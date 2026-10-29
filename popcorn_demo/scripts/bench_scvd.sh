#!/usr/bin/env bash
# S2 — SCVD host-side measurement lane (popcorn_demo).
#
# PRD §5 protocol, HOST-SIDE (the falsifiable twin; in-browser comes later):
#   (1) baseline: single-process memory tax — :erlang.memory totals + cold ramp(1)
#   (2) ramp 1->256 (powers of two), N x3 runs, median
#   (3) contention stress at 32/128 actors
# Emits one jsonl row per {phase, n, run} into popcorn_demo/bench/scvd.jsonl.
#
# Lane law: this lane writes ONLY bench/scvd.jsonl. Row shape is lane-granular
# {lane, phase, n, run, wall_ms, p50_us, p99_us, verified, breaches, mem_*},
# NOT the scripts/bench/lib.sh {surface,op,p50..} shape — documented here;
# lib.sh is sourced only for bench_machine_spec.
#
# Each ramp run is a FRESH `mix run` (cold VM) — cold-boot numbers, measured
# not slept. In-VM clocks are :erlang.monotonic_time (Concurrency's own).
#
# Contention rows measure wall_ms in-VM around contention/1; per-actor
# percentiles are not reported by contention/1, so p50_us/p99_us are OMITTED
# there (never zero-filled).
#
# Error rows are typed and single: a failed run appends exactly one
# {"error": ...} row and the lane continues.
#
# Threshold Wall: first N where wall stops scaling linearly — computed in
# BENCH_SCVD.md from the emitted data, not asserted here.
set -uo pipefail   # NOT -e: a failed run must append its typed error row, not abort the lane

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="${REPO_ROOT}/popcorn_demo"
RESULT="${DEMO_DIR}/bench/scvd.jsonl"

# popcorn_demo pins elixir ~> 1.20; host lane toolchain: 1.20.3-otp-28.
export PATH="$HOME/.asdf/installs/elixir/1.20.3-otp-28/bin:$PATH"
export MIX_BUILD_ROOT=_build-s2

# lib.sh: bench_machine_spec only (schema note above).
# shellcheck source=/Users/sac/smalt/scripts/bench/lib.sh
source "${REPO_ROOT}/scripts/bench/lib.sh"

mkdir -p "$(dirname "${RESULT}")"
cd "${DEMO_DIR}"

MACHINE="$(bench_machine_spec)"

# --------------------------------------------------------------- jsonl sink
# Reads one VM run's output on stdin, extracts the SCVD_JSON line, stamps
# {phase, n, run}, appends one row. Missing marker -> loud error row.
sink() {
  python3 -c '
import json, sys
row = None
for line in sys.stdin:
    if line.startswith("SCVD_JSON: "):
        row = json.loads(line[len("SCVD_JSON: "):])
phase, n, run = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
if row is None:
    print(json.dumps({"lane": "scvd", "phase": phase, "n": n, "run": run,
                      "error": "no-SCVD_JSON"}))
    sys.exit(0)
row.update(lane="scvd", phase=phase, n=n, run=run)
print(json.dumps(row))
' "$1" "$2" "$3" >> "${RESULT}"
}

error_row() {
  python3 -c '
import json, sys
print(json.dumps({"lane": "scvd", "phase": sys.argv[1], "n": int(sys.argv[2]),
                  "run": int(sys.argv[3]), "error": sys.argv[4]}))
' "$1" "$2" "$3" "$4" >> "${RESULT}"
}

# ------------------------------------------------------------------ inner VM
# One fresh VM per {n, run}. Prints a single SCVD_JSON line (jason).
# All timing/memory measured in-VM; nothing zero-filled.
INNER='
alias Jason, as: J
n = String.to_integer(System.get_env("SCVD_N") || "1")
phase = System.get_env("SCVD_PHASE") || "ramp"

mem0 = :erlang.memory()
t0 = :erlang.monotonic_time()

{row, extra} =
  case phase do
    "contention" ->
      case PopcornDemo.Concurrency.contention(n) do
        {:ok, r} ->
          {%{verified: r.winners, breaches: 0, wall_ms: nil, p50_us: nil, p99_us: nil},
           %{"keys" => r.keys, "committed_rows" => r.committed_rows}}

        {:error, {:not_deterministic, detail}} ->
          {%{verified: 0, breaches: n, wall_ms: nil, p50_us: nil, p99_us: nil},
           %{"not_deterministic" => inspect(detail)}}
      end

    _ ->
      r = PopcornDemo.Concurrency.ramp(n)
      {%{verified: r.verified, breaches: r.breaches, wall_ms: r.wall_ms,
         p50_us: r.p50_us, p99_us: r.p99_us}, %{}}
  end

t1 = :erlang.monotonic_time()
mem1 = :erlang.memory()
vm_wall_ms = :erlang.convert_time_unit(t1 - t0, :native, :microsecond) / 1000.0

out =
  %{phase: phase, n: n,
    verified: row.verified,
    ramp_wall_ms: row.wall_ms,
    p50_us: row.p50_us,
    p99_us: row.p99_us,
    vm_wall_ms: Float.round(vm_wall_ms, 1),
    mem_processes_kb: div(mem1[:processes], 1024),
    mem_total_kb: div(mem1[:total], 1024),
    mem0_total_kb: div(mem0[:total], 1024),
    extra: extra}
  |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  |> Map.new()

IO.puts("SCVD_JSON: " <> J.encode!(out))
'

# --------------------------------------------------------------- run driver
# timeout: a hung run (e.g. an actor crash leaving ramp's receive blocked) is
# a loud timed-out error row, never a stalled lane.
run_one() {
  local phase="$1" n="$2" run="$3"
  local out
  if out="$(timeout 120 env SCVD_PHASE="$phase" SCVD_N="$n" mix run -e "$INNER" 2>&1)"; then
    printf '%s\n' "$out" | sink "$phase" "$n" "$run"
  else
    error_row "$phase" "$n" "$run" "mix-failed-or-timed-out"
    echo "FAIL: mix run failed/timed out (phase=${phase} n=${n} run=${run})" >&2
  fi
}

echo "machine: ${MACHINE}"
echo "result: ${RESULT}"

# (1) baseline — single-process resource tax (cold VM, N=1, full memory map)
echo "== baseline =="
out="$(timeout 120 env SCVD_PHASE=baseline mix run -e '
alias Jason, as: J
r = PopcornDemo.Concurrency.ramp(1)
mem = :erlang.memory()
totals = %{"total_kb" => div(mem[:total], 1024), "processes_kb" => div(mem[:processes], 1024),
  "processes_used_kb" => div(mem[:processes_used], 1024), "ets_kb" => div(mem[:ets], 1024),
  "atom_kb" => div(mem[:atom], 1024), "code_kb" => div(mem[:code], 1024)}
IO.puts("SCVD_JSON: " <> J.encode!(%{phase: "baseline", n: 1,
  verified: r.verified, ramp_wall_ms: r.wall_ms, p50_us: r.p50_us, p99_us: r.p99_us,
  vm_wall_ms: 0.0,
  mem_processes_kb: div(mem[:processes], 1024), mem_total_kb: div(mem[:total], 1024),
  mem0_total_kb: div(mem[:total], 1024),
  extra: %{"memory" => totals}}))
' 2>&1)"
if [ $? -eq 0 ]; then
  printf '%s\n' "$out" | sink baseline 1 1
else
  error_row baseline 1 1 "mix-failed-or-timed-out"
  echo "FAIL: baseline mix run failed" >&2
fi

# (2) ramp 1->256, N x3 runs each
echo "== ramp =="
for n in 1 2 4 8 16 32 64 128 256; do
  for run in 1 2 3; do
    echo "-- ramp n=${n} run=${run}"
    run_one ramp "$n" "$run"
  done
done

# (3) contention stress 32/128, x3 runs each
echo "== contention =="
for n in 32 128; do
  for run in 1 2 3; do
    echo "-- contention n=${n} run=${run}"
    run_one contention "$n" "$run"
  done
done

echo "done: $(wc -l < "${RESULT}") rows in ${RESULT}"
