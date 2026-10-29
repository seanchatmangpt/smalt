#!/usr/bin/env bash
# demo_migration_rehearsal.sh — T26 one-command Fortune-5 demo:
# end-to-end migration rehearsal against the LIVE substrate.
#
#   scan -> generate -> inject  (smalt-cli migrate all)
#   verify                      (smalt-cli migrate verify)
#
# Contract:
#   - Substrate DOWN  -> loud typed [SKIP] line per stage, NEVER a fake pass,
#     NEVER boots the substrate (lanes don't restart the shared substrate).
#     Exit 2.
#   - Harness-skip (venv/CLI missing) -> loud typed [SKIP], exit 3.
#   - Any stage fails -> typed table + REHEARSAL-FAIL, exit 3.
#   - All stages ok   -> typed table + REHEARSAL-PASS, exit 0.
#
# Zero-egress is inherited from the verify gate itself (REQ-4.2: every wire
# request rides WireSession.wire(); host set asserted 127.0.0.1-only).
#
# Usage: scripts/demo_migration_rehearsal.sh [iac-dir] [workdir]
set -u
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
IAC_DIR="${1:-$REPO/smalt-cli/tests/fixtures/migrate-enterprise}"
WORK="${2:-$(mktemp -d /tmp/t26-rehearsal.XXXXXX)}"
CLI_PY="$REPO/smalt-cli/.venv-cli/bin/python"
CLI_DIR="$REPO/smalt-cli"

emit()  { printf '%s\n' "$*"; }
fail3() { emit "[rehearsal] REHEARSAL-FAIL ($1)"; exit 3; }

# --- stage registry (typed per-stage table) -------------------------------
STAGES=(scan generate inject verify)
declare -A S_STATUS S_DETAIL

# --- preflight 1: harness (loud SKIP, exit 3) ------------------------------
if [[ ! -x "$CLI_PY" ]]; then
  for s in "${STAGES[@]}"; do
    emit "[$s] SKIP: harness — $CLI_PY not executable (run: python3 -m venv $REPO/smalt-cli/.venv-cli && $CLI_PY -m pip install -e $CLI_DIR)"
  done
  emit "[rehearsal] REHEARSAL-SKIP harness-missing"
  exit 3
fi
if [[ ! -d "$IAC_DIR" ]]; then
  for s in "${STAGES[@]}"; do
    emit "[$s] SKIP: harness — fixture missing: $IAC_DIR"
  done
  emit "[rehearsal] REHEARSAL-SKIP fixture-missing"
  exit 3
fi

# --- preflight 2: substrate DOWN -> loud per-stage SKIP, exit 2 ------------
# Observe, don't guess: ARM plane 9443 must answer (any HTTP code, incl 401).
ARM_PROBE_URL="${ARM_PROBE_URL:-http://127.0.0.1:9443/}"
ARM_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ARM_PROBE_URL" 2>/dev/null)"
if [[ -z "$ARM_CODE" || "$ARM_CODE" == "000" ]]; then
  for s in "${STAGES[@]}"; do
    emit "[$s] SKIP: substrate-down — ARM plane 9443 not answering (probe=000/no-answer); NOT booting (lane never restarts the shared substrate)"
  done
  emit "[rehearsal] REHEARSAL-SKIP substrate-down"
  exit 2
fi

emit "[rehearsal] substrate UP (ARM 9443 probe=$ARM_CODE); iac=$IAC_DIR"
emit "[rehearsal] workdir=$WORK"

run_py() { (cd "$CLI_DIR" && "$CLI_PY" -m smalt_cli.cli "$@"); }

# --- stage: scan+generate+inject via `migrate all` (typed per-stage lines) --
ALL_OUT="$(run_py migrate all --iac-dir "$IAC_DIR" --output-dir "$WORK/out" --target "$WORK/.env.smalt" 2>&1)"
ALL_RC=$?
parse_stage() { # $1=stage name -> sets S_STATUS/S_DETAIL from ALL_OUT
  local line
  line="$(printf '%s\n' "$ALL_OUT" | grep -m1 "^\[$1\] " || true)"
  if [[ -n "$line" ]]; then
    S_STATUS["$1"]="$(printf '%s' "$line" | sed -E 's/^\[[a-z]+\] ([^:]+):.*/\1/')"
    S_DETAIL["$1"]="$(printf '%s' "$line" | sed -E 's/^\[[a-z]+\] [^:]+: //')"
  else
    S_STATUS["$1"]="missing"
    S_DETAIL["$1"]="no typed line from migrate all (rc=$ALL_RC)"
  fi
}
for s in scan generate inject; do parse_stage "$s"; done

# --- stage: verify (wire-fidelity gate, exit 1 on check failure) -----------
VERIFY_OUT="$(run_py migrate verify --services blob,cosmos,kv,servicebus --out "$WORK/migration-receipt.json" 2>&1)"
VERIFY_RC=$?
if [[ $VERIFY_RC -eq 0 ]]; then
  S_STATUS["verify"]="ok"
  ZE="$(printf '%s' "$VERIFY_OUT" | grep -m1 '"zero_egress"')"
  S_DETAIL["verify"]="zero_egress line: ${ZE:-n/a}; receipt=$WORK/migration-receipt.json"
else
  S_STATUS["verify"]="failed"
  S_DETAIL["verify"]="verify rc=$VERIFY_RC (see $WORK/migration-receipt.json)"
fi

# --- typed per-stage table + verdict ---------------------------------------
emit ""
emit "| stage    | status | detail |"
emit "|----------|--------|--------|"
for s in "${STAGES[@]}"; do
  emit "| $s | ${S_STATUS[$s]} | ${S_DETAIL[$s]} |"
done
emit ""

FAIL=0
for s in "${STAGES[@]}"; do
  [[ "${S_STATUS[$s]}" == "ok" ]] || FAIL=1
done
if [[ $FAIL -eq 0 && $ALL_RC -eq 0 ]]; then
  emit "[rehearsal] REHEARSAL-PASS stages=4/4 iac=$IAC_DIR workdir=$WORK"
  exit 0
fi
fail3 "stages=$(
  for s in "${STAGES[@]}"; do printf '%s=%s ' "$s" "${S_STATUS[$s]}"; done
)"
