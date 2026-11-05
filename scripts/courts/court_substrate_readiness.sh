#!/usr/bin/env bash
# court_substrate_readiness.sh — L53 non-vacuity court for substrate.sh's
# await_ready readiness poll (real sockets, no mocks).
#
# Arms (must yield DISTINCT verdicts or the court is vacuous):
#   A. fake HTTP listener on a temp port -> await_ready returns 0 (boot success
#      within budget)
#   B. live process that never listens, tiny budget -> rc 1 (budget exhausted =
#      slow/failed boot, NOT accepted as success)
#   C. process that dies mid-boot, generous budget -> rc 2 quickly (boot
#      refusal detected via the pid observable, not the clock)
#
# A gate that accepts both boot-success and boot-refusal is vacuous: B and C
# must be refused with DISTINCT typed outcomes, and A must be admitted.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SMALT="$REPO/scripts/substrate.sh"

fails=0

# --- source the script (source-guard added in L53; dispatch not triggered) ---
# shellcheck disable=SC1090
source "$SMALT"

# Arm A: real temp HTTP listener -> success within budget.
aport=$(( 30000 + RANDOM % 20000 ))
python3 -m http.server "$aport" --bind 127.0.0.1 >/dev/null 2>&1 &
asrv=$!
# bounded poll for the temp listener itself (never a fixed sleep)
SECONDS=0
until lsof -nP -iTCP:"$aport" -sTCP:LISTEN >/dev/null 2>&1; do
  if [ "$SECONDS" -ge 10 ]; then echo "[COURT] FAIL: temp listener never came up"; exit 1; fi
  sleep 0.2 # SLEEP-CLASS: POLL-STEP (bounded listener-up poll)
done
PORTS="$aport"
HEALTH="http://127.0.0.1:$aport/"
t0=$SECONDS
await_ready "$asrv" 15
arcA=$?
echo "[COURT] A success-listener: rc=$arcA (budget 15s, took ${t0}s)"
[ "$arcA" -eq 0 ] || { echo "[COURT] FAIL: arm A must be admitted (rc 0)"; fails=$((fails+1)); }

# Arm B: live process, never listens, 3s budget -> rc 1 (slow/failed refused).
sleep 30 & bsleep=$!
PORTS="$aport"
HEALTH="http://127.0.0.1:1/"   # never-serving URL
await_ready "$bsleep" 3
arcB=$?
echo "[COURT] B never-listening: rc=$arcB (budget 3s)"
[ "$arcB" -eq 1 ] || { echo "[COURT] FAIL: arm B must be refused as budget-exhausted (rc 1)"; fails=$((fails+1)); }

# Arm C: process dies mid-boot, generous budget -> rc 2 fast (refusal, not clock).
sh -c 'sleep 0.4' & csleep=$!
PORTS="1"
HEALTH="http://127.0.0.1:1/"
c0=$(date +%s)
await_ready "$csleep" 20
arcC=$?
cdur=$(( $(date +%s) - c0 ))
echo "[COURT] C died-mid-boot: rc=$arcC in ${cdur}s (budget 20s)"
[ "$arcC" -eq 2 ] || { echo "[COURT] FAIL: arm C must be refused as boot-refusal (rc 2)"; fails=$((fails+1)); }
[ "$cdur" -lt 15 ] || { echo "[COURT] FAIL: arm C detected by clock, not pid observable (took ${cdur}s)"; fails=$((fails+1)); }

kill "$asrv" "$bsleep" 2>/dev/null
wait "$asrv" "$bsleep" 2>/dev/null

if [ "$fails" -ne 0 ]; then
  echo "[COURT] VACUOUS/FAIL: $fails arm(s) failed"
  exit 1
fi
# Distinctness: the three arms produced 0 / 1 / 2 — success, slow-refusal,
# dead-refusal are typed differently, so the gate is non-vacuous.
echo "[COURT] PASS: readiness poll distinguishes boot-success (0) / slow-boot refusal (1) / dead-boot refusal (2); non-vacuous"
exit 0
