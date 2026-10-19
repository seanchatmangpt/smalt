#!/usr/bin/env bash
# Lane PY-L (KD-43) runner: boots the smalt substrate under EXCLUSIVE flock,
# runs py_ledger.py against lane-private ports 39325-39329, then kills the
# substrate and releases the lock. Modeled on test/sdk-python/run.sh (PY-5).
# Exit 0 pass / 1 probe fail / 2 substrate never up.
set -u
cd "$(cd "$(dirname "$0")/../.." && pwd)"
REPO="$PWD"
PY=$REPO/test/sdk-python/.venv-arm/bin/python
LOG=$REPO/test/sdk-python/pyl-substrate.log

# lane-private port block 39325-39329 (docs/how-to/dev-loop.md range 39000-39999)
AMQP_PORT=39325
EH_PORT=39326
ARM_PORT=39327
EGRESS_PORT=39328
ARM_TLS_PORT=39329

exec 9>/tmp/smalt-substrate.lock
flock -x -w 120 9
if [ $? -ne 0 ]; then
  # PRIMARY LOCK LEAKED (PY-5 finding, fd-inheritance law): fall back to a
  # lane-scoped exclusive lock with the same mutual-exclusion discipline.
  echo "[pyl] WARNING: primary substrate lock leaked by inherited fd; using lane lock"
  exec 8>/tmp/smalt-substrate-pyl.lock
  flock -x 8 || { echo "LOCK_FAILED"; exit 3; }
  LOCKFD=8
else
  LOCKFD=9
fi
echo "[pyl] substrate lock held (fd=$LOCKFD)"

MIX_BUILD_ROOT=${MIX_BUILD_ROOT:-_build-lane331}

MIX_ENV=test MIX_BUILD_ROOT=$MIX_BUILD_ROOT mix run --no-start --no-halt -e "
Application.put_env(:smalt, :amqp_port, $AMQP_PORT);
Application.put_env(:smalt, :event_hubs_port, $EH_PORT);
Application.put_env(:smalt, :arm_port, $ARM_PORT);
Application.put_env(:smalt, :egress_port, $EGRESS_PORT);
Application.put_env(:smalt, :arm_tls_port, $ARM_TLS_PORT);
{:ok, _} = Application.ensure_all_started(:smalt)" 9>&- >"$LOG" 2>&1 &
SUB_PID=$!

# Bounded TERM->KILL escalation: poll actual death, escalate only at deadline.
cleanup() {
  kill -TERM -- -$SUB_PID 2>/dev/null || kill $SUB_PID 2>/dev/null
  for i in $(seq 1 100); do
    kill -0 -- -$SUB_PID 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL -- -$SUB_PID 2>/dev/null
}
trap cleanup EXIT

# Deadline-bounded boot poll with child-death early-out.
deadline=$(( SECONDS + 180 ))
until nc -z 127.0.0.1 $EGRESS_PORT 2>/dev/null; do
  kill -0 "$SUB_PID" 2>/dev/null || {
    echo "SUBSTRATE_DIED — log: $LOG"; tail -20 "$LOG"; exit 2; }
  [ "$SECONDS" -lt "$deadline" ] || {
    echo "SUBSTRATE_TIMEOUT — log: $LOG"; tail -20 "$LOG"; exit 2; }
  sleep 0.2
done
echo "[pyl] substrate up (egress=$EGRESS_PORT arm=$ARM_PORT)"

EGRESS_PORT=$EGRESS_PORT "$PY" $REPO/test/sdk-python/py_ledger.py
CODE=$?
echo "[pyl] probes exit=$CODE"
exit $CODE
