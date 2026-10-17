#!/usr/bin/env bash
# fast_test.sh — single-file / file:line inner-loop test runner.
#
# Usage:
#   scripts/fast_test.sh test/smalt_graphlaw_validator_test.exs
#   scripts/fast_test.sh test/smalt_graphlaw_validator_test.exs:42
#   scripts/fast_test.sh test/foo_test.exs:42 --watch
#
# MIX_BUILD_ROOT is derived from a hash of the argument, so parallel
# invocations never race the shared _build directory. Prints wall time.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <test_file[:line]> [--watch]" >&2
  exit 2
fi

WATCH=0
EXTRA_ARGS=()
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --watch) WATCH=1 ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$arg"; else EXTRA_ARGS+=("$arg"); fi ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <test_file[:line]> [--watch] [extra mix test args]" >&2
  exit 2
fi

# Resolve to an existing file (strip :line).
FILE="${TARGET%%:*}"
if [[ ! -f "$FILE" ]]; then
  echo "fast_test: no such file: $FILE" >&2
  exit 2
fi

# Per-invocation build root: hash of the (watch-mode-independent) arg.
if [[ -n "${FAST_TEST_BUILD_ROOT:-}" ]]; then
  BUILD_ROOT="$FAST_TEST_BUILD_ROOT"
else
  HASH=$(printf '%s' "$FILE" | shasum | cut -c1-8)
  BUILD_ROOT="_build-ft-${HASH}"
fi
export MIX_BUILD_ROOT="$BUILD_ROOT"

run_once() {
  local t0 t1 rc=0
  t0=$(date +%s)
  mix test "$TARGET" ${EXTRA_ARGS+"${EXTRA_ARGS[@]}"} || rc=$?
  t1=$(date +%s)
  echo "[$(date '+%H:%M:%S')] wall: $((t1 - t0))s (build root: $BUILD_ROOT)"
  return $rc
}

if [[ "$WATCH" == 1 ]]; then
  # Watch: poll mtimes of lib/ sources + the test file every 1s; re-run on
  # change with a cleared screen + timestamp.
  # SHIM-COURT: R17/A11 #6 — SNAP and NEW use the SAME format
  # (mtime + path for every watched file) so the first poll cannot
  # spuriously report a change.
  SNAP=$(find lib -name '*.ex' -print0 | xargs -0 stat -f '%m %N'; stat -f '%m %N' "$FILE" 2>/dev/null)
  run_once || true
  while true; do
    sleep 1
    NEW=$(find lib -name '*.ex' -print0 | xargs -0 stat -f '%m %N'; stat -f '%m %N' "$FILE" 2>/dev/null)
    if [[ "$NEW" != "$SNAP" ]]; then
      SNAP="$NEW"
      clear
      echo "== fast_test watch: change detected, $(date '+%H:%M:%S') =="
      run_once || true
    fi
  done
else
  run_once
fi
