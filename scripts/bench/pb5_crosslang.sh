#!/usr/bin/env bash
# PB-5 — cross-language differential bench driver (Erlang runner vs POWL2 Executor).
# Sources scripts/bench/lib.sh; emits tmp/bench/pb5-crosslang.jsonl.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/bench/lib.sh"
BENCH_LANE=pb5
RESULT_FILE="$REPO/tmp/bench/pb5-crosslang.jsonl"
mkdir -p "$(dirname "$RESULT_FILE")"
: >"$RESULT_FILE"

export PATH="$HOME/.asdf/shims:$PATH"
OUT=$(cd "$REPO" && MIX_BUILD_ROOT=_build-fondrun mix run --no-compile --no-start scripts/bench/pb5_crosslang.exs 2>/dev/null)
echo "$OUT" | tee "$REPO/tmp/bench/pb5-staged.log" >/dev/null

while IFS='|' read -r surface op n ops p9599 errors; do
  read -r p50 p95 p99 <<<"$p9599"
  bench_emit "$RESULT_FILE" "$surface" "$op" "$n" "$ops" "$p50" "$p95" "$p99" "$errors"
done < <(echo "$OUT" | sed -n '/PB5_ROWS_BEGIN/,/PB5_ROWS_END/p' | sed '1d;$d')

echo "--- machine spec (just bench-machine equivalent) ---"
bench_machine_spec
echo
echo "--- result file ---"
cat "$RESULT_FILE"
