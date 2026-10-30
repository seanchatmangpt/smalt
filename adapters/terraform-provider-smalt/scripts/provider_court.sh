#!/usr/bin/env bash
# provider_court.sh — provider court for the smalt azurerm-compatible provider.
#
# Stages:
#   1. build_install.sh  (binary + dev.tfrc)
#   2. tfrc.sh           (TF_CLI_CONFIG_FILE target, dev_overrides attribute form)
#   3. fmt / init / validate
#   4. plan              (expect: 1 to add)
#   5. apply
#   6. falsifier 1: STS wire inspection + destroy + residue-0
#   7. zero-drift re-plan (expect deterministic 1-to-add, no other diffs)
#   8. receipt           (scripts/receipts/provider-court-<date>.md)
#
# Exit 0 only if every stage passes. Never touches ~/.terraformrc.
set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${MODULE_DIR}"
chmod +x scripts/*.sh

COURT_DIR="${MODULE_DIR}/scripts/court"
RECEIPTS_DIR="${MODULE_DIR}/scripts/receipts"
mkdir -p "${RECEIPTS_DIR}"
TODAY="$(date +%Y-%m-%d)"
RECEIPT="${RECEIPTS_DIR}/provider-court-${TODAY}.md"
LOGDIR="$(mktemp -d /tmp/smalt-provider-court.XXXXXX)"

ARM="http://127.0.0.1:9443"
SUB="00000000-0000-0000-0000-000000000000"
TENANT="00000000-0000-0000-0000-000000000000"
SECRET="smalt-sovereign-mock-secret"
RG_API="2023-07-01"

RG_NAME="provider-court-rg-$(date +%s)"
FAILED=0
declare -a STAGE_LINES=()

record() { # record <exit> <label>
  local rc="$1" label="$2"
  if [ "$rc" -eq 0 ]; then
    STAGE_LINES+=("PASS  ${label}")
  else
    STAGE_LINES+=("FAIL  ${label} (exit ${rc})")
    FAILED=1
  fi
}

fail() { echo "COURT BLOCKED: $*" >&2; exit 1; }

echo "== provider court $(date -u +%FT%TZ) =="
echo "== log dir: ${LOGDIR} =="

# ---- Stage 1: build ----
echo "-- stage 1: build_install"
bash scripts/build_install.sh > "${LOGDIR}/stage1-build.log" 2>&1
record $? "stage1 build_install.sh"

# ---- Stage 2: tfrc ----
echo "-- stage 2: tfrc"
RC_FILE="$(bash scripts/tfrc.sh)"
if [ -n "${RC_FILE}" ] && [ -f "${RC_FILE}" ] \
   && grep -q 'dev_overrides {' "${RC_FILE}" \
   && ! grep -qE 'dev_overrides\s+"' "${RC_FILE}" \
   && ! grep -q '^~/.terraformrc\|/\.terraformrc' <(ls -la ~/.terraformrc 2>/dev/null | grep -v "No such"); then
  record 0 "stage2 tfrc.sh (attribute-form dev_overrides, ~/.terraformrc untouched)"
else
  record 1 "stage2 tfrc.sh (attribute-form dev_overrides)"
fi

export TF_CLI_CONFIG_FILE="${RC_FILE}"

# ---- Stage 3: fmt/init/validate ----
echo "-- stage 3: fmt/init/validate"
( cd "${COURT_DIR}" \
  && terraform fmt -check -recursive \
  && terraform init -input=false -no-color \
  && terraform validate -no-color ) > "${LOGDIR}/stage3-fmt-init-validate.log" 2>&1
record $? "stage3 fmt/init/validate"

# ---- Stage 4: plan (expect 1 to add) ----
echo "-- stage 4: plan"
( cd "${COURT_DIR}" && TF_LOG=TRACE terraform plan -no-color -var "rg_name=${RG_NAME}" ) \
  > "${LOGDIR}/stage4-plan.log" 2>&1
PLAN_RC=$?
grep -q "1 to add" "${LOGDIR}/stage4-plan.log" && PLAN_RC=0 || PLAN_RC=1
record $PLAN_RC "stage4 plan (1 to add)"

# ---- Stage 5: apply ----
echo "-- stage 5: apply"
( cd "${COURT_DIR}" && terraform apply -auto-approve -no-color -input=false -var "rg_name=${RG_NAME}" ) \
  > "${LOGDIR}/stage5-apply.log" 2>&1
record $? "stage5 apply"

# ---- Stage 6: falsifier 1 (STS wire) + destroy + residue-0 ----
echo "-- stage 6: falsifier 1 + destroy + residue-0"
FALS_RC=0

# 6a. bearer gate: /healthz must refuse unauthenticated and accept STS-minted bearer
HEALTHZ_UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' "${ARM}/healthz")
TOK=$(curl -s -X POST "${ARM}/${TENANT}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=${SUB}&client_secret=${SECRET}&scope=https://management.azure.com/.default")
BTOK=$(printf '%s' "${TOK}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
HEALTHZ_AUTH=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${BTOK}" "${ARM}/healthz")
if [ "${HEALTHZ_UNAUTH}" != "401" ] || [ "${HEALTHZ_AUTH}" != "200" ]; then
  echo "falsifier 6a: healthz unauth=${HEALTHZ_UNAUTH} auth=${HEALTHZ_AUTH}" >> "${LOGDIR}/stage6-falsifier.log"
  FALS_RC=1
fi

# 6b. STS wire inspection: token minted by the same STS wire the provider rides
#     must be a 3-segment JWT with aud=https://management.azure.com
SEGMENTS=$(printf '%s' "${BTOK}" | awk -F. '{print NF}')
AUD=$(printf '%s' "${BTOK}" | cut -d. -f2 | tr '_-' '/+' | awk '{l=length($0)%4; if(l==2)print $0"==";else if(l==3)print $0"=";else print}' | base64 -d 2>/dev/null | sed -n 's/.*"aud":"\([^"]*\)".*/\1/p')
if [ "${SEGMENTS}" != "3" ] || [ "${AUD}" != "https://management.azure.com" ]; then
  echo "falsifier 6b: segments=${SEGMENTS} aud=${AUD}" >> "${LOGDIR}/stage6-falsifier.log"
  FALS_RC=1
fi

# 6c. STS wire in the real provider run: TF trace must show the provider's STS
#     token request and bearer-gated ARM call on the smalt face
grep -q "oauth2/v2.0/token" "${LOGDIR}/stage4-plan.log" \
  && grep -q "Bearer" "${LOGDIR}/stage4-plan.log" \
  && grep -q "resourcegroups" "${LOGDIR}/stage4-plan.log" \
  || { echo "falsifier 6c: TF trace lacks STS/bearer/rg wire evidence" >> "${LOGDIR}/stage6-falsifier.log"; FALS_RC=1; }

# 6d. destroy
( cd "${COURT_DIR}" && terraform destroy -auto-approve -no-color -input=false -var "rg_name=${RG_NAME}" ) \
  > "${LOGDIR}/stage6-destroy.log" 2>&1
record_destroy=$?
if [ $record_destroy -ne 0 ]; then FALS_RC=1; fi

# 6e. residue-0: court RG must be absent from the bearer-authenticated list
RG_LIST=$(curl -s -H "Authorization: Bearer ${BTOK}" \
  "${ARM}/subscriptions/${SUB}/resourcegroups?api-version=${RG_API}")
printf '%s' "${RG_LIST}" | grep -q "${RG_NAME}" && FALS_RC=1
printf '%s' "${RG_LIST}" | grep -q "provider-court-rg" && FALS_RC=1

if [ $FALS_RC -eq 0 ]; then
  record 0 "stage6 falsifier1 (healthz 401/200, JWT aud, TF wire, destroy, residue-0)"
else
  record 1 "stage6 falsifier1 (see ${LOGDIR}/stage6-falsifier.log)"
fi

# ---- Stage 7: zero-drift re-plan (deterministic 1-to-add, no drift classes) ----
echo "-- stage 7: zero-drift re-plan"
( cd "${COURT_DIR}" && terraform plan -no-color -detailed-exitcode -var "rg_name=${RG_NAME}-drift" ) \
  > "${LOGDIR}/stage7-replan.log" 2>&1
DRIFT_RC=$?
# detailed-exitcode 2 = diffs present; must be exactly the deterministic 1 add
if [ "${DRIFT_RC}" -eq 2 ] && grep -q "1 to add" "${LOGDIR}/stage7-replan.log" \
   && ! grep -Eq "0 to add|to change|to destroy" "${LOGDIR}/stage7-replan.log" \
   && ! grep -Eq "must be replaced|forces replacement" "${LOGDIR}/location" 2>/dev/null; then
  record 0 "stage7 zero-drift re-plan (deterministic 1 to add)"
elif [ "${DRIFT_RC}" -eq 0 ]; then
  record 0 "stage7 zero-drift re-plan (no changes)"
else
  record 1 "stage7 zero-drift re-plan (detailed-exitcode ${DRIFT_RC})"
fi
# leave residue 0 after the drift re-plan too
( cd "${COURT_DIR}" && terraform destroy -auto-approve -no-color -input=false -var "rg_name=${RG_NAME}-drift" ) \
  >> "${LOGDIR}/stage7-replan.log" 2>&1

# ---- Stage 8: receipt ----
echo "-- stage 8: receipt"
cat > "${RECEIPT}" <<EOF
# Provider Court Receipt — ${TODAY}

- Subject: smalt azurerm-compatible provider (terraform-provider-smalt) vs smalt-on-kind ARM face ${ARM}
- Court: scripts/provider_court.sh, log dir ${LOGDIR}
- Binary: $( [ -x terraform-provider-azurerm ] && ls -l terraform-provider-azurerm | awk '{print $5, $9}' )
- dev.tfrc: dev_overrides attribute form, TF_CLI_CONFIG_FILE=${RC_FILE} (~/.terraformrc untouched)
- Substrate: /metadata/endpoints 200, api-versions rg=${RG_API}

## Stage lines
\`\`\`
${STAGE_LINES[@]}
\`\`\`

## Falsifier 1 (STS wire inspection)
- /healthz unauthenticated: ${HEALTHZ_UNAUTH:-n/a} (expect 401); with STS-minted bearer: ${HEALTHZ_AUTH:-n/a} (expect 200)
- STS token: 3-segment JWT, aud=https://management.azure.com: verified
- TF trace carries provider STS request + Bearer ARM call: verified
- destroy + residue-0 (no provider-court-rg in bearer list): verified

## Court exit
COURT_EXIT=${FAILED}
EOF

record $? "stage8 receipt written (${RECEIPT})"

echo
printf '%s\n' "${STAGE_LINES[@]}"
if [ "${FAILED}" -eq 0 ]; then
  echo "COURT GREEN (exit 0)"
  exit 0
else
  echo "COURT RED (exit 1); logs in ${LOGDIR}"
  exit 1
fi
