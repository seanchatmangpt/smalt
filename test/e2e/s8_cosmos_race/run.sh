#!/usr/bin/env bash
# S8 Cosmos optimistic-concurrency e2e chain runner.
#
# Boots its OWN substrate instance on private ports (18443 egress / 19443 ARM /
# 19444 ARM-TLS) via `mix run --no-start --no-halt -e` port overrides, so it
# never contends with a shared 8443/9443 substrate or other lanes' listeners.
# Runs race.py against that instance, then tears the instance down.
# Exit 0 only when every step in the race.py receipt is PASS.
set -u
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO="$(cd ../../.. && pwd)"

EGRESS_PORT=18443
ARM_PORT=19443
SUB_PID=""

port_up() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

wait_port() { # port deadline_s
  local deadline=$((SECONDS + $2))
  until port_up "$1"; do
    if (( SECONDS >= deadline )); then return 1; fi
    sleep 1
  done
}

cleanup() {
  # mix wraps beam.smp; also free the private listeners so nothing leaks.
  kill -9 $SUB_PID 2>/dev/null
  pkill -9 -P $SUB_PID 2>/dev/null
  for p in $EGRESS_PORT $ARM_PORT 19444; do
    lsof -ti tcp:$p 2>/dev/null | xargs kill -9 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

# Private ports are ours by construction — clear any stale leftover listener
# (e.g. a half-booted previous run) so the identity gate can bind our instance.
for p in $EGRESS_PORT $ARM_PORT 19444 15672 15673; do
  lsof -ti tcp:$p 2>/dev/null | xargs kill -9 2>/dev/null
done
sleep 1

echo "[s8] booting own substrate on egress=$EGRESS_PORT arm=$ARM_PORT"
(cd "$REPO" && MIX_ENV=test mix run --no-start --no-halt -e '
  Application.put_env(:smalt, :egress_port, 18443)
  Application.put_env(:smalt, :arm_port, 19443)
  Application.put_env(:smalt, :arm_tls_port, 19444)
  Application.put_env(:smalt, :amqp_port, 15672)
  Application.put_env(:smalt, :event_hubs_port, 15673)
  {:ok, _} = Application.ensure_all_started(:smalt)
  Process.sleep(:infinity)' >"$HERE/s8_substrate.log" 5>&1) &
SUB_PID=$!

if ! wait_port "$EGRESS_PORT" 120 || ! wait_port "$ARM_PORT" 5; then
  echo "[s8] own substrate did not come up in 120s; log: $HERE/s8_substrate.log" >&2
  exit 2
fi

# Identity gate: the responder on $EGRESS_PORT must be our own instance, not a
# stray listener. Create a run-unique marker doc and require it to read back.
MARKER="s8-marker-$$"
curl -s -o /dev/null -X POST "http://127.0.0.1:$EGRESS_PORT/dbs/s8db/colls/s8coll/docs" \
  -H 'content-type: application/json' -d "{\"id\":\"$MARKER\",\"m\":1}"
FOUND=$(curl -s "http://127.0.0.1:$EGRESS_PORT/dbs/s8db/colls/s8coll/docs/$MARKER")
case "$FOUND" in
  *"$MARKER"*) echo "[s8] substrate identity confirmed via marker $MARKER" ;;
  *) echo "[s8] identity gate FAILED: marker not served on $EGRESS_PORT (found: $FOUND)" >&2; exit 2 ;;
esac
echo "[s8] substrate up"

"$HERE/.venv/bin/python" race.py "http://127.0.0.1:$EGRESS_PORT"
RC=$?
echo "[s8] chain exit=$RC"
exit "$RC"
