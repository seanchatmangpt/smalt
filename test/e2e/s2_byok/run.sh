#!/usr/bin/env bash
# test/e2e/s2_byok/run.sh — S2 BYOK custody chain e2e runner.
#
# Boots a live smalt substrate (MIX_ENV=test) with the MAA attestation
# baseline registered (config path: Application env :maa_measurement_baseline;
# the hex64 measurement is injected post-boot via `mix run -e`), waits for the
# egress (8443) + ARM (9443) listeners, runs byok.test.mjs, tears down.
#
# Exit codes: 0 pass / 1 test failure / 2 substrate never came up / 3 harness
# failure (ports occupied, spawn error).
set -u

# Anonymous-mode substrate (config/test.exs) — matches s10/s5: the SKR release
# path verifies the MAA token itself (RS256 via Attestation.verify_token); in
# enforce mode the STS bearer guard refuses RS256 MAA tokens before SKR runs.
export MIX_ENV=test

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$REPO/test/e2e/s2_byok"
LOG_DIR="$HERE/.logs"
mkdir -p "$LOG_DIR"

# Own ports (defaults chosen in the 28xxx/29xxx band to coexist with other
# lanes' substrates on 8443/9443 and 28443/29443).
ARM_PORT="${SMALT_BYOK_ARM_PORT:-29453}"
ARM_TLS_PORT="${SMALT_BYOK_ARM_TLS_PORT:-29454}"
EGRESS_PORT="${SMALT_BYOK_EGRESS_PORT:-28453}"
AMQP_PORT="${SMALT_BYOK_AMQP_PORT:-26720}"
EH_PORT="${SMALT_BYOK_EH_PORT:-26721}"
POLL_DEADLINE_S=120

MEASUREMENT="${SMALT_BYOK_MEASUREMENT:-$(printf 'ab%.0s' $(seq 1 32))}"
export SMALT_BYOK_MEASUREMENT="$MEASUREMENT"

log() { echo "[byok-run] $*"; }

port_up() {
  nc -z -w 2 127.0.0.1 "$1" 2>/dev/null
}

# 1. Ports must be free before boot.
for port in "$ARM_PORT" "$EGRESS_PORT"; do
  if port_up "$port"; then
    echo "[byok-run] port $port is occupied. Remediation: lsof -ti tcp:$port | xargs kill -9" >&2
    exit 3
  fi
done

# 2. Boot the substrate with ports + attestation baseline registered.
#    --no-start + ensure_all_started lets the -e eval set Application env
#    (ports, baseline) BEFORE the app supervision tree starts; Attestation
#    reads the baseline per request, so this is the config-path registration.
LOG="$LOG_DIR/substrate.log"
log "booting substrate (MIX_ENV=test, egress=$EGRESS_PORT arm=$ARM_PORT, measurement ${MEASUREMENT:0:12}...) log=$LOG"
mix run --no-start --no-halt -e "Application.put_env(:smalt, :arm_port, ${ARM_PORT}); Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT}); Application.put_env(:smalt, :egress_port, ${EGRESS_PORT}); Application.put_env(:smalt, :amqp_port, ${AMQP_PORT}); Application.put_env(:smalt, :event_hubs_port, ${EH_PORT}); Application.put_env(:smalt, :maa_measurement_baseline, [\"${MEASUREMENT}\"]); {:ok, _} = Application.ensure_all_started(:smalt); Process.sleep(:infinity)" \
  >"$LOG" 2>&1 &
SUB_PID=$!

cleanup() {
  kill -9 "$SUB_PID" 2>/dev/null
  wait "$SUB_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# 3. Poll for the listeners.
start=$(date +%s)
while :; do
  if port_up "$EGRESS_PORT" && port_up "$ARM_PORT"; then
    break
  fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "[byok-run] substrate process exited during boot. Log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  if [ $(( $(date +%s) - start )) -gt "$POLL_DEADLINE_S" ]; then
    echo "[byok-run] substrate did not open $ARM_PORT/$EGRESS_PORT within ${POLL_DEADLINE_S}s. Log tail:" >&2
    tail -40 "$LOG" >&2
    exit 2
  fi
  sleep 1
done
log "substrate up on $ARM_PORT/$EGRESS_PORT"

# 4. Run the custody chain.
SMALT_SDK_ROOT="${SMALT_SDK_ROOT:-$REPO/test/sdk-full/node_modules}" \
  SMALT_EGRESS_BASE="http://127.0.0.1:$EGRESS_PORT" \
  SMALT_ARM_BASE="http://127.0.0.1:$ARM_PORT" \
  node --test "$HERE/byok.test.mjs"
CODE=$?

case "$CODE" in
  0) log "ALL BYOK STEPS PASS" ;;
  *) log "BYOK FAILED (node exit $CODE — failing step listed above)" ;;
esac
exit "$CODE"
