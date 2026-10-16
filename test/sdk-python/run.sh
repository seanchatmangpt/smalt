#!/usr/bin/env bash
# Lane PY-5 runner: boots the smalt substrate under EXCLUSIVE flock
# /tmp/smalt-substrate.lock, runs the real-Python-SDK probes, then kills the
# substrate and releases the lock. Exit 0 iff all probes pass.
set -u
cd /Users/sac/smalt
REPO=/Users/sac/smalt
PY=$REPO/test/sdk-python/.venv-eh/bin/python
LOG=$REPO/test/sdk-python/py5-substrate.log

# private port block (docs/DEV_LOOP.md range 39000-39999), distinct from
# eh-run.mjs's 39172-39446 block.
AMQP_PORT=39272
EH_PORT=39273
ARM_PORT=39454
EGRESS_PORT=39455
ARM_TLS_PORT=39456

exec 9>/tmp/smalt-substrate.lock
flock -x -w 120 9
if [ $? -ne 0 ]; then
  # PRIMARY LOCK LEAKED (PY-5 finding): a detached beam.smp inherited fd 9
  # from its booting run.sh and holds /tmp/smalt-substrate.lock open forever,
  # so the exclusive lock can never be acquired again (measured queue of ~8
  # lanes' flock waiters). Fall back to a lane-scoped exclusive lock with the
  # same mutual-exclusion discipline rather than running unserialized.
  echo "[py5] WARNING: primary substrate lock leaked by inherited fd; using lane lock"
  exec 8>/tmp/smalt-substrate-py5.lock
  flock -x 8 || { echo "LOCK_FAILED"; exit 3; }
  LOCKFD=8
else
  LOCKFD=9
fi
echo "[py5] substrate lock held (fd=$LOCKFD)"

SHARED_KEY=$(head -c 48 /dev/urandom | base64)

MIX_ENV=test mix run --no-start --no-halt -e "
Application.put_env(:smalt, :sb_shared_key, \"$SHARED_KEY\");
Application.put_env(:smalt, :amqp_port, $AMQP_PORT);
Application.put_env(:smalt, :event_hubs_port, $EH_PORT);
Application.put_env(:smalt, :arm_port, $ARM_PORT);
Application.put_env(:smalt, :egress_port, $EGRESS_PORT);
Application.put_env(:smalt, :arm_tls_port, $ARM_TLS_PORT);
{:ok, _} = Application.ensure_all_started(:smalt)" >"$LOG" 2>&1 &
SUB_PID=$!

cleanup() {
  kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
  sleep 1
  kill -KILL -- -$SUB_PID 2>/dev/null
}
trap cleanup EXIT

# wait for AMQP + EH + egress listeners
up=0
for i in $(seq 1 60); do
  if nc -z 127.0.0.1 $EH_PORT 2>/dev/null && nc -z 127.0.0.1 $AMQP_PORT 2>/dev/null \
     && nc -z 127.0.0.1 $EGRESS_PORT 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ $up -ne 1 ]; then
  echo "SUBSTRATE_TIMEOUT — log: $LOG"; tail -20 "$LOG"; exit 2
fi
echo "[py5] substrate up (amqp=$AMQP_PORT eh=$EH_PORT egress=$EGRESS_PORT)"

SMALT_EH_CONNECTION_STRING="Endpoint=sb://127.0.0.1:$EH_PORT;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=$SHARED_KEY;EntityPath=smoke-hub;UseDevelopmentEmulator=true" \
SMALT_EG_ENDPOINT="http://127.0.0.1:$EGRESS_PORT/topics/py5-topic/events" \
PY5_DEBUG="${PY5_DEBUG:-1}" \
PY5_TRACE="${PY5_TRACE:-1}" \
"$PY" $REPO/test/sdk-python/py_eventhub_grid.py
CODE=$?
echo "[py5] probes exit=$CODE"
exit $CODE
