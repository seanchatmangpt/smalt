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
SUITES=(test/smalt_graphlaw_validator_test.exs test/smalt_services_test.exs test/arm_error_corpus_test.exs)

snapshot() {
  find "${WATCH_PATHS[@]}" -name '*.ex' -print0 2>/dev/null | xargs -0 stat -f '%m %N' 2>/dev/null
}

run_suites() {
  clear
  echo "== dev_watch: graphlaw change, $(date '+%H:%M:%S') =="
  local t0=$(date +%s)
  MIX_BUILD_ROOT="${DEV_WATCH_BUILD_ROOT:-_build-dw}" mix test "${SUITES[@]}"
  local rc=$?
  echo "[$(date '+%H:%M:%S')] wall: $(( $(date +%s) - t0 ))s"
  return $rc
}

if [[ "${1:-}" == "--once" ]]; then
  run_suites
  exit $?
fi

SNAP=$(snapshot)
run_suites || true
while true; do
  sleep 1
  NEW=$(snapshot)
  if [[ "$NEW" != "$SNAP" ]]; then
    SNAP="$NEW"
    run_suites || true
  fi
done
