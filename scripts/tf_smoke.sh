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
FIXTURE="$ROOT/test/terraform_fixture"
PORT=9443
SUBSTRATE_LOG="/tmp/smalt-tf-smoke-substrate.log"
STEP_LOG="/tmp/smalt-tf-smoke-step.log"
PLAN_OUT="/tmp/smalt-plan.out"
PID_FILE="/tmp/smalt-tf-smoke.pid"

declare -a STEP_NAMES=()
declare -a STEP_STATUS=()

record() {
  STEP_NAMES+=("$1")
  STEP_STATUS+=("$2")
}

receipt() {
  echo
  echo "================ TF SMOKE RECEIPT ================"
  for i in "${!STEP_NAMES[@]}"; do
    printf '%-32s %s\n' "${STEP_NAMES[$i]}" "${STEP_STATUS[$i]}"
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
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
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

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  fail_step "preflight: port $PORT free" 1 "port $PORT already in use"
fi
record "preflight: port $PORT free" "PASS"

# ---------- 2. boot substrate ----------
bash "$ROOT/scripts/gen_dev_cert.sh" >/dev/null
: > "$SUBSTRATE_LOG"
(cd "$ROOT" && SMALT_TLS_CERTFILE="$ROOT/.smalt/tls/dev-cert.pem" \
  SMALT_TLS_KEYFILE="$ROOT/.smalt/tls/dev-key.pem" exec mix run --no-halt) >"$SUBSTRATE_LOG" 2>&1 &
SUB_PID=$!
echo "$SUB_PID" > "$PID_FILE"

up=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then up=1; break; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[FAULT] substrate process exited before binding $PORT; log tail:" >&2
    tail -n 40 "$SUBSTRATE_LOG" >&2
    fail_step "substrate bound $PORT <=30s" 1 "substrate process died"
  fi
  sleep 1
done

if [ "$up" -ne 1 ]; then
  echo "[FAULT] substrate never bound $PORT within 30s; log tail:" >&2
  tail -n 40 "$SUBSTRATE_LOG" >&2
  fail_step "substrate bound $PORT <=30s" 1 "bind timeout"
fi
record "substrate bound $PORT <=30s" "PASS"

up=0
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 9444 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "[FAULT] substrate never bound TLS port 9444 within 30s; log tail:" >&2
  tail -n 40 "$SUBSTRATE_LOG" >&2
  fail_step "substrate bound 9444 <=30s" 1 "TLS bind timeout"
fi
record "substrate bound 9444 <=30s" "PASS"

# ---------- 3. terraform ----------
# Env now lives in scripts/smalt-tf (ARM_SKIP_PROVIDER_REGISTRATION removed
# there: azurerm 4.x hard-rejects it with resource_provider_registrations="none").
cd "$FIXTURE"
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
if ! tf apply -auto-approve -no-color plan.tfplan >"$STEP_LOG" 2>&1; then
  echo "[FAULT] terraform apply failed; output tail:" >&2
  tail -n 40 "$STEP_LOG" >&2
  fail_step "tf apply" 2 "apply failed"
fi
record "tf apply" "PASS"

# ---------- 6. destroy ----------
if ! tf destroy -auto-approve -no-color >"$STEP_LOG" 2>&1; then
  echo "[FAULT] terraform destroy failed; output tail:" >&2
  tail -n 40 "$STEP_LOG" >&2
  fail_step "tf destroy" 2 "destroy failed"
fi
record "tf destroy" "PASS"

# ---------- 7. kill substrate ----------
cleanup
record "kill substrate" "PASS"

receipt
exit 0
