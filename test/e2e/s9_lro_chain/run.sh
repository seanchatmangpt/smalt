#!/usr/bin/env bash
# s9 LRO chain e2e harness. Boots its own substrate and runs the raw-wire
# chain in lro_chain.ems — see lro_chain.test.mjs header. Port policy: if
# 9443/8443 are occupied (another lane's substrate), boot an ISOLATED
# substrate on alternate ports (arm 19443 / tls 19444 / egress 18443 / amqp
# 15672 / eventhubs 15673) via --no-start env overrides rather than failing
# or killing another lane's process.
#
# Exit codes: 0 pass / 1 test failure / 2 substrate never came up / 3 harness
# failure.
set -u

REPO="${SMALT_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HERE/.logs"
DEADLINE=$((SECONDS + 120))

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/substrate.log"

port_busy() {
  nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
}

MODE=default
ARM_PORT=9443
if port_busy 9443 || port_busy 8443; then
  MODE=isolated
  ARM_PORT=19443
fi

echo "[s9-lro-chain] mode=$MODE arm=$ARM_PORT log=$LOG"

if [ "$MODE" = default ]; then
  ( cd "$REPO" && MIX_ENV=test mix run --no-halt >"$LOG" 2>&1 ) &
else
  ( cd "$REPO" && MIX_ENV=test mix run --no-start -e 'Application.put_env(:smalt, :arm_port, 19443); Application.put_env(:smalt, :arm_tls_port, 19444); Application.put_env(:smalt, :egress_port, 18443); Application.put_env(:smalt, :amqp_port, 15672); Application.put_env(:smalt, :event_hubs_port, 15673)' --no-halt >"$LOG" 2>&1 ) &
fi
SUB_PID=$!

cleanup() {
  kill -9 "$SUB_PID" 2>/dev/null
  pkill -9 -P "$SUB_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

if ! kill -0 "$SUB_PID" 2>/dev/null; then
  echo "[s9-lro-chain] mix spawn failed" >&2
  exit 3
fi

while ! port_busy "$ARM_PORT"; do
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[s9-lro-chain] substrate died during boot; log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "[s9-lro-chain] substrate did not open $ARM_PORT within 120s; log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  sleep 1
done
echo "[s9-lro-chain] substrate up on $ARM_PORT"

cd "$REPO"
set +e
SMALT_ARM="http://127.0.0.1:$ARM_PORT" node --test "$HERE/lro_chain.test.mjs"
CODE=$?
set -u

if [ "$CODE" -eq 0 ]; then
  echo "[s9-lro-chain] PASS"
else
  echo "[s9-lro-chain] FAIL (node --test exit $CODE)"
fi
exit "$CODE"
