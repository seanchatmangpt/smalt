#!/usr/bin/env zsh
# r2_state — adversarial state/isolation redteam against a live smalt substrate.
# Owns the substrate lifecycle: boots a fresh substrate with a slow LRO delay
# (so PUT-during-LRO races are actually reachable), runs the node:test suite,
# kills the substrate, exits with the test status.
#
# Exit codes: 0 pass / 1 findings or test failure / 2 substrate never came up.
set -u
cd "$(dirname "$0")/../../.."   # repo root

# Dedicated port block (other lanes' substrates hold 9443/9444/8443/5672/5673).
ARM_PORT=39443
DATA_PORT=38443
TLS_PORT=39444
AMQP_PORT=35672
EH_PORT=35673
LOG=/tmp/smalt-r2-state-substrate.log
LRO_DELAY_MS=12000
RPORTS="$ARM_PORT $DATA_PORT $TLS_PORT $AMQP_PORT $EH_PORT"

try_connect() {
  node -e '
    const net = require("net");
    const s = net.connect({ host: "127.0.0.1", port: Number(process.argv[1]), timeout: 1500 });
    s.once("connect", () => { s.destroy(); process.exit(0); });
    s.once("timeout", () => { s.destroy(); process.exit(1); });
    s.once("error", () => process.exit(1));
  ' "$1"
}

reap_ports() {
  for p in $RPORTS; do
    lsof -ti tcp:$p 2>/dev/null | xargs kill -9 2>/dev/null
  done
}

# Wait until every r2_state port actually REFUSES connections (a killed beam's
# late-binding sibling, or TIME_WAIT holder, otherwise collides with the next boot).
await_ports_free() {
  for p in $ARM_PORT $DATA_PORT; do
    for i in $(seq 1 240); do
      try_connect $p || return 0
      reap_ports
      sleep 0.5
    done
  done
}

# --- pre-flight: kill leftovers of previous r2_state runs on our ports -------
for p in $ARM_PORT $DATA_PORT; do
  if try_connect $p; then
    echo "port $p occupied by a previous r2_state substrate — killing it" >&2
    reap_ports
    sleep 1
  fi
done
await_ports_free

up=0
for attempt in 1 2 3; do
  # NOTE: `mix run -e` evaluates AFTER app start, so ports must come from the
  # config-time SMALT_TEST_*_PORT env vars (config/test.exs); put_env in -e
  # would be too late for listeners. lro_delay_ms is read lazily per request,
  # so the -e put_env below is still effective for it.
  SMALT_TEST_ARM_PORT=$ARM_PORT \
  SMALT_TEST_ARM_TLS_PORT=$TLS_PORT \
  SMALT_TEST_EGRESS_PORT=$DATA_PORT \
  SMALT_TEST_AMQP_PORT=$AMQP_PORT \
  SMALT_TEST_EVENT_HUBS_PORT=$EH_PORT \
  MIX_ENV=test mix run --no-halt \
    --eval 'Application.put_env(:smalt, :lro_delay_ms, '"$LRO_DELAY_MS"')' \
    > "$LOG" 2>&1 &
  SUB_PID=$!

  trap 'kill -9 $SUB_PID 2>/dev/null; reap_ports; wait $SUB_PID 2>/dev/null' EXIT INT TERM

  up=0
  for i in $(seq 1 900); do
    if try_connect $ARM_PORT && try_connect $DATA_PORT; then
      # TCP accepting is not alive: require an HTTP answer from the ARM plane.
      if curl -sf -o /dev/null "http://127.0.0.1:$ARM_PORT/tenants"; then up=1; break; fi
    fi
    # NOTE: no kill -0 early exit — the mix(1) shell wrapper exits after
    # spawning beam.smp, so SUB_PID may vanish while the substrate boots fine.
    sleep 0.5
  done
  if [ "$up" -eq 1 ]; then break; fi

  echo "boot attempt $attempt failed — reaping our ports and retrying" >&2
  reap_ports
  await_ports_free
  reap_ports
  sleep 2
done
if [ "$up" -ne 1 ]; then
  echo "substrate did not come up after 3 attempts; log: $LOG" >&2
  tail -40 "$LOG" >&2
  exit 2
fi
echo "substrate up (pid $SUB_PID, lro_delay_ms=$LRO_DELAY_MS)"

node --test test/redteam/r2_state/state.test.mjs
rc=$?

# mix(1) wraps beam.smp: kill the actual listener, not just the wrapper.
kill -9 $SUB_PID 2>/dev/null
reap_ports
wait $SUB_PID 2>/dev/null
trap - EXIT INT TERM
echo "substrate log: $LOG"
exit $rc
