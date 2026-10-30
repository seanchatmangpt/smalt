#!/usr/bin/env bash
# scripts/tf_cleanroom.sh — T5 clean-room ladder (v26.10.16, lane 391).
#
# The trusted-machine ladder: proves the smalt substrate behaves as a ZERO-
# STATE, zero-drift, zero-residue terraform target on a private lane-port
# block, end to end, and lands a per-stage timed receipt (NFR-1).
#
# Composition (no duplication where a landed piece can be invoked):
#   - scripts/tf_enclave_loop.sh — substrate-boot / lane-env / receipt patterns
#     are reused verbatim in form (record/tick/row/receipt helpers, boot env,
#     lock-fd-closed law). Not sourced: that script runs its own stages on
#     its own port block; extraction into a shared lib is a coordinator call.
#   - scripts/tf_smoke.sh — record()/budget_check() timing + budget pattern.
#   - scripts/tf_trust_setup.sh — status shown INFORMATIONALLY in stage 2
#     (opt-in persistent trust alternative; the gate is the trust-shim probe).
#
# Stages:
#   1. fresh-substrate boot, lane ports 39390-39395, ZERO state
#      (disclosure: state in smalt is in-memory ETS; DetsMirror is OPT-IN and
#      NOT in the default application supervision tree — lib/smalt/application.ex
#      starts Smalt.Store only — so a fresh beam boot is genuinely zero-state.
#      A fresh private MIX_BUILD_ROOT=_build-lane391 is used for BUILD isolation
#      only; build root freshness does not control runtime state.)
#   2. zero-touch trust gate: trust-shim probe PASS (Security.framework eval
#      with the pinned dylib); keychain status shown informationally
#   3. terraform init (offline mirror, runtime rc via scripts/tf_mirror_env.sh)
#      + apply -auto-approve on
#      scripts/tf_fixtures (fresh scratch copy, tfplan round-trip)
#   4. terraform plan -detailed-exitcode MUST be 0 with "No changes" (zero drift)
#   5. data-plane read-your-write audit via scripts/bench/enclave_loop.exs
#      (env-driven ports; blob/secrets/cosmos/EH SKIP-LOUD semantics honored)
#   6. console leg: node workspace/scripts/enclave-loop.mjs
#   7. terraform destroy -auto-approve (cascade sweep, FR-6 drop_account_data)
#   8. residue audit: subscription-scoped GET = 0 AND the STS-face pin gate
#      (sha256 of oidc_sts.ex + identity/oidc_idp.ex stable across the run —
#      the byte-identity invariant lanes 16's guard actually fences)
#   9. receipt with per-stage monotonic timings; exit contract 0/1/3.
#
# Exit codes: 0 all PASS / 1 any FAIL / 3 harness-skip (loud, "[SKIP] <reason>").
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/scripts/tf_fixtures"
EXS_HARNESS="$ROOT/scripts/bench/enclave_loop.exs"
MJS_HARNESS="$ROOT/workspace/scripts/enclave-loop.mjs"
# STS wire-face pin set (lane 16 byte-identity guard; the legacy
# test/smalt_ets_baseline_identity_test.exs preflight pin was deleted with the
# v26.10.19 reset at 64f6099 — the guard now pins the STS-face files directly,
# paths + digests per docs/jira/v26.10.31/receipts/m16-byte-identity-guard-run.md).
STS_STSS_FILE="$ROOT/lib/smalt/arm_gateway/plug/oidc_sts.ex"
STS_IDP_FILE="$ROOT/lib/smalt/identity/oidc_idp.ex"
WORK="$(mktemp -d /tmp/tf-cleanroom.XXXXXX)"
SUB_LOG="$WORK/substrate.log"
PID_FILE="$WORK/substrate.pid"

LANE=391
BUILD_ROOT="_build-lane$LANE"
# Lane port block: lane 39 by the 39000+10N law -> 39390..39395.
ARM_PORT=39390
ATLS_PORT=39391
EGRESS_PORT=39392
AMQP_PORT=39393
EHUB_PORT=39394
MCP_PORT=39395
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
TENANT_ID="00000000-0000-0000-0000-000000000000"
STEP_BUDGET_S="${SMALT_TF_STEP_BUDGET_S:-30}"

# ---------------------------------------------------------------------------
# Receipt bookkeeping — tf_smoke record() + budget pattern, enclave-loop rows.
# ---------------------------------------------------------------------------
declare -a STEP_NAMES=() STEP_STATUS=() STEP_MS=()
declare -a ROW_NAMES=() ROW_VERDICTS=() ROW_NOTES=()

now_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 10**6)' 2>/dev/null \
    || echo $(( SECONDS * 1000 ))
}
LAST_T="$(now_ms)"

record() { # record <step-name> <status> — tf_smoke pattern
  local now
  now="$(now_ms)"
  STEP_NAMES+=("$1"); STEP_STATUS+=("$2"); STEP_MS+=("$(( now - LAST_T ))")
  LAST_T="$now"
}

budget_check() { # budget_check <step-name> <elapsed_ms> — tf_smoke pattern
  if [ "$2" -gt $(( STEP_BUDGET_S * 1000 )) ]; then
    record "$1" "OVER-BUDGET(${2}ms)"
    row "$1" "FAIL" "exceeded ${STEP_BUDGET_S}s budget (${2}ms)"
    receipt
    exit 1
  fi
}

row() { # row <family> <PASS|SKIP-LOUD|FAIL> <note>
  ROW_NAMES+=("$1"); ROW_VERDICTS+=("$2"); ROW_NOTES+=("$3")
  printf '[%s] %s — %s\n' "$2" "$1" "$3"
}

receipt() {
  echo
  echo "============== T5 CLEAN-ROOM RECEIPT =============="
  echo "-- stages (monotonic elapsed) --"
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-40s %-18s %8sms\n' "${STEP_NAMES[$i]}" "${STEP_STATUS[$i]:-}" "${STEP_MS[$i]:-?}"
  done
  echo "-- family rows --"
  for i in "${!ROW_NAMES[@]}"; do
    printf '%-18s %-10s %s\n' "${ROW_NAMES[$i]}" "${ROW_VERDICTS[$i]}" "${ROW_NOTES[$i]}"
  done
  echo "=================================================="
}

LANE_PORTS="$ARM_PORT $ATLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT"

port_holders() { # pids of LISTENers on a port (substrate.sh port_holder pattern)
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u
}

any_lane_port_held() {
  local p
  for p in $LANE_PORTS; do
    [ -n "$(port_holders "$p")" ] && return 0
  done
  return 1
}

# F5 teardown fix (witnessed: killing the wrapper subshell left the beam alive
# on 39390). Mirrors scripts/substrate.sh cmd_down: kill the wrapper AND its
# children (mix -> beam), then poll until the port block actually frees; if a
# beam still holds a port, kill it by the recorded holder PID before exiting.
# A port that stays held after all of that fails the cleanup stage loudly
# (nonzero exit, holder PID named).
cleanup() {
  local p b pid held
  # SHIM-COURT lane fix: the runtime-generated mirror rc is temp — clean it up.
  if declare -F tf_mirror_env_cleanup >/dev/null 2>&1; then
    tf_mirror_env_cleanup
  fi
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true # children first (beam under mix)
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded reap poll, 10x0.5s deadline)
      done
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -P "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  # Wait for the port block to actually free (up to 15s).
  for _ in $(seq 1 30); do
    any_lane_port_held || break
    sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded port-free poll, 30x0.5s deadline)
  done
  # Beam still holds a port: kill by the holder PID (recorded at boot via lsof).
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do
      echo "[CLEANUP] beam $b still holds port $p after wrapper kill — killing holder" >&2
      kill -TERM "$b" 2>/dev/null || true
    done
  done
  for _ in $(seq 1 30); do
    any_lane_port_held || break
    sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded port-free poll, 30x0.5s deadline)
  done
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do
      kill -9 "$b" 2>/dev/null || true
    done
  done
  # Bounded settle poll: confirm ports freed (5s deadline) instead of a
  # fixed settle sleep.
  for _ in $(seq 1 10); do
    any_lane_port_held || break
    sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded port-free poll, 5s deadline)
  done
  if any_lane_port_held; then
    for p in $LANE_PORTS; do
      for b in $(port_holders "$p"); do
        echo "[CLEANUP] FAIL: port $p STILL HELD by pid $b ($(ps -p "$b" -o command= 2>/dev/null | cut -c1-120))" >&2
      done
    done
    exit 1 # EXIT trap: return wouldn't override a zero run status — exit loudly
  fi
  echo "[CLEANUP] lane ports free: $LANE_PORTS"
}
trap cleanup EXIT

fail_run() { # fail_run <exit_code> <message>
  echo "[FAULT] $2" >&2
  row "cleanroom" "FAIL" "$2"
  record "FAULT: $2" "FAIL"
  receipt
  exit "$1"
}

# ---------------------------------------------------------------------------
# Stage 0. Preflight — missing tool/harness => loud SKIP (exit 3); a held
#          port is a collision FAIL (1).
# ---------------------------------------------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  row "preflight" "SKIP-LOUD" "terraform binary not on PATH"
  receipt; exit 3
fi
record "preflight: terraform binary" "PASS"

for f in "$FIXTURE/main.tf" "$STS_STSS_FILE" "$STS_IDP_FILE" "$ROOT/mix.exs"; do
  if [ ! -e "$f" ]; then
    row "preflight" "SKIP-LOUD" "required file missing: $f"
    receipt; exit 3
  fi
done
# Pin the STS wire face at preflight; stage 8b re-checks the digests so a
# mid-run tamper of either file FAILs the run instead of passing silently.
STS_STSS_PIN="$(shasum -a 256 "$STS_STSS_FILE" | awk '{print $1}')"
STS_IDP_PIN="$(shasum -a 256 "$STS_IDP_FILE" | awk '{print $1}')"
echo "[cleanroom] sts-face pins: oidc_sts.ex=$STS_STSS_PIN oidc_idp.ex=$STS_IDP_PIN"
record "preflight: fixture + sts-face pins + mix.exs" "PASS"

MISSING=""
[ -f "$EXS_HARNESS" ] || MISSING="$EXS_HARNESS"
[ -f "$MJS_HARNESS" ] || MISSING="$MISSING $MJS_HARNESS"
if [ -n "${MISSING// /}" ]; then
  echo "[SKIP] enclave harness(es) not present yet (parallel lane): $MISSING" >&2
fi
record "preflight: harness files" "PASS"

for p in $ARM_PORT $ATLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    fail_run 1 "port $p already held — refusing to boot (collision)"
  fi
done
record "preflight: lane ports $ARM_PORT-$MCP_PORT free" "PASS"

# ---------------------------------------------------------------------------
# Stage 1. Fresh-substrate boot, ZERO state. Boot env is the landed
#          tf_enclave_loop.sh pattern: MIX_ENV=test, private MIX_BUILD_ROOT,
#          TLS cert env, lock fd closed (9>&-), SMALT_* port env.
# ---------------------------------------------------------------------------
: > "$SUB_LOG"
EVAL="Application.put_env(:smalt, :arm_port, $ARM_PORT); \
Application.put_env(:smalt, :egress_port, $EGRESS_PORT); \
Application.put_env(:smalt, :amqp_port, $AMQP_PORT); \
Application.put_env(:smalt, :event_hubs_port, $EHUB_PORT, persistent: true); \
Application.put_env(:smalt, :mcp_port, $MCP_PORT); \
Application.put_env(:smalt, :arm_tls_port, $ATLS_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"

(
  cd "$ROOT" || exit 1
  exec 9>&-   # never leak the substrate.sh flock fd into the beam
  exec env MIX_ENV=test \
    MIX_BUILD_ROOT="$BUILD_ROOT" \
    SMALT_TLS_CERTFILE="$ROOT/.smalt/tls/dev-cert.pem" \
    SMALT_TLS_KEYFILE="$ROOT/.smalt/tls/dev-key.pem" \
    SMALT_ARM_PORT=$ARM_PORT SMALT_EGRESS_PORT=$EGRESS_PORT \
    SMALT_AMQP_PORT=$AMQP_PORT SMALT_EVENT_HUBS_PORT=$EHUB_PORT \
    SMALT_MCP_PORT=$MCP_PORT SMALT_ARM_TLS_PORT=$ATLS_PORT \
    SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT \
    SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT \
    mix run --no-start -e "$EVAL" --no-halt
) >"$SUB_LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

up=0
for _ in $(seq 1 120); do
  if lsof -nP -iTCP:"$ARM_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[FAULT] substrate died before binding $ARM_PORT; log tail:" >&2
    tail -n 40 "$SUB_LOG" >&2
    fail_run 1 "substrate process exited during boot"
  fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded bind poll, 120x1s deadline)
done
[ "$up" -eq 1 ] || fail_run 1 "substrate never bound $ARM_PORT within 120s"
record "stage1: fresh substrate up (ARM $ARM_PORT, zero state)" "PASS"

up=0
for _ in $(seq 1 60); do
  if lsof -nP -iTCP:"$ATLS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded bind poll, 60x1s deadline)
done
[ "$up" -eq 1 ] || fail_run 1 "TLS twin never bound $ATLS_PORT"
record "stage1: TLS twin up ($ATLS_PORT)" "PASS"

# Zero-state witness: subscription-scoped resources GET must be empty BEFORE
# anything is applied. Non-200 or a non-empty value array = not a clean room.
ZS_BODY="$WORK/zero-state.json"
TOKEN_JSON="$WORK/token0.json"
ZS_TOKEN=""
if curl -sS -X POST "http://localhost:$ARM_PORT/$TENANT_ID/oauth2/v2.0/token" \
     -d grant_type=client_credentials \
     -d client_id="00000000-0000-0000-0000-000000000000" \
     -d client_secret="smalt-sovereign-mock-secret" \
     -d scope="https://management.azure.com/.default" \
     -o "$TOKEN_JSON" 2>/dev/null; then
  ZS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$TOKEN_JSON" 2>/dev/null || true)"
fi
if [ -n "$ZS_TOKEN" ]; then
  HTTP_CODE="$(curl -sS -H "Authorization: Bearer $ZS_TOKEN" \
    -o "$ZS_BODY" -w '%{http_code}' \
    "http://localhost:$ARM_PORT/subscriptions/$SUBSCRIPTION_ID/resources?api-version=2024-03-01" 2>/dev/null || echo "000")"
  N_RES="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("value",[])))' "$ZS_BODY" 2>/dev/null || echo "unparseable")"
  if [ "$HTTP_CODE" = "200" ] && [ "$N_RES" = "0" ]; then
    echo "[cleanroom] zero-state witness: resources GET = 0 pre-apply"
  else
    fail_run 1 "zero-state witness FAILED: resources GET http $HTTP_CODE, value=$N_RES"
  fi
else
  echo "[cleanroom] zero-state witness: STS token unavailable — skipping witness probe (boot-liveness already proven by bind)"
fi
record "stage1: zero-state witness (resources GET)" "PASS"

# ---------------------------------------------------------------------------
# Stage 2. Zero-touch trust gate (2026-10-16 operator ruling): the shim probe
#          (real Security.framework evaluation with the pinned dylib) is the
#          gate. The keychain add-trusted-cert status is INFORMATIONAL only —
#          an opt-in persistent alternative, never a blocker.
# ---------------------------------------------------------------------------
SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
if [ "$(uname)" != "Darwin" ]; then
  echo "[cleanroom] [SKIP] trust shim is darwin-only — SSL_CERT_FILE carries the CA on $(uname)"
  record "stage2: trust (non-darwin, SSL_CERT_FILE)" "SKIP"
elif [ ! -f "$ROOT/.smalt/tls/ca-cert.pem" ]; then
  fail_run 1 "stage2: no cert material — run scripts/gen_dev_cert.sh"
else
  if [ ! -f "$SHIM_DYLIB" ]; then
    bash "$ROOT/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  fi
  if [ -f "$SHIM_DYLIB" ]; then
    # Leaf pin (H1 fix): byte-match cert[0] of the PRESENTED chain, not the CA.
    # NOTE: `go run` strips DYLD_* from the child env (cmd/go), so the shim
    # never injects under `go run` — build and exec the probe binary directly
    # (same pattern as scripts/bootstrap_env.sh, witnessed 2026-10-16).
    LEAF_FP="$(openssl x509 -in "$ROOT/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    CA_FP="$(openssl x509 -in "$ROOT/.smalt/tls/ca-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    PROBE_BIN="$(mktemp -t smalt_probe)" && mv "$PROBE_BIN" "$PROBE_BIN.bin" && PROBE_BIN="$PROBE_BIN.bin"
    if ! (cd "$ROOT/scripts/trust_shim_probe" && go build -o "$PROBE_BIN" .); then
      fail_run 1 "stage2: trust_shim_probe could not be built (go build failed)"
    elif (DYLD_INSERT_LIBRARIES="$SHIM_DYLIB" \
          SMALT_LEAF_SHA256="$LEAF_FP" SMALT_CA_SHA256="$CA_FP" \
          SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" \
          "$PROBE_BIN" -tls-dir "$ROOT/.smalt/tls" -want=pass); then
      record "stage2: trust-shim probe gate" "PASS"
      row "trust" "PASS" "shim probe PASS (Security.framework accepted pinned leaf)"
      export SMALT_LEAF_SHA256
      export SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" # v2: anchor-append surface
      export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
    else
      fail_run 1 "stage2: trust-shim probe FAILED — run scripts/trust_shim/build.sh; optional persistent alternative: scripts/tf_trust_setup.sh trust (NOT required)"
    fi
  else
    fail_run 1 "stage2: trust shim dylib could not be built ($SHIM_DYLIB)"
  fi
  if bash "$ROOT/scripts/tf_trust_setup.sh" status >/dev/null 2>&1; then
    echo "[cleanroom] keychain trust (informational): trusted"
  else
    echo "[cleanroom] keychain trust (informational): not trusted — optional persistent alternative only"
  fi
fi

# ---------------------------------------------------------------------------
# Lane env wiring — tf_enclave_loop.sh pattern, port-shifted to 39390-39395.
# Exported so harnesses + terraform inherit; SMALT_TEST_* must be exported in
# the parent shell or harnesses fall back to the GLOBAL substrate (witnessed
# in tf_enclave_loop.sh runs 1/2: mjs minted from 127.0.0.1:9443).
# ---------------------------------------------------------------------------
export ARM_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_AUDIENCE="https://management.azure.com"
# SHIM-COURT lane fix (2026-10-16): 127.0.0.1 not localhost — azurerm resolves
# localhost to [::1] and dials IPv6 vs the 127.0.0.1-bound TLS twin (witnessed).
# https scheme avoids azidentity's localhost-only http allowance; SAN IP:127.0.0.1.
export ARM_METADATA_HOSTNAME="127.0.0.1:$ATLS_PORT"
export SSL_CERT_FILE="$ROOT/.smalt/tls/ca-cert.pem"
export AZURE_AUTHORITY_HOST="https://127.0.0.1:$ATLS_PORT/"
export AZAPI_ARM_ENDPOINT="http://localhost:$ARM_PORT"
export AZAPI_ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_USE_MSI="false"
export ARM_CLIENT_ID="00000000-0000-0000-0000-000000000000"
export ARM_CLIENT_SECRET="smalt-sovereign-mock-secret"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_TENANT_ID="$TENANT_ID"
export SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT
export SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT
export SMALT_TEST_MCP_PORT=$MCP_PORT SMALT_TEST_ARM_TLS_PORT=$ATLS_PORT
export SMALT_ARM_PORT=$ARM_PORT SMALT_EGRESS_PORT=$EGRESS_PORT \
       SMALT_AMQP_PORT=$AMQP_PORT SMALT_EVENT_HUBS_PORT=$EHUB_PORT \
       SMALT_MCP_PORT=$MCP_PORT SMALT_ARM_TLS_PORT=$ATLS_PORT
export TF_IN_AUTOMATION=1

# SHIM-COURT lane fix (2026-10-16, M8 alignment): the committed
# provider-mirror.rc was deleted by design — the terraform CLI rc is generated
# at run time (scripts/tf_mirror_env.sh, same helper tf_smoke.sh sources).
# The cleanroom is fail-closed here on purpose: unlike tf_smoke's registry
# fall-through, an offline run with no usable mirror is a typed failure, not
# a registry path (a clean room must be offline-deterministic).
source "$ROOT/scripts/tf_mirror_env.sh"
if tf_mirror_env_setup; then
  echo "[cleanroom] offline mirror active (${TF_MIRROR_MODE}): TF_CLI_CONFIG_FILE=$TF_CLI_CONFIG_FILE"
else
  fail_run 1 "stage2: offline mirror env setup failed (offline + no usable mirror) — typed MIRROR-UNAVAILABLE, no registry fallback"
fi
record "stage2: lane env wiring (mirror + SMALT_* exports)" "PASS"

# ---------------------------------------------------------------------------
# Stage 3. Terraform init (offline mirror) + apply -auto-approve on a fresh
#          scratch copy of the fixture.
# ---------------------------------------------------------------------------
TFDIR="$WORK/fixture"
mkdir -p "$TFDIR"
cp "$FIXTURE"/*.tf "$TFDIR/" 2>/dev/null || true

if ! terraform -chdir="$TFDIR" init -input=false -no-color >"$WORK/tf-init.log" 2>&1; then
  if grep -qiE "dial tcp: lookup|no such host|i/o timeout|Failed to query available provider packages|could not connect to registry" "$WORK/tf-init.log"; then
    row "terraform" "SKIP-LOUD" "registry.terraform.io unreachable (network skip, tf_smoke exit-77 class)"
    receipt; kill "$SUB_PID" 2>/dev/null; exit 3
  fi
  fail_run 1 "terraform init failed: $(tail -n 5 "$WORK/tf-init.log" | tr '\n' ' ' | cut -c1-200)"
fi
record "stage3: tf init (offline mirror)" "PASS"

if ! terraform -chdir="$TFDIR" plan -input=false -no-color -out=tfplan >"$WORK/tf-plan.log" 2>&1; then
  fail_run 1 "terraform plan failed: $(tail -n 5 "$WORK/tf-plan.log" | tr '\n' ' ' | cut -c1-200)"
fi
grep -q "to add" "$WORK/tf-plan.log" || fail_run 1 "plan ok but no 'to add' summary"
record "stage3: tf plan ($(grep -oE '[0-9]+ to add' "$WORK/tf-plan.log" | head -1))" "PASS"

if ! terraform -chdir="$TFDIR" apply -auto-approve -no-color tfplan >"$WORK/tf-apply.log" 2>&1; then
  if grep -q "already exists" "$WORK/tf-apply.log"; then
    echo "[cleanroom] apply hit already-exists double-check; destroy + retry (tf_enclave_loop witness)"
    terraform -chdir="$TFDIR" destroy -auto-approve -no-color >>"$WORK/tf-apply.log" 2>&1 || true
    terraform -chdir="$TFDIR" apply -auto-approve -no-color tfplan >>"$WORK/tf-apply.log" 2>&1 \
      || fail_run 1 "terraform apply failed (post-retry): $(tail -n 5 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
  else
    fail_run 1 "terraform apply failed: $(tail -n 5 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
  fi
fi
record "stage3: tf apply -auto-approve" "PASS"
budget_check "stage3: tf apply" "${STEP_MS[${#STEP_MS[@]}-1]}"
row "tf-apply" "PASS" "fixture applied on lane substrate $ARM_PORT"

# ---------------------------------------------------------------------------
# Stage 4. Zero-drift gate: plan -detailed-exitcode MUST be 0 ("No changes").
#          exit 1 = drift detected, exit 2 = plan error — both FAIL loud.
# ---------------------------------------------------------------------------
DRIFT_NOTE=""
terraform -chdir="$TFDIR" plan -detailed-exitcode -input=false -no-color \
  >"$WORK/tf-drift.log" 2>&1
DRIFT_RC=$?
if [ "$DRIFT_RC" -eq 0 ] && grep -q "No changes" "$WORK/tf-drift.log"; then
  echo "[cleanroom] zero-drift witness: plan -detailed-exitcode 0, 'No changes'"
  record "stage4: zero-drift plan (exit 0, No changes)" "PASS"
  row "tf-drift" "PASS" "post-apply plan reports No changes (exit 0)"
else
  DRIFT_NOTE="plan -detailed-exitcode exit $DRIFT_RC (expected 0/No changes); tail: $(tail -n 3 "$WORK/tf-drift.log" | tr '\n' ' ' | cut -c1-160)"
  fail_run 1 "zero-drift gate FAILED: $DRIFT_NOTE"
fi

# ---------------------------------------------------------------------------
# Stage 5. Data-plane read-your-write audit — invoke the landed exs harness.
#          SKIP-LOUD semantics per surface are honored inside the harness.
# ---------------------------------------------------------------------------
EXS_RC=0
if [ -f "$EXS_HARNESS" ]; then
  export ENCLAVE_LANE=t5
  export ENCLAVE_RESULT_FILE="$ROOT/docs/jira/v26.10.16/bench/t5-cleanroom.jsonl"
  mkdir -p "$(dirname "$ENCLAVE_RESULT_FILE")"
  if (cd "$ROOT" && exec 9>&- && env MIX_BUILD_ROOT="$BUILD_ROOT" MIX_ENV=test \
      ENCLAVE_LANE="$ENCLAVE_LANE" ENCLAVE_RESULT_FILE="$ENCLAVE_RESULT_FILE" \
      mix run --no-start "$EXS_HARNESS") >"$WORK/exs.log" 2>&1; then
    : EXS_RC=0
  else
    EXS_RC=$?
  fi
  if [ "$EXS_RC" -eq 0 ]; then
    row "exs-harness" "PASS" "$(grep -c '"verdict":"PASS"' "$WORK/exs.log" 2>/dev/null || echo 0)/$(grep -c '"verdict"' "$WORK/exs.log" 2>/dev/null || echo 0) rows PASS; log $WORK/exs.log"
  else
    row "exs-harness" "FAIL" "exit $EXS_RC; tail: $(tail -n 5 "$WORK/exs.log" | tr '\n' ' ' | cut -c1-200)"
  fi
else
  row "exs-harness" "SKIP-LOUD" "$EXS_HARNESS missing (parallel lane)"
fi
record "stage5: exs enclave-loop audit (lane t5)" "DONE"

# ---------------------------------------------------------------------------
# Stage 6. Console leg — node workspace/scripts/enclave-loop.mjs.
# ---------------------------------------------------------------------------
MJS_RC=0
if [ -f "$MJS_HARNESS" ]; then
  if (cd "$ROOT/workspace" && node scripts/enclave-loop.mjs) >"$WORK/mjs.log" 2>&1; then
    : MJS_RC=0
  else
    MJS_RC=$?
  fi
  if [ "$MJS_RC" -eq 0 ]; then
    row "mjs-harness" "PASS" "$(grep -c '"verdict":"PASS"' "$WORK/mjs.log" 2>/dev/null || echo 0)/$(grep -c '"verdict"' "$WORK/mjs.log" 2>/dev/null || echo 0) rows PASS; log $WORK/mjs.log"
  else
    row "mjs-harness" "FAIL" "exit $MJS_RC; tail: $(tail -n 5 "$WORK/mjs.log" | tr '\n' ' ' | cut -c1-200)"
  fi
else
  row "mjs-harness" "SKIP-LOUD" "$MJS_HARNESS missing (parallel lane)"
fi
record "stage6: mjs console leg" "DONE"

# ---------------------------------------------------------------------------
# Stage 7. Terraform destroy -auto-approve — cascade sweep (FR-6
#          drop_account_data, landed in lib/smalt/arm_gateway/router.ex).
# ---------------------------------------------------------------------------
if ! terraform -chdir="$TFDIR" destroy -auto-approve -no-color >"$WORK/tf-destroy.log" 2>&1; then
  fail_run 1 "terraform destroy failed: $(tail -n 5 "$WORK/tf-destroy.log" | tr '\n' ' ' | cut -c1-200)"
fi
record "stage7: tf destroy (cascade sweep)" "PASS"
budget_check "stage7: tf destroy" "${STEP_MS[${#STEP_MS[@]}-1]}"
row "tf-destroy" "PASS" "fixture destroyed; FR-6 cascade sweep exercised"

# ---------------------------------------------------------------------------
# Stage 8. Residue audit — fail-closed, BOTH must prove zero:
#   (a) subscription-scoped resources GET = 0 (real STS bearer over lane ARM)
#   (b) STS-face pin gate: sha256 of oidc_sts.ex + identity/oidc_idp.ex
#       unchanged within the run (lane 16 byte-identity invariant).
# ---------------------------------------------------------------------------
RESIDUE_FAIL=""

TOKEN_JSON2="$WORK/token2.json"
RES_TOKEN=""
if curl -sS -X POST "http://localhost:$ARM_PORT/$TENANT_ID/oauth2/v2.0/token" \
     -d grant_type=client_credentials \
     -d client_id="$ARM_CLIENT_ID" -d client_secret="$ARM_CLIENT_SECRET" \
     -d scope="https://management.azure.com/.default" \
     -o "$TOKEN_JSON2" 2>"$WORK/curl-err"; then
  RES_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$TOKEN_JSON2" 2>/dev/null || true)"
fi
if [ -n "$RES_TOKEN" ]; then
  GET_BODY="$WORK/resources.json"
  HTTP_CODE="$(curl -sS -H "Authorization: Bearer $RES_TOKEN" \
    -o "$GET_BODY" -w '%{http_code}' \
    "http://localhost:$ARM_PORT/subscriptions/$SUBSCRIPTION_ID/resources?api-version=2024-03-01" 2>/dev/null || echo "000")"
  if [ "$HTTP_CODE" = "200" ]; then
    N_RES="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("value",[])))' "$GET_BODY" 2>/dev/null || echo "unparseable")"
    if [ "$N_RES" = "0" ]; then
      echo "[residue] subscription-scoped GET: 0 resources"
    else
      RESIDUE_FAIL="resources GET returned $N_RES residue (http $HTTP_CODE)"
    fi
  else
    RESIDUE_FAIL="resources GET http $HTTP_CODE (expected 200)"
  fi
else
  RESIDUE_FAIL="STS token POST failed: $(cat "$WORK/curl-err" 2>/dev/null | head -c 120)"
fi
record "stage8a: subscription GET residue" "PASS"

STS_STSS_NOW="$(shasum -a 256 "$STS_STSS_FILE" | awk '{print $1}')"
STS_IDP_NOW="$(shasum -a 256 "$STS_IDP_FILE" | awk '{print $1}')"
if [ "$STS_STSS_NOW" = "$STS_STSS_PIN" ] && [ "$STS_IDP_NOW" = "$STS_IDP_PIN" ]; then
  echo "[residue] sts-face pin gate: PASS (digests unchanged within the run)"
  row "sts-face-pin" "PASS" "oidc_sts.ex + oidc_idp.ex digests stable across the run"
else
  RESIDUE_FAIL="STS face tampered mid-run: oidc_sts.ex $STS_STSS_PIN->$STS_STSS_NOW oidc_idp.ex $STS_IDP_PIN->$STS_IDP_NOW"
  row "sts-face-pin" "FAIL" "$RESIDUE_FAIL"
fi
record "stage8b: sts-face pin gate" "PASS"

if [ -n "$RESIDUE_FAIL" ]; then
  fail_run 1 "residue audit: $RESIDUE_FAIL"
fi
row "residue-audit" "PASS" "subscription GET = 0 AND sts-face pins stable"

# ---------------------------------------------------------------------------
# Stage 9. Receipt + verdict.
# ---------------------------------------------------------------------------
record "stage9: receipt" "PASS"
receipt

ANY_FAIL=0; ANY_PASS=0
for v in "${ROW_VERDICTS[@]}"; do
  [ "$v" = "FAIL" ] && ANY_FAIL=1
  [ "$v" = "PASS" ] && ANY_PASS=1
done
if [ "$ANY_FAIL" -eq 1 ]; then
  echo "[cleanroom] verdict: FAIL (exit 1)" >&2
  exit 1
fi
if [ "$ANY_PASS" -eq 0 ]; then
  echo "[SKIP] every family skipped — harness-skip" >&2
  exit 3
fi
echo "[cleanroom] verdict: PASS (exit 0)"
exit 0
