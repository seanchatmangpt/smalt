#!/usr/bin/env bash
# R1 input fuzz runner — owns the full substrate lifecycle, fail-closed receipt.
# Usage: test/redteam/r1_input_fuzz/run.sh
# Boot: mix run --no-halt (starts Smalt.Application: Bandit 9443 + 9444 TLS
# twin + 8443 egress + AmqpBroker 5672/5673). Waits for readiness, runs the
# node test suite, tears the substrate down, then emits a receipt whose exit
# code is nonzero unless BOTH (a) the test run passed and (b) findings.md
# was written.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
cd "$REPO"

LOG="$HERE/substrate.log"
RECEIPT="$HERE/receipt.txt"
rm -f "$LOG" "$RECEIPT"

cleanup() {
  if [[ -n "${SUB_PID:-}" ]] && kill -0 "$SUB_PID" 2>/dev/null; then
    kill "$SUB_PID" 2>/dev/null
    wait "$SUB_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

echo "[run.sh] booting smalt substrate (9443/8443/5672/5673)..." >&2
mix run --no-halt >"$LOG" 2>&1 &
SUB_PID=$!

# Readiness gate: all four surfaces must answer before fuzzing.
ready() {
  curl -s -o /dev/null -m 3 http://127.0.0.1:9443/metadata/endpoints &&
    curl -s -o /dev/null -m 3 http://127.0.0.1:8443/keys &&
    (exec 3<>/dev/tcp/127.0.0.1/5672) 2>/dev/null &&
    (exec 3<>/dev/tcp/127.0.0.1/5673) 2>/dev/null
}

UP=0
for _ in $(seq 1 90); do
  if ready; then UP=1; break; fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[run.sh] FATAL: substrate process died during boot" >&2
    tail -20 "$LOG" >&2
    exit 2
  fi
  sleep 1
done

if [[ "$UP" != 1 ]]; then
  echo "[run.sh] FATAL: substrate not ready after 90s" >&2
  tail -20 "$LOG" >&2
  exit 2
fi
echo "[run.sh] substrate up; running fuzz suite" >&2

RESULT=0
node --test "$HERE/fuzz.test.mjs" 2>&1 | tee "$HERE/fuzz-output.log"
RESULT=${PIPESTATUS[0]}

if [[ ! -s "$HERE/findings.md" ]]; then
  echo "[run.sh] FATAL: findings.md missing/empty (reporter did not run)" >&2
  RESULT=1
fi

{
  echo "R1 input fuzz receipt — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "substrate: pid $SUB_PID, log $LOG"
  echo "node --test exit: $RESULT"
  echo "checks + findings: see findings.md"
  if [[ "$RESULT" == 0 ]]; then
    echo "PASS (fail-closed receipt: tests green AND findings.md written)"
  else
    echo "FAIL"
  fi
} >"$RECEIPT"

cat "$RECEIPT"
exit "$RESULT"
