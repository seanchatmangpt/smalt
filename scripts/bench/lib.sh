#!/usr/bin/env bash
# scripts/bench/lib.sh — shared benchmark harness for the v26.10.14 bench wave.
#
# Lane B-1 (core) owns this file; lanes B-2..B-12 source it. Provides:
#   bench_machine_spec        — machine/toolchain spec block (JSON) every lane embeds
#   bench_lane_ports <lane>   — deterministic private port block per lane (no collisions)
#   bench_boot <lane>         — private-port substrate, MIX_ENV=test, auth_mode anonymous
#   bench_down <pid>          — kill a substrate spawned by bench_boot
#   bench_emit <file> <fields...>  — append one JSONL result record
#   bench_percentile          — stdin: latencies (ms, one per line) -> p50/p95/p99
#
# Result format (one JSON object per line in docs/jira/v26.10.14/bench/<lane>.jsonl):
#   {lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}
#
# Port law (no concurrent-lane collisions): lane id -> base port
#   base = 39000 + (lane_number * 10). Ports: ARM, ARM+1(egress/data),
#   ARM+2(amqp), ARM+3(event_hubs), ARM+4(arm_tls), ARM+5(mcp).
#   e.g. b1 -> 39010..39015, b2 -> 39020..39025, ... b12 -> 39120..39125.
#
# Substrate spawn mirrors scripts/bench.py spawn_substrate (witnessed-safe:
# every fixed listener is scoped) but pins MIX_ENV=test (auth_mode :anonymous
# is set in config/test.exs) and private ports so N lanes boot concurrently.

set -euo pipefail

BENCH_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BENCH_RESULTS_DIR="${BENCH_RESULTS_DIR:-$BENCH_REPO/docs/jira/v26.10.14/bench}"
# Lane receipts ALWAYS go here (absolute) — a relative "receipts/" in a dispatch
# prompt resolves against the lane's cwd and has drifted to $BENCH_REPO/receipts/.
# Lanes: use "$RECEIPTS_DIR/<lane-receipt>.md", never a bare relative path.
RECEIPTS_DIR="${RECEIPTS_DIR:-$BENCH_REPO/docs/jira/v26.10.14/receipts}"

# ---------------------------------------------------------------------------
# Machine spec — the exact block every lane embeds in its machine field.
# ---------------------------------------------------------------------------
bench_machine_spec() {
  local cpu cores ram elixir otp darwin
  cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "0")
  ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  ram=$((ram_bytes / 1024 / 1024 / 1024))
  elixir=$(elixir -e 'IO.puts System.version()' 2>/dev/null | tail -1 || echo "unknown")
  otp=$(elixir -e 'IO.puts :erlang.system_info(:otp_release)' 2>/dev/null | tail -1 || echo "unknown")
  darwin=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  printf '{"cpu":"%s","cores":%s,"ram_gb":%s,"elixir":"%s","otp":"%s","darwin":"%s"}' \
    "$cpu" "$cores" "$ram" "$elixir" "$otp" "$darwin"
}

# ---------------------------------------------------------------------------
# Ports — deterministic per-lane private block.
# ---------------------------------------------------------------------------
bench_lane_number() {
  # b1..b12 -> 1..12
  local lane="$1"
  echo "${lane#[Bb]}" | tr -dc '0-9'
}

bench_lane_ports() {
  local lane="$1" n base
  n=$(bench_lane_number "$lane")
  [ -n "$n" ] && [ "$n" -ge 1 ] && [ "$n" -le 12 ] || {
    echo "bench_lane_ports: lane must be b1..b12, got '$lane'" >&2; return 1; }
  base=$((39000 + n * 10))
  echo "$base $((base+1)) $((base+2)) $((base+3)) $((base+4)) $((base+5))"
}

# ---------------------------------------------------------------------------
# Substrate lifecycle — private ports, MIX_ENV=test, anonymous auth.
# Mirrors scripts/bench.py::spawn_substrate (all listeners scoped).
# ---------------------------------------------------------------------------
bench_boot() {
  local lane="$1"
  local log
  local arm data amqp ehub atls mcp
  read -r arm data amqp ehub atls mcp <<<"$(bench_lane_ports "$lane")"

  # Pre-flight: whole block must be free.
  local p
  for p in $arm $data $amqp $ehub $atls $mcp; do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "bench_boot[$lane]: port $p already held — refusing to boot (collision)" >&2
      return 1
    fi
  done

  log="$BENCH_RESULTS_DIR/../../../tmp/bench-substrate-$lane.log"
  mkdir -p "$(dirname "$log")"
  log="$(cd "$(dirname "$log")" && pwd)/$(basename "$log")"

  local eval_code
  eval_code="Application.put_env(:smalt, :arm_port, $arm); \
Application.put_env(:smalt, :egress_port, $data); \
Application.put_env(:smalt, :amqp_port, $amqp); \
Application.put_env(:smalt, :event_hubs_port, $ehub); \
Application.put_env(:smalt, :arm_tls_port, $atls); \
Application.put_env(:smalt, :mcp_port, $mcp); \
{:ok, _} = Application.ensure_all_started(:smalt); \
Process.sleep(:infinity)"

  MIX_ENV=test \
  SMALT_TEST_ARM_PORT=$arm SMALT_TEST_EGRESS_PORT=$data \
  SMALT_TEST_AMQP_PORT=$amqp SMALT_TEST_EVENT_HUBS_PORT=$ehub \
  mix run --no-start -e "$eval_code" --no-halt \
    >"$log" 2>&1 &
  local pid=$!

  # Health: ARM front door accepts TCP (matches scripts/bench.py readiness).
  local i
  for i in $(seq 1 "${SMALT_BENCH_UP_TIMEOUT:-120}"); do
    if lsof -nP -iTCP:"$arm" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$pid"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  echo "bench_boot[$lane]: substrate pid $pid failed to listen on $arm within timeout; log: $log" >&2
  kill "$pid" 2>/dev/null || true
  return 1
}

bench_down() {
  local pid="${1:-}"
  [ -n "${pid:-}" ] || return 0
  kill "$pid" 2>/dev/null || true
  # Reap the process group too (mix -> beam), best-effort.
  pkill -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Results — JSONL emission + percentiles.
# ---------------------------------------------------------------------------
bench_emit() {
  # bench_emit <jsonl_path> <surface> <op> <n> <ops_per_sec> <p50_ms> <p95_ms> <p99_ms> <errors>
  local file="$1"; shift
  local surface="$1" op="$2" n="$3" ops="$4" p50="$5" p95="$6" p99="$7" errors="$8"
  local lane="${BENCH_LANE:-unknown-lane}"
  local machine
  machine=$(bench_machine_spec)
  mkdir -p "$(dirname "$file")"
  printf '{"lane":"%s","surface":"%s","op":"%s","n":%s,"ops_per_sec":%s,"p50_ms":%s,"p95_ms":%s,"p99_ms":%s,"errors":%s,"machine":%s}\n' \
    "$lane" "$surface" "$op" "$n" "$ops" "$p50" "$p95" "$p99" "$errors" "$machine" \
    >>"$file"
}

bench_percentile() {
  # stdin: one latency (ms) per line. Prints "p50 p95 p99" (ms).
  python3 -c '
import sys
v = sorted(float(x) for x in sys.stdin if x.strip())
if not v:
    print("0 0 0"); raise SystemExit
def pct(p):
    return v[round((p/100.0)*(len(v)-1))]
print(f"{pct(50):.3f} {pct(95):.3f} {pct(99):.3f}")
'
}

# Lane's canonical result file path.
bench_result_file() {
  local lane="$1"
  echo "$BENCH_RESULTS_DIR/${lane}.jsonl"
}
