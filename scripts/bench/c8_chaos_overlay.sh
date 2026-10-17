#!/usr/bin/env bash
# c8_chaos_overlay.sh — lane C-8: cross-product chaos overlay orchestrator.
#
# Boots the substrate on the c8 c-law block (39200+10N family: 39280..39285,
# disjoint from the b-law band), starts the 3-surface Node driver (c8_chaos_cross.mjs), then:
#   t=60s   SIGKILL the substrate BEAM; re-boot; epochs recorded to the jsonl
#   t=120s  write emphasis file ("cosmos") — traffic re-weighted
#   t=180s  kill #2 lands under cosmos-emphasized traffic; re-boot
#   t=270s  driver ends; substrate torn down
#
# Chaos method: SIGKILL of the whole substrate BEAM process (B-11's class).
# A per-process kill of the ARM Bandit listener is not reachable from outside
# the BEAM (Bandit acceptors are BEAM-internal), so the full-restart class is
# the honest option that still produces client-visible errors on every surface
# sharing the VM — exactly the cross-surface blast radius C-8 measures.
#
# Boot mirrors lib.sh bench_boot but ALSO pins :sb_shared_key (lib.sh leaves it
# nil, which fails EH CBS SAS verification — b4_messaging_ts.mjs does the same).
#
# No commits, no lib edits.
# Output: docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl + stdout.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/docs/jira/v26.10.14/bench/c8-chaos-cross.jsonl"
EMP="$REPO/tmp/c8-emphasis.txt"
mkdir -p "$(dirname "$OUT")" "$(dirname "$EMP")"
: > "$OUT"
: > "$EMP"

TS() { python3 -c 'import time;print(round(time.time()*1000))'; }
clamp_sleep() { # clamp_sleep <target_epoch_ms> — sleep until then, min 0
  local d
  d=$(( $1 - $(TS) ))
  if [ "$d" -gt 0 ]; then sleep $(python3 -c "print($d/1000)"); fi
}

# AMQP CBS SAS shared key (mirrors b4_messaging_ts.mjs).
SB_SHARED_KEY=$(python3 - <<'PYEOF'
import base64, os
print(base64.b64encode(os.urandom(48)).decode())
PYEOF
)

boot_substrate() {
  local log="$REPO/tmp/bench-substrate-c8.log"
  local eval_code
  eval_code="Application.put_env(:smalt, :sb_shared_key, \"$SB_SHARED_KEY\"); \
Application.put_env(:smalt, :sb_endpoint, \"sb://127.0.0.1:39282\"); \
Application.put_env(:smalt, :arm_port, 39280); \
Application.put_env(:smalt, :egress_port, 39281); \
Application.put_env(:smalt, :amqp_port, 39282); \
Application.put_env(:smalt, :event_hubs_port, 39283); \
Application.put_env(:smalt, :arm_tls_port, 39284); \
Application.put_env(:smalt, :mcp_port, 39285); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"
  MIX_ENV=test mix run --no-start -e "$eval_code" --no-halt >"$log" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 120); do
    if lsof -nP -iTCP:39280 -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$pid"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  echo "c8: substrate failed to listen; log: $log" >&2
  kill "$pid" 2>/dev/null || true
  return 1
}

wait_ports_free() {
  local p held i
  for i in $(seq 1 60); do
    held=0
    for p in 39280 39281 39282 39283 39284 39285; do
      if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then held=1; fi
    done
    if [ "$held" = 0 ]; then return 0; fi
    sleep 0.5
  done
  echo "c8: ports never freed after SIGKILL" >&2
  return 1
}

echo "== c8: boot substrate (lane c8, ports 39280..39285) =="
PID=$(boot_substrate)
echo "c8: substrate pid $PID"

T0=$(TS)
C8_EGRESS_PORT=39281 C8_EHUB_PORT=39283 C8_OUT="$OUT" \
  C8_EMPHASIS_FILE="$EMP" C8_DURATION_MS=270000 C8_T0_EPOCH="$T0" \
  C8_SB_KEY="$SB_SHARED_KEY" \
  node "$REPO/scripts/bench/c8_chaos_cross.mjs" &
NODE_PID=$!

# Port-watch sampler: every 1s, if any of 39280..39285 is LISTENed by a pid
# other than the current substrate (and not the previous substrate pid, which
# lingers in TIME_WAIT listings for a moment), record a marker — catches a port
# squatter that would explain out-of-chaos ECONNREFUSED windows.
LASTPID=""
( while kill -0 "$NODE_PID" 2>/dev/null; do
    for p in 39280 39281 39282 39283 39284 39285; do
      wp=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [ -n "$wp" ] && [ "$wp" != "$PID" ] && [ "$wp" != "$LASTPID" ]; then
        echo "{\"kind\":\"portsquat\",\"port\":$p,\"pid\":\"$wp\",\"ts\":$(TS)}" >> "$OUT"
        LASTPID=$wp
      fi
    done
    sleep 1
  done ) &
SAMPLER=$!

kill_and_reboot() {
  local phase="$1" kt rt
  kt=$(TS)
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  wait_ports_free
  echo "{\"kind\":\"kill\",\"phase\":\"$phase\",\"ts\":$kt}" >> "$OUT"
  PID=$(boot_substrate)
  rt=$(TS)
  echo "{\"kind\":\"reboot_done\",\"phase\":\"$phase\",\"ts\":$rt}" >> "$OUT"
  echo "c8: [$phase] kill at $kt, substrate listening again at $rt (+$((rt - kt))ms) pid $PID"
}

# Phase 1: uniform traffic; kill at t=60s.
clamp_sleep $((T0 + 60000))
kill_and_reboot p1

# Emphasis from t=120s.
clamp_sleep $((T0 + 120000))
echo "cosmos" > "$EMP"

# Phase 2: cosmos-emphasized traffic; kill at t=180s.
clamp_sleep $((T0 + 180000))
kill_and_reboot p2

# Neutral emphasis for the final recovery stretch.
clamp_sleep $((T0 + 210000))
: > "$EMP"

echo "c8: waiting for driver to finish (t=270s)..."
wait "$NODE_PID"
echo "c8: driver done"

kill "$SAMPLER" 2>/dev/null || true

# Teardown: kill the last substrate (reaps the mix -> beam group).
kill -9 "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
: > "$EMP"
rm -f "$EMP"
echo "c8: substrate down. Result: $OUT"
