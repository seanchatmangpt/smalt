#!/usr/bin/env bash
# run.sh — s3_pipeline e2e court. Boots its own substrate, runs the document
# pipeline chain over real wire surfaces, always tears down (trap).
# Exit codes: 0 pass / 1 test failure / 2 substrate never came up / 3 harness failure.
set -u

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HERE/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/substrate.log"

ARM_PORT=9443
EGRESS_PORT=8443

port_busy() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

# Wait (bounded) for other lanes' transient substrates to release the ports.
FREE_AT=""
for i in $(seq 1 240); do
  if ! port_busy "$ARM_PORT" && ! port_busy "$EGRESS_PORT"; then
    FREE_AT=$i
    break
  fi
  sleep 0.5
done
if [ -z "$FREE_AT" ]; then
  echo "[s3_pipeline] ports $ARM_PORT/$EGRESS_PORT still occupied after 120s. Remediation: lsof -ti tcp:$ARM_PORT | xargs kill -9" >&2
  exit 3
fi
[ "$FREE_AT" -gt 1 ] && echo "[s3_pipeline] ports free after $((FREE_AT / 2))s (another lane's substrate released them)"

CHILD_PID=""
cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -9 "$CHILD_PID" 2>/dev/null
    wait "$CHILD_PID" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

# Boot substrate exactly like the T3 harness does (foreground VM, MIX_ENV=test).
(cd "$REPO" && MIX_ENV=test SMALT_TEST_ARM_PORT=9443 SMALT_TEST_ARM_TLS_PORT=9444 SMALT_TEST_EGRESS_PORT=8443 SMALT_TEST_AMQP_PORT=5672 SMALT_TEST_EVENT_HUBS_PORT=5673 mix run --no-halt >"$LOG" 2>&1) &
CHILD_PID=$!

echo "[s3_pipeline] substrate booting (pid $CHILD_PID, log $LOG)"
DEADLINE=$((SECONDS + 90))
for i in $(seq 1 180); do
  if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "[s3_pipeline] substrate process exited early. Log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  if port_busy "$ARM_PORT" && port_busy "$EGRESS_PORT"; then
    echo "[s3_pipeline] substrate up on $ARM_PORT/$EGRESS_PORT after ${i}x500ms"
    break
  fi
  if [ $i -eq 180 ]; then
    echo "[s3_pipeline] substrate did not open $ARM_PORT/$EGRESS_PORT within 90s. Log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  sleep 0.5
done

node --test "$HERE/pipeline.test.mjs"
STATUS=$?
echo "[s3_pipeline] node --test exit: $STATUS"
exit $STATUS
