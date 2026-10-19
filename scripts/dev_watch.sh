#!/usr/bin/env bash
# dev_watch.sh — source-driven watch over a scoped fast subset.
#
# Watches lib/smalt/graphlaw/** and re-runs the graphlaw suites on change.
# Demonstrates the pattern for scoping a watcher to a subsystem; see
# docs/how-to/dev-loop.md for how to generalize (copy the WATCH_PATHS/SUITES pair,
# or extend fast_test.sh --watch, which watches lib/ + one test file).
#
# Usage: scripts/dev_watch.sh [--once]
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH_PATHS=(lib/smalt/graphlaw)
SUITES=(test/internal/dets_mirror_recovery_test.exs test/internal/plane_blast_radius_test.exs test/internal/vm_zero_growth_test.exs)

snapshot() {
  find "${WATCH_PATHS[@]}" -name '*.ex' -print0 2>/dev/null | xargs -0 stat -f '%m %N' 2>/dev/null
}

run_suites() {
  clear
  echo "== dev_watch: graphlaw change, $(date '+%H:%M:%S') =="
  local t0=$(date +%s)
  local rc=0
  # `set -e` would kill the watcher on a red suite before rc is captured;
  # run under an inverted condition so the exit contract is preserved.
  MIX_BUILD_ROOT="${DEV_WATCH_BUILD_ROOT:-_build-dw}" mix test "${SUITES[@]}" || rc=$?
  echo "[$(date '+%H:%M:%S')] wall: $(( $(date +%s) - t0 ))s (mix exit: $rc)"
  return $rc
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: scripts/dev_watch.sh [--once]"
  echo "  (default) watch ${WATCH_PATHS[*]} and re-run the suites on change"
  echo "  --once    run the suites once and exit with mix's exit code"
  exit 0
fi

if [[ "${1:-}" == "--once" ]]; then
  run_suites
  exit $?
fi

SNAP=$(snapshot)
run_suites || true
# Watch loop: poll-step on a real observable (stat snapshot diff). This is the
# one audited poll implementation — no other sleeps in this script.
while true; do
  sleep 1 # SLEEP-CLASS: POLL-STEP
  NEW=$(snapshot)
  if [[ "$NEW" != "$SNAP" ]]; then
    SNAP="$NEW"
    run_suites || true
  fi
done
