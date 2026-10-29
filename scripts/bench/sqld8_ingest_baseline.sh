#!/usr/bin/env bash
# SQLD-8 — bench driver: runs 3 isolated-worker rounds per route and emits
# tmp/bench/sqld8-ingest-baseline.jsonl rows. AR-BENCH-01 aggregate model:
# min-of-3 wall (worker monotonic deltas), peak = worker OS max-RSS.
# Note: macOS /usr/bin/time -l reports "maximum resident set size" in BYTES.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXS="$REPO/scripts/bench/sqld8_ingest_baseline.exs"
OUT="$REPO/tmp/bench/sqld8-ingest-baseline.jsonl"
WORK="$REPO/tmp/sqld8"
DUMP="$WORK/events_dump.sql"
CSV="$WORK/events_direct.csv"
ROUND_MS=()
ROUND_RSS=0

round() { # round <tag> <exs args...>
  local tag="$1"; shift
  local tlog="$WORK/${tag}.time"
  /usr/bin/time -l -o "$tlog" elixir "$EXS" "$@" > "$WORK/${tag}.out" 2>"$WORK/${tag}.err"
  local ms rss
  ms=$(sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p' "$WORK/${tag}.out" | head -1)
  rss=$(awk '/maximum resident set size/ {print $1}' "$tlog")
  echo "round $tag: wall_ms=$ms peak_rss_bytes=$rss"
  ROUND_MS+=("$ms")
  [ "$rss" -gt "$ROUND_RSS" ] && ROUND_RSS=$rss || true
}

machine='{"cpu":"'"$(sysctl -n machdep.cpu.brand_string | tr -d '"')"'","cores":'"$(sysctl -n hw.ncpu)"',"ram_gb":'"$(($(sysctl -n hw.memsize)/1024/1024/1024))"',"elixir":"'"$(elixir -e 'IO.puts System.version()' | tail -1)"'","otp":"'"$(elixir -e 'IO.puts :erlang.system_info(:otp_release)' | tail -1)"'","darwin":"'"$(sw_vers -productVersion)"'"}'

emit() { # emit <surface> <op> <n> <rss_bytes> <ms...>
  local surface="$1" op="$2" n="$3" rss="$4"; shift 4
  local sorted
  mapfile -t sorted < <(printf '%s\n' "$@" | sort -n)
  local best=${sorted[0]} p50=${sorted[1]} p95=${sorted[2]} p99=${sorted[2]}
  local ops
  ops=$(python3 -c "print(round($n/($best/1000),1))")
  printf '{"lane":"sqld8","surface":"%s","op":"%s","n":%s,"ops_per_sec":%s,"p50_ms":%s,"p95_ms":%s,"p99_ms":%s,"errors":0,"machine":%s,"rounds_ms":[%s],"min_ms":%s,"peak_rss_bytes":%s,"method":"AR-BENCH-01 aggregate; isolated worker OS process (plain elixir, no Mix); min-of-3; peak=worker max-RSS (/usr/bin/time -l); no fixed sleeps"}\n' \
    "$surface" "$op" "$n" "$ops" "$p50" "$p95" "$p99" "$machine" \
    "$(IFS=,; echo "$*")" "$best" "$rss"
}

# ---- converter route: dump -> SqlIngest -> CSV -> duckdb projection ----
ROUND_RSS=0; ROUND_MS=()
for r in 1 2 3; do round "conv$r" converter-round "$DUMP" "$WORK/round${r}_conv.csv" "$WORK/round${r}_conv.duckdb"; done
CONV_MS=("${ROUND_MS[@]}"); CONV_RSS=$ROUND_RSS

# ---- direct route: duckdb read_csv -> same projection ----
ROUND_RSS=0; ROUND_MS=()
for r in 1 2 3; do round "direct$r" direct-round "$CSV" "$WORK/round${r}_direct.duckdb"; done
DIRECT_MS=("${ROUND_MS[@]}"); DIRECT_RSS=$ROUND_RSS

{
  emit "sql_dump_ingest" "dump_to_ocel_projection_converter" 100000 "$CONV_RSS" "${CONV_MS[@]}"
  emit "sql_dump_ingest" "csv_to_ocel_projection_direct" 100000 "$DIRECT_RSS" "${DIRECT_MS[@]}"
} >> "$OUT"

echo "EMITTED $OUT"
cat "$OUT"
