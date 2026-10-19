#!/usr/bin/env bash
# test/e2e/s5_sessions/run.sh — boot the smalt substrate, then run the
# ordered-session chain (sessions.test.cjs) against it.
#
# Exit codes: 0 pass / 1 test failure / 2 substrate never came up / 3 harness
# failure (ports occupied, env missing, spawn error).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LOG_DIR="$SCRIPT_DIR/.logs"
# Non-default ports: the canonical checkout's default 5672/9443 are held by
# another lane's long-running substrate; these are injected at boot via
# Application env (same pattern the other lanes use) so this probe owns its
# own substrate without touching anyone else's.
ARM_PORT=24443
AMQP_PORT=25678
ARM_TLS_PORT=24444
EGRESS_PORT=26443
EVENT_HUBS_PORT=26673
POLL_DEADLINE_S=60

mkdir -p "$LOG_DIR"

log() { echo "[s5-run] $*"; }
die() { echo "[s5-run] ERROR: $*" >&2; exit 3; }

# --- 1. Env: deterministic shared key + vendored SDK (dev_env.sh pattern) -----
if [ -d "$REPO/scripts" ] && [ -f "$REPO/scripts/dev_env.sh" ]; then
  eval "$(SMALT_REPO="$REPO" bash "$REPO/scripts/dev_env.sh")" || die "dev_env.sh failed"
else
  die "scripts/dev_env.sh not found under $REPO"
fi
[ -n "${SMALT_SB_SHARED_KEY:-}" ] || die "SMALT_SB_SHARED_KEY not exported"
[ -d "${SMALT_SDK_ROOT:-}" ] || die "SMALT_SDK_ROOT=$SMALT_SDK_ROOT not a directory"

# --- 2. Ports must be free before boot -----------------------------------------
for port in "$AMQP_PORT" "$ARM_PORT" "$ARM_TLS_PORT" "$EGRESS_PORT" "$EVENT_HUBS_PORT"; do
  if lsof -ti "tcp:$port" >/dev/null 2>&1; then
    echo "[s5-run] ERROR: port $port is occupied. Remediation: lsof -ti tcp:$port | xargs kill -9" >&2
    exit 3
  fi
done

# --- 3. api-version from Smalt.Registry (single source of truth) ---------------
log "reading api-version from Smalt.Registry"
API_VERSION="$(cd "$REPO" && SMALT_SB_SHARED_KEY="$SMALT_SB_SHARED_KEY" MIX_ENV=test \
  mix run --no-start -e 'IO.puts Smalt.Registry.latest_version("Microsoft.ServiceBus/namespaces") || raise "no api-version"' \
  | tail -n 1)"
case "$API_VERSION" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "Smalt.Registry returned no api-version (got '$API_VERSION')" ;;
esac
log "api-version=$API_VERSION"

# --- 4. Boot substrate (own boot + trap; key via census shared-key env pattern) -
log "booting substrate (MIX_ENV=test, key from SMALT_SB_SHARED_KEY env)"
LOG_PATH="$LOG_DIR/substrate.log"
: > "$LOG_PATH"
BOOT_EVAL="Application.put_env(:smalt, :sb_shared_key, \"${SMALT_SB_SHARED_KEY}\"); Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:${AMQP_PORT}\"); Application.put_env(:smalt, :amqp_port, ${AMQP_PORT}); Application.put_env(:smalt, :arm_port, ${ARM_PORT}); Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT}); Application.put_env(:smalt, :egress_port, ${EGRESS_PORT}); Application.put_env(:smalt, :event_hubs_port, ${EVENT_HUBS_PORT}); Logger.configure(level: :debug); {:ok, _} = Application.ensure_all_started(:smalt)"
MIX_ENV=test SMALT_SB_SHARED_KEY="$SMALT_SB_SHARED_KEY" \
  mix run --no-halt --no-start -e "$BOOT_EVAL" >"$LOG_PATH" 2>&1 &
SUBSTRATE_PID=$!

cleanup() {
  if kill -0 "$SUBSTRATE_PID" 2>/dev/null; then
    kill "$SUBSTRATE_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SUBSTRATE_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$SUBSTRATE_PID" 2>/dev/null || true
  fi
  # The beam may be a child of mix; make sure nothing survives on our ports.
  for port in "$AMQP_PORT" "$ARM_PORT" "$ARM_TLS_PORT" "$EGRESS_PORT" "$EVENT_HUBS_PORT"; do
    lsof -ti "tcp:$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# --- 5. Poll ports until the substrate accepts ----------------------------------
START=$(date +%s)
while :; do
  ARM_UP=0; AMQP_UP=0
  lsof -ti "tcp:$ARM_PORT" >/dev/null 2>&1 && ARM_UP=1
  lsof -ti "tcp:$AMQP_PORT" >/dev/null 2>&1 && AMQP_UP=1
  if [ "$ARM_UP" = 1 ] && [ "$AMQP_UP" = 1 ]; then break; fi
  NOW=$(date +%s)
  if [ $((NOW - START)) -gt "$POLL_DEADLINE_S" ]; then
    echo "[s5-run] ERROR: substrate did not open $AMQP_PORT/$ARM_PORT within ${POLL_DEADLINE_S}s. Substrate log: $LOG_PATH" >&2
    tail -n 40 "$LOG_PATH" >&2 || true
    exit 2
  fi
  if ! kill -0 "$SUBSTRATE_PID" 2>/dev/null; then
    echo "[s5-run] ERROR: substrate process exited early. Substrate log: $LOG_PATH" >&2
    tail -n 40 "$LOG_PATH" >&2 || true
    exit 2
  fi
  sleep 0.5
done
log "substrate up on $AMQP_PORT/$ARM_PORT after $(( $(date +%s) - START ))s"

# --- 6. Run the chain ------------------------------------------------------------
log "running sessions.test.cjs"
set +e
SMALT_REPO="$REPO" \
SMALT_SB_SHARED_KEY="$SMALT_SB_SHARED_KEY" \
SMALT_SDK_ROOT="$SMALT_SDK_ROOT" \
SMALT_SB_API_VERSION="$API_VERSION" \
SMALT_ARM_PORT="$ARM_PORT" \
SMALT_AMQP_PORT="$AMQP_PORT" \
  node --test "$SCRIPT_DIR/sessions.test.cjs"
TEST_CODE=$?
set -e

if [ "$TEST_CODE" = 0 ]; then
  log "PASS"
else
  log "FAIL (exit $TEST_CODE)"
fi
exit "$TEST_CODE"
