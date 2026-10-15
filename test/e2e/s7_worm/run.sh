#!/usr/bin/env bash
# s7_worm run.sh — boots the smalt substrate (mix run --no-halt, MIX_ENV=test),
# waits for ARM 9443 + egress 8443, then runs the WORM e2e suite against the
# live wire. Exit codes: 0 pass / 1 test failure / 2 substrate never came up /
# 3 harness failure (ports occupied, missing SDK root).
set -u
cd "$(dirname "$0")/../../.."   # repo root

PORTS=(9443 8443)
POLL_DEADLINE_S=60

port_busy() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

for p in "${PORTS[@]}"; do
  if port_busy "$p"; then
    echo "[s7_worm] port $p already serving — reusing live substrate"
    REUSE=1
  fi
done

SMALT_SDK_ROOT="${SMALT_SDK_ROOT:-/Users/sac/smalt/test/sdk-full/node_modules}"
export SMALT_SDK_ROOT
if [ ! -d "$SMALT_SDK_ROOT/@azure/storage-blob" ]; then
  echo "[s7_worm] SMALT_SDK_ROOT=$SMALT_SDK_ROOT has no @azure/storage-blob." >&2
  exit 3
fi

LOG_DIR="$(pwd)/test/e2e/s7_worm/.logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/substrate.log"

REUSE="${REUSE:-0}"
if [ "$REUSE" -ne 1 ]; then
  MIX_ENV=test mix run --no-halt >"$LOG" 2>&1 &
  SUBSTRATE_PID=$!
  trap 'kill -9 $SUBSTRATE_PID 2>/dev/null' EXIT INT TERM

  up=0
  for _ in $(seq 1 $((POLL_DEADLINE_S * 2))); do
    if port_busy 9443 && port_busy 8443; then up=1; break; fi
    if ! kill -0 "$SUBSTRATE_PID" 2>/dev/null; then
      echo "[s7_worm] substrate process exited early. Log: $LOG" >&2
      tail -40 "$LOG" >&2
      exit 2
    fi
    sleep 0.5
  done
  if [ "$up" -ne 1 ]; then
    echo "[s7_worm] substrate did not open 9443/8443 within ${POLL_DEADLINE_S}s. Log: $LOG" >&2
    exit 2
  fi
fi
echo "[s7_worm] substrate up on 9443/8443 (reuse=$REUSE)"

node --test test/e2e/s7_worm/
CODE=$?
echo "[s7_worm] suite exit $CODE"
exit $CODE
