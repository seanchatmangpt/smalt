#!/usr/bin/env bash
# Lane PY-ATLAS runner (KD-41 purview-atlas/py): boots a lane-private smalt
# substrate on ports 39320-39324 under an exclusive flock, runs the
# requests-based Atlas REST probes, then kills the substrate and releases the
# lock. Exit 0 iff all probes pass.
#
# Lock law (same-checkout-fanout #4): the substrate spawns with the lock fd
# CLOSED (9>&-) so the beam never inherits the flock.
set -u
cd "$(cd "$(dirname "$0")/../.." && pwd)"
REPO="$PWD"
PY=$REPO/test/sdk-python/.venv-eh/bin/python
LOG=$REPO/test/sdk-python/atlas-substrate.log

# lane-private port block 39320-39324
AMQP_PORT=39320
EH_PORT=39321
ARM_PORT=39322
EGRESS_PORT=39323
ARM_TLS_PORT=39324

exec 9>/tmp/smalt-substrate.lock
if ! flock -x -w 120 9; then
  echo "[atlas] WARNING: primary substrate lock unavailable; using lane lock"
  exec 8>/tmp/smalt-substrate-atlas.lock
  flock -x 8 || { echo "LOCK_FAILED"; exit 3; }
  LOCKFD=8
else
  LOCKFD=9
fi
echo "[atlas] substrate lock held (fd=$LOCKFD)"

MIX_ENV=test mix run --no-start --no-halt -e "
Application.put_env(:smalt, :amqp_port, $AMQP_PORT);
Application.put_env(:smalt, :event_hubs_port, $EH_PORT);
Application.put_env(:smalt, :arm_port, $ARM_PORT);
Application.put_env(:smalt, :egress_port, $EGRESS_PORT);
Application.put_env(:smalt, :arm_tls_port, $ARM_TLS_PORT);
{:ok, _} = Application.ensure_all_started(:smalt)" >"$LOG" 2>&1 9>&- &
SUB_PID=$!

cleanup() {
  kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
  sleep 1
  kill -KILL -- -$SUB_PID 2>/dev/null
}
trap cleanup EXIT

up=0
for i in $(seq 1 600); do
  if nc -z 127.0.0.1 $EGRESS_PORT 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ $up -ne 1 ]; then
  echo "SUBSTRATE_TIMEOUT — log: $LOG"; tail -20 "$LOG"; exit 2
fi
echo "[atlas] substrate up (egress=$EGRESS_PORT amqp=$AMQP_PORT)"

SMALT_EGRESS_BASE="http://127.0.0.1:$EGRESS_PORT" \
  "$PY" $REPO/test/sdk-python/py_atlas.py
CODE=$?
echo "[atlas] probes exit=$CODE"
exit $CODE
