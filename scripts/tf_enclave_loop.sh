#!/usr/bin/env bash
# scripts/tf_enclave_loop.sh — executor wrapper for the enclave loop lane
# (v26.10.16, T5-adjacent). Boots a lane-PRIVATE smalt substrate on the
# 39370-39375 block, runs the Elixir + Node enclave-loop harnesses, applies
# and destroys the terraform fixture against the private substrate, then
# proves zero residue (subscription-scoped resources GET = 0 + empty-graph
# plan) before printing a per-family row receipt.
#
# Stages:
#   1. preflight          terraform binary, fixture dir, harness files, port block free
#   2. substrate          private boot (bench_boot/tf_plan_check pattern, lock fd closed,
#                         MIX_BUILD_ROOT=_build-lane354, SMALT_TLS_CERTFILE/KEYFILE)
#   3. exs-harness        scripts/bench/enclave_loop.exs   (mix run --no-start)
#   4. mjs-harness        workspace/scripts/enclave-loop.mjs (node)
#   5. tf-apply/destroy   init + plan + apply, then destroy -auto-approve
#   6. residue audit      subscription-scoped GET => value:[] AND plan -detailed-exitcode 0
#   7. receipt + teardown per-family PASS/SKIP-LOUD/FAIL, timing per stage
#
# Exit codes: 0 all PASS-or-SKIP / 1 any FAIL / 3 harness-skip (loud).
# SKIP is loud, never a fake pass: every skip prints "[SKIP] <reason>".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/test/terraform_fixture"
EXS_HARNESS="$ROOT/scripts/bench/enclave_loop.exs"
MJS_HARNESS="$ROOT/workspace/scripts/enclave-loop.mjs"
WORK="$(mktemp -d /tmp/tf-enclave-loop.XXXXXX)"
SUB_LOG="$WORK/substrate.log"
PID_FILE="$WORK/substrate.pid"

# Lane port block (lane 37 by the 39000+10N law, documented here as 354's block):
# ARM, ARM-TLS twin, egress/data, amqp, event_hubs, mcp.
ARM_PORT=39370
ATLS_PORT=39371
EGRESS_PORT=39372
AMQP_PORT=39373
EHUB_PORT=39374
MCP_PORT=39375
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
TENANT_ID="00000000-0000-0000-0000-000000000000"

# ---------------------------------------------------------------------------
# Receipt bookkeeping — per-family verdict rows + per-stage monotonic timing.
# ---------------------------------------------------------------------------
declare -a ROW_NAMES=() ROW_VERDICTS=() ROW_NOTES=()
declare -a STEP_NAMES=() STEP_MS=()

now_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 10**6)' 2>/dev/null \
    || echo $(( SECONDS * 1000 ))
}
LAST_T="$(now_ms)"

tick() { STEP_NAMES+=("$1"); local t; t="$(now_ms)"; STEP_MS+=("$(( t - LAST_T ))"); LAST_T="$t"; }

row() { # row <family> <PASS|SKIP-LOUD|FAIL> <note>
  ROW_NAMES+=("$1"); ROW_VERDICTS+=("$2"); ROW_NOTES+=("$3")
  printf '[%s] %s — %s\n' "$2" "$1" "$3"
}

receipt() {
  echo
  echo "============== ENCLAVE LOOP RECEIPT =============="
  echo "-- stages (monotonic elapsed) --"
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-34s %8sms\n' "${STEP_NAMES[$i]}" "${STEP_MS[$i]:-?}"
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
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      pkill -TERM -P "$pid" 2>/dev/null || true # children first (beam under mix)
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -P "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  # Wait for the port block to actually free (up to 15s).
  for _ in $(seq 1 30); do
    any_lane_port_held || break
    sleep 0.5
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
    sleep 0.5
  done
  for p in $LANE_PORTS; do
    for b in $(port_holders "$p"); do
      kill -9 "$b" 2>/dev/null || true
    done
  done
  sleep 1
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
  row "harness" "FAIL" "$2"
  receipt
  exit "$1"
}

# ---------------------------------------------------------------------------
# 1. Preflight. Missing tool/harness => loud SKIP of the whole run (exit 3);
#    a held port is a collision FAIL (1), not a skip.
# ---------------------------------------------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  row "terraform" "SKIP-LOUD" "terraform binary not on PATH"
  receipt; exit 3
fi
tick "preflight: terraform binary"

if [ ! -d "$FIXTURE" ]; then
  row "terraform" "SKIP-LOUD" "fixture dir missing: $FIXTURE"
  receipt; exit 3
fi
tick "preflight: fixture dir"

if [ ! -f "$ROOT/mix.exs" ]; then
  row "harness" "SKIP-LOUD" "no mix.exs at $ROOT — not the smalt checkout"
  receipt; exit 3
fi

MISSING_HARNESSES=""
[ -f "$EXS_HARNESS" ] || MISSING_HARNESSES="$EXS_HARNESS"
[ -f "$MJS_HARNESS" ] || MISSING_HARNESSES="$MISSING_HARNESSES $MJS_HARNESS"
if [ -n "${MISSING_HARNESSES// /}" ]; then
  echo "[SKIP] enclave harness files not present yet (parallel lane):$MISSING_HARNESSES" >&2
fi
tick "preflight: harness files"

for p in $ARM_PORT $ATLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    fail_run 1 "port $p already held — refusing to boot (collision)"
  fi
done
tick "preflight: lane ports $ARM_PORT-$MCP_PORT free"

# ---------------------------------------------------------------------------
# 2. Private substrate — mirrors scripts/tf_plan_check.sh (bench_boot pattern):
#    MIX_ENV=test, SMALT_TLS_CERTFILE/KEYFILE, lock fd closed (9>&-), private
#    MIX_BUILD_ROOT so concurrent lanes never share _build.
# ---------------------------------------------------------------------------
# Lane-368 validation fix (disclosed): concurrent lanes re-mint .smalt/tls
# every ~10 min. A substrate pins the cert AT BOOT while terraform re-reads
# ca-cert.pem LATER — a mid-run re-mint desyncs them and the provider dies on
# x509 "not trusted". Snapshot the pair + CA into this run's $WORK and point
# every consumer (substrate env, SSL_CERT_FILE) at the immutable snapshots.
CERT_SNAP="$WORK/tls-snapshot"
mkdir -p "$CERT_SNAP"
snap_pair_ok() {
  local c k
  c=$(openssl x509 -in "$CERT_SNAP/dev-cert.pem" -noout -modulus 2>/dev/null | openssl md5)
  k=$(openssl rsa -in "$CERT_SNAP/dev-key.pem" -noout -modulus 2>/dev/null | openssl md5)
  # Chain proof: the leaf must chain to the snapshot CA. A modulus match on a
  # SELF-SIGNED leaf (legacy minter rewrites dev-cert.pem, witnessed 11:48)
  # is not enough — Go clients reject a self-signed end-entity outright.
  [ -n "$c" ] && [ "$c" = "$k" ] \
    && openssl verify -CAfile "$CERT_SNAP/ca-cert.pem" "$CERT_SNAP/dev-cert.pem" >/dev/null 2>&1
}
SNAP_OK=0
for _ in 1 2 3 4 5; do
  cp "$ROOT/.smalt/tls/dev-cert.pem" "$ROOT/.smalt/tls/dev-key.pem" "$CERT_SNAP/"
  cp "$ROOT/.smalt/tls/ca-cert.pem" "$CERT_SNAP/"
  if snap_pair_ok; then SNAP_OK=1; break; fi
  # Self-heal: the checkout's dev-cert.pem was reverted to a legacy self-signed
  # CN=127.0.0.1 leaf — re-mint the CA-chained pair and retry the snapshot.
  bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
  rm -f "$ROOT/.smalt/tls/dev-cert.pem" "$ROOT/.smalt/tls/dev-key.pem"
  bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null 2>&1 || true
  sleep 2
done
if [ "$SNAP_OK" -ne 1 ]; then
  fail_run 1 "tls snapshot: no chain-verified cert/key pair after self-heal (re-mint churn) — refusing to boot against a self-signed leaf"
fi
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
    MIX_BUILD_ROOT=_build-lane354 \
    SMALT_TLS_CERTFILE="$CERT_SNAP/dev-cert.pem" \
    SMALT_TLS_KEYFILE="$CERT_SNAP/dev-key.pem" \
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
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "[FAULT] substrate never bound $ARM_PORT within 120s; log tail:" >&2
  tail -n 40 "$SUB_LOG" >&2
  fail_run 1 "substrate bind timeout on $ARM_PORT"
fi
tick "substrate up: ARM $ARM_PORT"

up=0
for _ in $(seq 1 60); do
  if lsof -nP -iTCP:"$ATLS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then up=1; break; fi
  sleep 1
done
[ "$up" -eq 1 ] || fail_run 1 "TLS twin never bound $ATLS_PORT"
tick "substrate up: TLS twin $ATLS_PORT"

# ---------------------------------------------------------------------------
# Env for harnesses + terraform: same authority routing as scripts/smalt-tf,
# port-shifted to the lane block. Exported so the exs/mjs harnesses inherit.
# ---------------------------------------------------------------------------
export ARM_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_RESOURCE_MANAGER_AUDIENCE="https://management.azure.com"
# SHIM-COURT lane fix (2026-10-16): pin 127.0.0.1, not localhost — azurerm
# resolves localhost to [::1] and dials IPv6 while the TLS twin binds
# 127.0.0.1 (witnessed connection refused on lane runs). https scheme means
# azidentity's localhost-only http allowance is not exercised; cert SAN has
# IP:127.0.0.1.
export ARM_METADATA_HOSTNAME="127.0.0.1:$ATLS_PORT"
export SSL_CERT_FILE="$CERT_SNAP/ca-cert.pem"
export AZURE_AUTHORITY_HOST="https://127.0.0.1:$ATLS_PORT/"
export AZAPI_ARM_ENDPOINT="http://localhost:$ARM_PORT"
export AZAPI_ARM_RESOURCE_MANAGER_ENDPOINT="http://localhost:$ARM_PORT"
export ARM_USE_MSI="false"
export ARM_CLIENT_ID="00000000-0000-0000-0000-000000000000"
export ARM_CLIENT_SECRET="smalt-sovereign-mock-secret"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_TENANT_ID="$TENANT_ID"
# Lane-dispatch fix (SHIM-COURT-free lane edit, disclosed): the harnesses
# (enclave_loop.exs / enclave-loop.mjs) read SMALT_TEST_*_PORT — those must be
# exported here in the parent shell too, or they fall back to the GLOBAL
# substrate (9443/8443) and validate the wrong tree (witnessed: run 1/2 mjs
# minted from 127.0.0.1:9443 while the lane substrate held 39370).
export SMALT_TEST_ARM_PORT=$ARM_PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT
export SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT
export SMALT_TEST_MCP_PORT=$MCP_PORT SMALT_TEST_ARM_TLS_PORT=$ATLS_PORT
export SMALT_ARM_PORT=$ARM_PORT SMALT_EGRESS_PORT=$EGRESS_PORT \
       SMALT_AMQP_PORT=$AMQP_PORT SMALT_EVENT_HUBS_PORT=$EHUB_PORT \
       SMALT_MCP_PORT=$MCP_PORT SMALT_ARM_TLS_PORT=$ATLS_PORT
export TF_IN_AUTOMATION=1

# Zero-touch trust shim (2026-10-16 operator ruling): the SHIM-PROBE stage —
# build the shim + probe, run the probe (go build + direct exec, never `go run`:
# cmd/go strips DYLD_* from the child env), THEN export the env for the
# terraform stages. Keychain trust is INFORMATIONAL only — never mutated.
# Fail-closed: shim-unbuildable or probe-fail is a typed FAIL, not a skip
# (the native tier needs none of this — informational note on the failure).
if [ "$(uname)" = "Darwin" ]; then
  SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
  if [ ! -f "$SHIM_DYLIB" ]; then
    bash "$ROOT/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$SHIM_DYLIB" ]; then
    fail_run 1 "SHIM-PROBE: trust shim dylib could not be built ($SHIM_DYLIB) — run scripts/trust_shim/build.sh (native tier needs no shim)"
  elif [ ! -f "$CERT_SNAP/dev-cert.pem" ]; then
    fail_run 1 "SHIM-PROBE: no leaf cert at $CERT_SNAP/dev-cert.pem — run scripts/gen_dev_cert.sh"
  else
    # H1 fix: pin the EXACT LEAF (dev-cert.pem), not the CA.
    SMALT_LEAF_SHA256="$(openssl x509 -in "$CERT_SNAP/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    CA_FP="$(openssl x509 -in "$CERT_SNAP/ca-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    PROBE_BIN="$(mktemp -t smalt_probe)" && mv "$PROBE_BIN" "$PROBE_BIN.bin" && PROBE_BIN="$PROBE_BIN.bin"
    if ! (cd "$ROOT/test/trust_shim_probe" && go build -o "$PROBE_BIN" .); then
      fail_run 1 "SHIM-PROBE: trust_shim_probe could not be built (go build failed — native tier needs no shim)"
    elif (DYLD_INSERT_LIBRARIES="$SHIM_DYLIB" \
          SMALT_LEAF_SHA256="$SMALT_LEAF_SHA256" SMALT_CA_SHA256="$CA_FP" \
          SMALT_CA_FILE="$CERT_SNAP/ca-cert.pem" \
          "$PROBE_BIN" -tls-dir "$CERT_SNAP" -want=pass); then
      export SMALT_LEAF_SHA256
      export SMALT_CA_FILE="$CERT_SNAP/ca-cert.pem" # v2: anchor-append surface
      export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
      echo "[enclave-loop] SHIM-PROBE PASS — shim env exported (pinned leaf fp ${SMALT_LEAF_SHA256:0:16}...)"
    else
      rc=$?
      fail_run 1 "SHIM-PROBE FAILED (exit $rc) — Security.framework rejected the pinned chain (native tier needs no shim; optional opt-in persistent trust: scripts/tf_trust_setup.sh trust)"
    fi
    rm -f "$PROBE_BIN" 2>/dev/null || true
  fi
  if bash "$ROOT/scripts/tf_trust_setup.sh" status >/dev/null 2>&1; then
    echo "[enclave-loop] keychain trust (informational): trusted"
  else
    echo "[enclave-loop] keychain trust (informational): not trusted — optional opt-in persistent alternative only, never a gate"
  fi
fi

# Offline provider mirror wiring, same rule as tf_smoke/tf_plan_check: pin to
# the one-time mirror only when it exists; otherwise registry + typed network
# failure.
FIXTURE_RC="$FIXTURE/provider-mirror.rc"
if [ -f "$FIXTURE_RC" ] && [ -d "$FIXTURE/provider-mirror" ]; then
  export TF_CLI_CONFIG_FILE="$FIXTURE_RC"
  echo "[enclave-loop] offline mirror active: TF_CLI_CONFIG_FILE=$TF_CLI_CONFIG_FILE"
fi
tick "env wiring (mirror + SMALT_* exports)"

# ---------------------------------------------------------------------------
# 3. Elixir enclave-loop harness — real subprocess, verdict rows on stdout.
# ---------------------------------------------------------------------------
EXS_RC=0
if [ -f "$EXS_HARNESS" ]; then
  # Registry law (scripts/bench/REGISTRY.md): this lane is e1, not the harness's
  # c9 default — pin lane id + result file before invoking.
  export ENCLAVE_LANE=e1
  export ENCLAVE_RESULT_FILE="$ROOT/docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl"
  mkdir -p "$(dirname "$ENCLAVE_RESULT_FILE")"
  if (cd "$ROOT" && exec 9>&- && env MIX_BUILD_ROOT=_build-lane354 MIX_ENV=test \
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
  row "exs-harness" "SKIP-LOUD" "$EXS_HARNESS missing"
fi
tick "exs enclave loop"

# ---------------------------------------------------------------------------
# 4. Node enclave-loop harness.
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
  row "mjs-harness" "SKIP-LOUD" "$MJS_HARNESS missing"
fi
tick "mjs enclave loop"

# ---------------------------------------------------------------------------
# 5. Terraform: init + plan + apply in a scratch dir, then destroy. The
#    apply exists so destroy is a real transition, not a no-op on empty state.
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
tick "tf init"

if ! terraform -chdir="$TFDIR" plan -input=false -no-color -out=tfplan >"$WORK/tf-plan.log" 2>&1; then
  fail_run 1 "terraform plan failed: $(tail -n 5 "$WORK/tf-plan.log" | tr '\n' ' ' | cut -c1-200)"
fi
grep -q "to add" "$WORK/tf-plan.log" || fail_run 1 "plan ok but no 'to add' summary"
tick "tf plan ($(grep -oE '[0-9]+ to add' "$WORK/tf-plan.log" | head -1))"

if ! terraform -chdir="$TFDIR" apply -auto-approve -no-color tfplan >"$WORK/tf-apply.log" 2>&1; then
  # azurerm's create-then-exists double-check ("already exists ... needs to be
  # imported") — witnessed on a provably fresh substrate (GET 404 -> PUT 201 ->
  # GET 200). Recover: destroy the half-applied graph and re-apply once.
  if grep -q "already exists" "$WORK/tf-apply.log"; then
    echo "[enclave-loop] apply hit already-exists double-check; destroy + retry"
    terraform -chdir="$TFDIR" destroy -auto-approve -no-color >>"$WORK/tf-apply.log" 2>&1 || true
    # Destroy invalidated the saved plan — re-plan before re-apply.
    if ! terraform -chdir="$TFDIR" plan -input=false -no-color -out=tfplan >>"$WORK/tf-apply.log" 2>&1; then
      fail_run 1 "terraform re-plan (post-destroy) failed: $(tail -n 5 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
    fi
    if terraform -chdir="$TFDIR" apply -auto-approve -no-color tfplan >>"$WORK/tf-apply.log" 2>&1; then
      : retry ok
    else
      fail_run 1 "terraform apply failed (post-retry): $(tail -n 5 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
    fi
  else
    fail_run 1 "terraform apply failed: $(tail -n 5 "$WORK/tf-apply.log" | tr '\n' ' ' | cut -c1-200)"
  fi
fi
tick "tf apply"

if ! terraform -chdir="$TFDIR" destroy -auto-approve -no-color >"$WORK/tf-destroy.log" 2>&1; then
  fail_run 1 "terraform destroy failed: $(tail -n 5 "$WORK/tf-destroy.log" | tr '\n' ' ' | cut -c1-200)"
fi
tick "tf destroy"
row "terraform" "PASS" "init/plan/apply/destroy round-trip on lane substrate $ARM_PORT"

# ---------------------------------------------------------------------------
# 6. Residue audit — fail-closed: BOTH must prove zero.
#    (a) subscription-scoped resources GET over the private ARM front door
#        with a real STS bearer token => value: []
#    (b) terraform plan -detailed-exitcode on the destroyed state => 0
# ---------------------------------------------------------------------------
RESIDUE_FAIL=""

TOKEN_JSON="$WORK/token.json"
if curl -sS -X POST "http://localhost:$ARM_PORT/$TENANT_ID/oauth2/v2.0/token" \
     -d grant_type=client_credentials \
     -d client_id="$ARM_CLIENT_ID" -d client_secret="$ARM_CLIENT_SECRET" \
     -d scope="https://management.azure.com/.default" \
     -o "$TOKEN_JSON" 2>"$WORK/curl-err"; then
  TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$TOKEN_JSON" 2>/dev/null || true)"
  if [ -n "${TOKEN:-}" ]; then
    GET_BODY="$WORK/resources.json"
    HTTP_CODE="$(curl -sS -H "Authorization: Bearer $TOKEN" \
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
    RESIDUE_FAIL="STS token response carried no access_token"
  fi
else
  RESIDUE_FAIL="STS token POST failed: $(cat "$WORK/curl-err" 2>/dev/null | head -c 120)"
fi
tick "residue: subscription GET"

if terraform -chdir="$TFDIR" plan -detailed-exitcode -input=false -no-color >"$WORK/tf-residue.log" 2>&1; then
  echo "[residue] post-destroy plan: empty graph (exit 0)"
else
  rc=$?
  RESIDUE_FAIL="${RESIDUE_FAIL:+$RESIDUE_FAIL; }post-destroy plan exit $rc (expected 0/empty)"
fi
tick "residue: post-destroy plan"

if [ -n "$RESIDUE_FAIL" ]; then
  fail_run 1 "residue audit: $RESIDUE_FAIL"
fi
row "residue-audit" "PASS" "subscription GET = 0 resources AND post-destroy plan empty"

# ---------------------------------------------------------------------------
# 7. Receipt + verdict.
# ---------------------------------------------------------------------------
tick "receipt"
receipt

ANY_FAIL=0
ANY_PASS=0
for v in "${ROW_VERDICTS[@]}"; do
  [ "$v" = "FAIL" ] && ANY_FAIL=1
  [ "$v" = "PASS" ] && ANY_PASS=1
done
if [ "$ANY_FAIL" -eq 1 ]; then
  exit 1
fi
if [ "$ANY_PASS" -eq 0 ]; then
  echo "[SKIP] every family skipped — harness-skip" >&2
  exit 3
fi
exit 0
