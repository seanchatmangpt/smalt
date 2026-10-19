#!/usr/bin/env bash
set -euo pipefail

# Terraform parity smoke for the smalt sovereign substrate.
# Boots the substrate, runs init/plan/apply/destroy against the fixture via
# scripts/smalt-tf, and prints an honest per-step receipt.
#
# Exit codes:
#   0  all steps passed
#   1  preflight or substrate failure
#   2  terraform step failure (init/plan/apply/destroy)
#   77 SKIPPED-NETWORK: provider download from registry.terraform.io failed

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/scripts/tf_fixtures"
# Port overrides (lane-concurrency fix, 2026-10-16): the shared substrate
# holds 9443/9444, so a concurrent tf_smoke must be able to shift lanes.
# Defaults unchanged: SMALT_TF_PORT=9443, SMALT_TLS_PORT=9444. Sibling data
# ports derive from SMALT_TF_PORT so the lane-private substrate never
# collides with the shared one (mirrors tf_plan_check.sh's 39330-39335 shift).
PORT="${SMALT_TF_PORT:-9443}"
TLS_PORT="${SMALT_TLS_PORT:-9444}"
EGRESS_PORT=$(( PORT + 2 ))
AMQP_PORT=$(( PORT + 3 ))
EHUB_PORT=$(( PORT + 4 ))
MCP_PORT=$(( PORT + 5 ))
SUBSTRATE_LOG="/tmp/smalt-tf-smoke-substrate.log"
STEP_LOG="/tmp/smalt-tf-smoke-step.log"
PLAN_OUT="/tmp/smalt-plan.out"
PID_FILE="/tmp/smalt-tf-smoke.pid"

declare -a STEP_NAMES=()
declare -a STEP_STATUS=()
declare -a STEP_MS=()

# Monotonic ms clock (python3 when present, $SECONDS fallback on Darwin).
now_ms() {
  python3 -c 'import time; print(time.monotonic_ns() // 10**6)' 2>/dev/null \
    || echo $(( SECONDS * 1000 ))
}
LAST_T="$(now_ms)"

record() { # step_name, status — appends per-step monotonic elapsed_ms
  local now
  now="$(now_ms)"
  STEP_NAMES+=("$1")
  STEP_STATUS+=("$2")
  STEP_MS+=("$(( now - LAST_T ))")
  LAST_T="$now"
}

# Budget gate: apply/destroy must complete under SMALT_TF_STEP_BUDGET_S
# (default 30s). Fail-closed — an over-budget step FAILs, never warns.
budget_check() { # step_name, elapsed_ms
  # 300s: the substrate's LRO/provisioning pacing makes a real storage-account
  # create take ~3 min (witnessed 178s); the historical 30s default predates
  # the reset-era provisioning model. SMALT_TF_STEP_BUDGET_S still overrides.
  local budget_s="${SMALT_TF_STEP_BUDGET_S:-300}"
  if [ "$2" -gt $(( budget_s * 1000 )) ]; then
    fail_step "$1" 2 "step exceeded ${budget_s}s budget (${2}ms)"
  fi
}

receipt() {
  echo
  echo "================ TF SMOKE RECEIPT ================"
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-32s %-16s %sms\n' "${STEP_NAMES[$i]}" "${STEP_STATUS[$i]}" "${STEP_MS[$i]:-?}"
  done
  echo "=================================================="
}

fail_step() { # step_name, exit_code, message
  record "$1" "FAIL"
  echo "[FAULT] $3" >&2
  receipt
  exit "$2"
}

cleanup() {
  # M8: temp rc + refresh log are runtime artifacts — always removed.
  if declare -F tf_mirror_env_cleanup >/dev/null; then tf_mirror_env_cleanup; fi
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      # Bounded reap poll: escalate to -9 only after the pid is observed
      # dead (or a 10s deadline expires) — never a fixed settle sleep.
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded reap poll, 10s deadline)
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}
trap cleanup EXIT

# ---------- 1. preflight ----------
if ! command -v terraform >/dev/null 2>&1; then
  fail_step "preflight: terraform binary" 1 "terraform binary not on PATH"
fi
record "preflight: terraform binary" "PASS"

if [ ! -d "$FIXTURE" ]; then
  fail_step "preflight: fixture dir" 1 "$FIXTURE missing"
fi
record "preflight: fixture dir" "PASS"

for p in $PORT $TLS_PORT $EGRESS_PORT $AMQP_PORT $EHUB_PORT $MCP_PORT; do
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then
    fail_step "preflight: port $p free" 1 "port $p already in use"
  fi
done
record "preflight: ports $PORT/$TLS_PORT free" "PASS"

# ---------- 1b. SHIM-PROBE (zero-touch trust, 2026-10-16 operator ruling) ----------
# Build the trust shim + probe, run the probe (go build + direct exec, never
# `go run`: cmd/go strips DYLD_* from the child env), then export the shim env
# so the terraform stages inherit it. The automated ladder NEVER requires
# interactive trust; keychain status is INFORMATIONAL only. Fail-closed:
# shim-unbuildable or probe-fail is a typed FAIL (the native tier needs none
# of this — informational note on the failure).
if [ "$(uname)" = "Darwin" ]; then
  SHIM_DYLIB="$ROOT/scripts/trust_shim/smalt_trust_shim.dylib"
  if [ ! -f "$SHIM_DYLIB" ]; then
    bash "$ROOT/scripts/trust_shim/build.sh" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$SHIM_DYLIB" ]; then
    fail_step "shim-probe: dylib built" 1 "trust shim dylib could not be built ($SHIM_DYLIB) — run scripts/trust_shim/build.sh (native tier needs no shim)"
  elif [ ! -f "$ROOT/.smalt/tls/dev-cert.pem" ]; then
    fail_step "shim-probe: leaf cert" 1 "no leaf cert at $ROOT/.smalt/tls/dev-cert.pem — run scripts/gen_dev_cert.sh"
  else
    # H1 fix: pin the EXACT LEAF (dev-cert.pem), not the CA.
    SMALT_LEAF_SHA256="$(openssl x509 -in "$ROOT/.smalt/tls/dev-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    CA_FP="$(openssl x509 -in "$ROOT/.smalt/tls/ca-cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':')"
    PROBE_BIN="$(mktemp -t smalt_probe)" && mv "$PROBE_BIN" "$PROBE_BIN.bin" && PROBE_BIN="$PROBE_BIN.bin"
    if ! (cd "$ROOT/scripts/trust_shim_probe" && go build -o "$PROBE_BIN" .); then
      fail_step "shim-probe: probe built" 1 "trust_shim_probe go build failed (native tier needs no shim)"
    elif (DYLD_INSERT_LIBRARIES="$SHIM_DYLIB" \
          SMALT_LEAF_SHA256="$SMALT_LEAF_SHA256" SMALT_CA_SHA256="$CA_FP" \
          SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" \
          "$PROBE_BIN" -tls-dir "$ROOT/.smalt/tls" -want=pass); then
      export SMALT_LEAF_SHA256
      export SMALT_CA_FILE="$ROOT/.smalt/tls/ca-cert.pem" # v2: anchor-append surface
      export DYLD_INSERT_LIBRARIES="$SHIM_DYLIB"
      record "shim-probe (Security.framework, pinned leaf)" "PASS"
      echo "[tf-smoke] SHIM-PROBE PASS — shim env exported (pinned leaf fp ${SMALT_LEAF_SHA256:0:16}...)"
    else
      rc=$?
      fail_step "shim-probe (Security.framework, pinned leaf)" 1 "SHIM-PROBE FAILED (exit $rc) — native tier needs no shim; optional opt-in persistent trust: scripts/tf_trust_setup.sh trust"
    fi
    rm -f "$PROBE_BIN" 2>/dev/null || true
    if bash "$ROOT/scripts/tf_trust_setup.sh" status >/dev/null 2>&1; then
      echo "[tf-smoke] keychain trust (informational): trusted"
    else
      echo "[tf-smoke] keychain trust (informational): not trusted — optional opt-in persistent alternative only, never a gate"
    fi
  fi
else
  record "shim-probe (non-darwin, SSL_CERT_FILE)" "SKIP"
fi

# ---------- 2. boot substrate ----------
# Lane-private boot (mirrors scripts/tf_plan_check.sh): explicit put_env of
# every listener port so a SMALT_TF_PORT-shifted lane never touches the
# shared substrate's ports.
bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null
: > "$SUBSTRATE_LOG"
EVAL="Application.put_env(:smalt, :arm_port, $PORT); \
Application.put_env(:smalt, :egress_port, $EGRESS_PORT); \
Application.put_env(:smalt, :amqp_port, $AMQP_PORT); \
Application.put_env(:smalt, :event_hubs_port, $EHUB_PORT, persistent: true); \
Application.put_env(:smalt, :mcp_port, $MCP_PORT); \
Application.put_env(:smalt, :arm_tls_port, $TLS_PORT); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"
(cd "$ROOT" && MIX_ENV=test \
  SMALT_TEST_ARM_PORT=$PORT SMALT_TEST_EGRESS_PORT=$EGRESS_PORT \
  SMALT_TEST_AMQP_PORT=$AMQP_PORT SMALT_TEST_EVENT_HUBS_PORT=$EHUB_PORT \
  SMALT_TLS_CERTFILE="$ROOT/.smalt/tls/dev-cert.pem" \
  SMALT_TLS_KEYFILE="$ROOT/.smalt/tls/dev-key.pem" \
  exec mix run --no-start -e "$EVAL" --no-halt 9>&-) >"$SUBSTRATE_LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"
echo "[tf-smoke] lane substrate: ARM $PORT, TLS $TLS_PORT, egress $EGRESS_PORT, amqp $AMQP_PORT, ehub $EHUB_PORT, mcp $MCP_PORT"

up=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then up=1; break; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[FAULT] substrate process exited before binding $PORT; log tail:" >&2
    tail -n 40 "$SUBSTRATE_LOG" >&2
    fail_step "substrate bound $PORT <=30s" 1 "substrate process died"
  fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded nc bind poll, 30x1s deadline)
done

if [ "$up" -ne 1 ]; then
  echo "[FAULT] substrate never bound $PORT within 30s; log tail:" >&2
  tail -n 40 "$SUBSTRATE_LOG" >&2
  fail_step "substrate bound $PORT <=30s" 1 "bind timeout"
fi
record "substrate bound $PORT <=30s" "PASS"

up=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$TLS_PORT" 2>/dev/null; then up=1; break; fi
  sleep 1 # SLEEP-CLASS: POLL-STEP (bounded nc bind poll, 30x1s deadline)
done
if [ "$up" -ne 1 ]; then
  echo "[FAULT] substrate never bound TLS port $TLS_PORT within 30s; log tail:" >&2
  tail -n 40 "$SUBSTRATE_LOG" >&2
  fail_step "substrate bound $TLS_PORT <=30s" 1 "TLS bind timeout"
fi
record "substrate bound $TLS_PORT <=30s" "PASS"

# ---------- 3. terraform ----------
# Env now lives in scripts/smalt-tf (ARM_SKIP_PROVIDER_REGISTRATION removed
# there: azurerm 4.x hard-rejects it with resource_provider_registrations="none").
cd "$FIXTURE"

# Offline provider install (M7/M8): refresh + re-validate the mirror every
# run (scripts/tf_provider_mirror.sh; online-revalidated or offline-trusted,
# loudly) and generate the TF_CLI_CONFIG_FILE rc at run time into a temp path
# (scripts/tf_mirror_env.sh) — no absolute rc is ever committed. If refresh
# fails outright, fall through to the registry path and the exit-77
# SKIPPED-NETWORK branch below.
source "$ROOT/scripts/tf_mirror_env.sh"
if tf_mirror_env_setup; then
  record "provider mirror (${TF_MIRROR_MODE})" "PASS"
else
  echo "[tf-smoke] no usable mirror — falling through to registry install" >&2
fi

tf() {
  TF_LOG="${TF_LOG:-}" "$ROOT/scripts/smalt-tf" "$@"
}

if ! tf init -input=false -no-color >"$STEP_LOG" 2>&1; then
  if grep -qiE "dial tcp: lookup|no such host|i/o timeout|connection refused|Failed to query available provider packages|could not connect to registry" "$STEP_LOG"; then
    record "tf init (provider download)" "SKIPPED-NETWORK"
    echo "[SKIP] registry.terraform.io unreachable; init error tail:" >&2
    tail -n 20 "$STEP_LOG" >&2
    receipt
    exit 77
  fi
  echo "[FAULT] terraform init failed; log tail:" >&2
  tail -n 40 "$STEP_LOG" >&2
  fail_step "tf init (provider download)" 2 "init failed"
fi
record "tf init (provider download)" "PASS"

# ---------- 4. plan ----------
if ! tf plan -input=false -no-color -out=plan.tfplan >"$PLAN_OUT" 2>&1; then
  record "token POST landed on substrate" "UNKNOWN"
  echo "[FAULT] terraform plan failed; output tail:" >&2
  tail -n 40 "$PLAN_OUT" >&2
  fail_step "tf plan (3 to add)" 2 "plan command failed"
fi
if ! grep -q "3 to add" "$PLAN_OUT"; then
  echo "[FAULT] plan succeeded but did not report '3 to add'; output tail:" >&2
  tail -n 40 "$PLAN_OUT" >&2
  fail_step "tf plan (3 to add)" 2 "plan assertion failed"
fi
record "tf plan (3 to add)" "PASS"

# ---------- 5. apply ----------
# Apply runs WITHOUT the saved plan: the provider-wrap lane rewrites the
# dependency lock after plan (h1 entries for wrapped binaries), so a saved
# plan fails the "Inconsistent dependency lock file" check. A fresh apply
# re-plans under the current (wrapped) selections — the smoke's purpose is
# the full upstream lifecycle, not saved-plan portability.
if ! tf apply -auto-approve -no-color >"$STEP_LOG" 2>&1; then
  echo "[FAULT] terraform apply failed; output tail:" >&2
  tail -n 40 "$STEP_LOG" >&2
  fail_step "tf apply" 2 "apply failed"
fi
record "tf apply" "PASS"
budget_check "tf apply" "${STEP_MS[${#STEP_MS[@]}-1]}"

# ---------- 6. destroy ----------
if ! tf destroy -auto-approve -no-color >"$STEP_LOG" 2>&1; then
  echo "[FAULT] terraform destroy failed; output tail:" >&2
  tail -n 40 "$STEP_LOG" >&2
  fail_step "tf destroy" 2 "destroy failed"
fi
record "tf destroy" "PASS"
budget_check "tf destroy" "${STEP_MS[${#STEP_MS[@]}-1]}"

# ---------- 7. kill substrate ----------
cleanup
record "kill substrate" "PASS"

receipt
exit 0
