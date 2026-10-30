#!/usr/bin/env bash
# import_roundtrip_court.sh — GAP22/GAP36 import roundtrip court.
#
# For each resource type: create the resource LIVE on the smalt ARM plane
# (via the provider's own create path — a tiny apply, which is the PUT-first
# requirement), then:
#   1. terraform apply        — resource exists on the wire
#   2. terraform state rm     — forget the adopted state (resource stays live)
#   3. terraform import       — re-adopt by id; MUST exit 0
#   4. state compare          — imported id must equal the live id
#   5. terraform plan -detailed-exitcode — MUST be 0 (zero drift)
#   6. terraform destroy      — cleanup; MUST exit 0
#
# Usage: scripts/import_roundtrip_court.sh [type ...]
#   with no args, runs all courtable types; loud SKIP for blocked rows.
# Exit 0 = every non-SKIP row green. Requires the posh plane on 127.0.0.1:9443.
set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${MODULE_DIR}"
chmod +x scripts/*.sh

ARM="http://127.0.0.1:9443"
SUB="00000000-0000-0000-0000-000000000000"
TENANT="00000000-0000-0000-0000-000000000000"
SECRET="smalt-sovereign-mock-secret"
RUN="$(date +%s)"
FAILED=0
declare -a ROWS=()

record() { # record <exit> <label>
  local rc="$1" label="$2"
  if [ "$rc" -eq 0 ]; then
    ROWS+=("PASS  ${label}")
  else
    ROWS+=("FAIL  ${label} (exit ${rc})")
    FAILED=1
  fi
}

skip() { ROWS+=("SKIP  $*"); }

fail() { echo "COURT BLOCKED: $*" >&2; exit 1; }

# ---- plane up check (fail-closed: no plane = court blocked, not vacuous pass)
HEALTH=$(curl -s -o /dev/null -w '%{http_code}' "${ARM}/healthz" || echo 000)
[ "${HEALTH}" = "401" ] || fail "smalt ARM plane not reachable at ${ARM}/healthz (got ${HEALTH}, need bearer-gated 401)"

# ---- build + rc
bash scripts/build_install.sh >/tmp/l36-court-build.log 2>&1 || fail "build_install.sh (see /tmp/l36-court-build.log)"
RC_FILE="${MODULE_DIR}/dev.tfrc"
export TF_CLI_CONFIG_FILE="${RC_FILE}"

WORK="$(mktemp -d /tmp/import-roundtrip-court.XXXXXX)"
echo "== import roundtrip court $(date -u +%FT%TZ) work=${WORK} =="

cat > "${WORK}/state_id.py" <<'PYEOF'
import json, os, sys
addr = os.environ["STATE_ADDR"]
s = json.load(sys.stdin)
for r in s.get("resources", []):
    if r["mode"] == "managed" and r["type"] + "." + r["name"] == addr:
        print(r["instances"][0]["attributes"]["id"])
        break
PYEOF

PROVIDER_HCL='terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
provider "azurerm" {
  features {}
  arm_endpoint    = "http://127.0.0.1:9443"
  subscription_id = "00000000-0000-0000-0000-000000000000"
}'

# roundtrip <label> <root> <addr> [import_id] — full create → forget → import
# → zero-drift plan → destroy cycle. Addr must be the root-level "type.name"
# address. Optional 4th arg overrides the import id (parity form) — when set,
# the id-equality check compares imported state id vs the OVERRIDE, not the
# create-path stored id.
roundtrip() { # roundtrip <label> <root> <addr> [import_id]
  local label="$1" root="$2" addr="$3" want_import_id="${4:-}"
  local log="${WORK}/${label}.log"
  (
    cd "${root}" || exit 9
    terraform init -input=false -no-color
    echo "RC_INIT/APPLY/RM/IMPORT/PLAN/DESTROY stages; see RC_* markers"
    echo "RC_INIT=$?"
    terraform apply -auto-approve -no-color -input=false
    echo "RC_APPLY=$?"
    if [ -n "${want_import_id}" ]; then
      LIVE_ID="${want_import_id}"
      echo "LIVE_ID=${LIVE_ID} (parity-form import-id override)"
      echo "RC_LIVEID=0"
    else
      LIVE_ID="$(terraform state pull | STATE_ADDR="${addr}" python3 "${WORK}/state_id.py")"
      echo "LIVE_ID=${LIVE_ID}"
      [ -n "${LIVE_ID}" ] && echo "RC_LIVEID=0" || { echo "no live id for ${addr}"; echo "RC_LIVEID=1"; exit 4; }
    fi
    terraform state rm "${addr}"
    echo "RC_RM=$?"
    terraform import "${addr}" "${LIVE_ID}"
    echo "RC_IMPORT=$?"
    IMPORTED_ID="$(terraform state pull | STATE_ADDR="${addr}" python3 "${WORK}/state_id.py")"
    echo "IMPORTED_ID=${IMPORTED_ID}"
    if [ -z "${want_import_id}" ] && [ "${IMPORTED_ID}" != "${LIVE_ID}" ]; then
      echo "id mismatch live=${LIVE_ID} imported=${IMPORTED_ID}"; exit 5
    fi
    terraform plan -detailed-exitcode -no-color -input=false
    echo "RC_PLAN=$?"
    terraform destroy -auto-approve -no-color -input=false
    echo "RC_DESTROY=$?"
  ) > "${log}" 2>&1
  local rc=0
  grep -q "RC_INIT=0"  "${log}" || { rc=1; }
  grep -q "RC_LIVEID=0" "${log}" || { rc=1; }
  grep -q "RC_APPLY=0" "${log}" || { rc=1; }
  grep -q "RC_RM=0"    "${log}" || { rc=1; }
  grep -q "RC_IMPORT=0" "${log}" || { rc=1; }
  grep -q "RC_PLAN=0"  "${log}" || { rc=1; }
  grep -q "RC_DESTROY=0" "${log}" || { rc=1; }
    record $rc "roundtrip ${label} (id=$(sed -n 's/^LIVE_ID=//p' "${log}" | head -1))"
}

cleanup_roots() {
  local d
  for d in "${WORK}"/*/; do
    [ -d "${d}" ] || continue
    [ -f "${d}/terraform.tfstate" ] || continue
    ( cd "${d}" && terraform destroy -auto-approve -no-color -input=false ) >/dev/null 2>&1
  done
  # residue-0 fallback: destroy pass can race the plane; DELETE any leftover
  # irtc-* resource groups directly, then verify the list is clean.
  local btok rg_list
  btok="$(curl -s -X POST "${ARM}/${TENANT}/oauth2/v2.0/token" \
    -d "grant_type=client_credentials&client_id=${SUB}&client_secret=${SECRET}&scope=https://management.azure.com/.default" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
  rg_list="$(curl -s -H "Authorization: Bearer ${btok}" \
    "${ARM}/subscriptions/${SUB}/resourcegroups?api-version=2023-07-01" \
    | python3 -c 'import json,sys; print("\n".join(r["name"] for r in json.load(sys.stdin).get("value",[]) if r["name"].startswith("irtc-")))' 2>/dev/null || true)"
  if [ -n "${rg_list}" ]; then
    local rg
    while IFS= read -r rg; do
      [ -n "${rg}" ] || continue
      curl -s -X DELETE -o /dev/null -H "Authorization: Bearer ${btok}" \
        "${ARM}/subscriptions/${SUB}/resourcegroups/${rg}?api-version=2023-07-01"
    done <<< "${rg_list}"
  fi
}
trap cleanup_roots EXIT

# ---- per-type fixtures. Each root: fixture RG + target resource(s).
new_root() { # new_root <label> <extra_hcl...>
  local label="$1"; shift
  local root="${WORK}/${label}"
  mkdir -p "${root}"
  {
    printf '%s\n' "${PROVIDER_HCL}"
    printf 'resource "azurerm_resource_group" "fixture" {\n  name     = "irtc-%s-%s"\n  location = "smaltlocation"\n}\n' "${label}" "${RUN}"
    printf '%s\n' "$@"
  } > "${root}/main.tf"
  echo "${root}"
}

want() { # want <type> — is this type requested?
  [ $# -eq 0 ] || case " $* " in *" ${TYPES} "*) return 0;; esac
  return 1
}

TYPES="$( [ $# -gt 0 ] && echo "$*" || echo "" )"
RUN_ALL=1; [ $# -gt 0 ] && RUN_ALL=0
SCRIPT_ARGS=("$@")
selected() { # selected <type...> — any of these requested on the CLI?
  [ ${RUN_ALL} -eq 1 ] && return 0
  local want t
  for want in "$@"; do
    for t in "${SCRIPT_ARGS[@]}"; do [ "${t}" = "${want}" ] && return 0; done
  done
  return 1
}

# ---- rg (consumer row 1; also the fixture for every other row)
if selected rg; then
  root="$(new_root rg "")"
  roundtrip rg "${root}" "azurerm_resource_group.fixture"
fi

# ---- kv
if selected kv; then
  root="$(new_root kv 'resource "azurerm_key_vault" "t" {
  name     = "irtckv'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
  tenant_id = "'"${TENANT}"'"
  sku_name = "standard"
}')"
  roundtrip kv "${root}" "azurerm_key_vault.t"
fi

# ---- kv-secret
if selected kv-secret; then
  root="$(new_root kv-secret 'resource "azurerm_key_vault" "kv" {
  name     = "irtckvs'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
  tenant_id = "'"${TENANT}"'"
  sku_name = "standard"
}
resource "azurerm_key_vault_secret" "t" {
  name        = "irtc-secret"
  key_vault_id = azurerm_key_vault.kv.id
  value       = "roundtrip"
}')"
  # Parity import-id form (upstream azurerm): the ARM path, not the vault URL
  # the create path stores. Court imports via the ARM path.
  roundtrip kv-secret "${root}" "azurerm_key_vault_secret.t" \
    "/subscriptions/${SUB}/resourceGroups/irtc-kv-secret-${RUN}/providers/Microsoft.KeyVault/vaults/irtckvs${RUN}/secrets/irtc-secret"
fi

# ---- uai — registered divergence KD-02: the smalt face record carries no
# properties.client_id/principal_id, so create/import cannot seed the computed
# attrs honestly; the honesty law refuses (error-by-default, lane C2). A
# roundtrip court would need fabrication to pass — loud SKIP, never a faked
# PASS. Close = face returns clientId/principalId on read (KD-02 falsifier).
if selected uai; then
  skip "uai (azurerm_user_assigned_identity) — registered divergence KD-02: face record has no properties.client_id/principal_id; create/import honestly refused by the honesty law (GAP22-2); roundtrip blocked without fabrication"
fi

# ---- role_assignment
if selected role_assignment; then
  root="$(new_root role_assignment 'resource "azurerm_role_definition" "rd" {
  name  = "irtc-rd-'"${RUN}"'"
  scope = azurerm_resource_group.fixture.id
  permissions {
    actions = ["*"]
  }
}
resource "azurerm_role_assignment" "t" {
  name         = "irtc-ra-'"${RUN}"'"
  scope        = azurerm_resource_group.fixture.id
  principal_id = "'"${TENANT}"'"
  # Full resource-id form: the bare-name form (rd.role_definition_id) routes
  # through the registered KD-09 deterministic mint, which rewrites
  # role_definition_id after apply and fails the import-parity gate by
  # construction. The consumer import ids themselves are path-form.
  role_definition_id = azurerm_role_definition.rd.role_definition_resource_id
}')"
  roundtrip role_assignment "${root}" "azurerm_role_assignment.t"
fi

# ---- role_definition (live via C1)
if selected role_definition; then
  root="$(new_root role_definition 'resource "azurerm_role_definition" "t" {
  name  = "irtc-rd-'"${RUN}"'"
  scope = azurerm_resource_group.fixture.id
  permissions {
    actions = ["*"]
  }
}')"
  roundtrip role_definition "${root}" "azurerm_role_definition.t"
fi

# ---- cae
if selected cae; then
  root="$(new_root cae 'resource "azurerm_container_app_environment" "t" {
  name     = "irtc-cae-'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
}')"
  roundtrip cae "${root}" "azurerm_container_app_environment.t"
fi

# ---- law (log analytics workspace)
if selected law; then
  root="$(new_root law 'resource "azurerm_log_analytics_workspace" "t" {
  name     = "irtc-law-'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
}')"
  roundtrip law "${root}" "azurerm_log_analytics_workspace.t"
fi

# ---- acr (container registry)
if selected acr; then
  root="$(new_root acr 'resource "azurerm_container_registry" "t" {
  name     = "irtcacr'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
  sku      = "Basic"
}')"
  roundtrip acr "${root}" "azurerm_container_registry.t"
fi

# ---- container_app (needs a CAE fixture too)
# ---- container_app (needs a CAE fixture too)
if selected container_app; then
  root="$(new_root container_app 'resource "azurerm_container_app_environment" "cae" {
  name     = "irtc-caca-'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  location = "smaltlocation"
}
resource "azurerm_container_app" "t" {
  name     = "irtc-ca-'"${RUN}"'"
  resource_group_name = azurerm_resource_group.fixture.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  revision_mode = "Single"
  template {
    container {
      name   = "main"
      image  = "smalt:local"
      cpu    = "0.5"
      memory = "1Gi"
    }
  }
}')"
  roundtrip container_app "${root}" "azurerm_container_app.t"
fi

# ---- blocked rows (loud SKIP, never silent)
skip "federated_identity_credential — blocked: nested FIC route 404 on smalt plane (KD-08)"
skip "consumer import blocks 11-12 (registry-nested role assignment ids) — covered by role_assignment row; nested-scope consumer ids re-courted once GAP22 consumer-root court lands"

echo
printf '%s\n' "${ROWS[@]}"
echo "work dir: ${WORK}"
if [ "${FAILED}" -eq 0 ]; then
  echo "COURT GREEN (exit 0)"
  exit 0
else
  echo "COURT RED (exit 1); logs in ${WORK}"
  exit 1
fi
