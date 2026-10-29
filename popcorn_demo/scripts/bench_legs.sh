#!/usr/bin/env bash
# ERRC-R8 — popcorn_demo host-leg latency bench (lane "legs").
#
# Runs each host leg (PopcornDemo.Live / LiveMatrix / LiveBlob) via mix run
# N=5 times, records per-leg wall ms (median + max, measured not slept), and
# appends one JSONL row per leg to popcorn_demo/bench/legs.jsonl:
#   {"lane":"legs","leg":...,"median_ms":...,"max_ms":...,"runs":5,"ts":...,
#    "machine":{...},"errors":0}
#
# Schema note: this lane emits its own row shape (leg-granular wall time), NOT
# the {surface,op,p50,p95,p99} rows of scripts/bench/lib.sh bench_emit — so it
# does a plain append (documented here) and sources lib.sh only for
# bench_machine_spec. A lane writes ONLY its own result file: bench/legs.jsonl.
#
# Ratio-fence law (no absolute ms bounds): a leg REGRESSES if its median_ms
# exceeds 2x the median_ms of the previous jsonl row for the same leg (see
# BENCH_LEGS.md). Fence compares row-to-row, never a wall-clock constant.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="${REPO_ROOT}/popcorn_demo"
RESULT="${DEMO_DIR}/bench/legs.jsonl"
RUNS="${RUNS:-5}"
SUBSTRATE_URL="http://127.0.0.1:9443/metadata/endpoints"

# lib.sh: bench_machine_spec only (see schema note above).
# shellcheck source=/Users/sac/smalt/scripts/bench/lib.sh
source "${REPO_ROOT}/scripts/bench/lib.sh"

# popcorn_demo pins elixir ~> 1.20 (mix.exs); host PATH may carry an older one.
for d in "$HOME"/.asdf/installs/elixir/1.20.*; do
  [ -x "$d/bin/elixir" ] && export PATH="$d/bin:$PATH" && break
done

mkdir -p "$(dirname "${RESULT}")"

# ---------------------------------------------------------------- preflight
if ! curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1; then
  echo "BLOCKED: substrate down at ${SUBSTRATE_URL} -> just substrate-up" >&2
  exit 2
fi
echo "substrate: UP"

MACHINE="$(bench_machine_spec)"

# --------------------------------------------------------------- timed legs
# Python wraps the mix run purely to measure wall ms (time.perf_counter) —
# the measurement clock, not a coordination sleep. One OS process per run;
# each run executes the leg's real run() and prints "<leg>=<verdict>".
run_timed() {
  local leg_module="$1"
  python3 - "$DEMO_DIR" "$leg_module" <<'PY'
import subprocess, sys, time
demo, mod = sys.argv[1], sys.argv[2]
code = """
case Code.ensure_loaded(%s) do
  {:module, _} ->
    r = %s.run()
    f = if function_exported?(%s, :format, 1), do: %s.format(r), else: inspect(r)
    IO.puts("LEG_OUT: " <> f)
  {:error, r} ->
    IO.puts("LEG_OUT: SKIP(" <> inspect(r) <> ")")
end
""" % (mod, mod, mod, mod)
t0 = time.perf_counter()
p = subprocess.run(
    ["mix", "run", "-e", code],
    cwd=demo, capture_output=True, text=True,
    env={**__import__("os").environ, "MIX_BUILD_ROOT": "_build-errc-r8"},
)
t1 = time.perf_counter()
out = p.stdout + p.stderr
verdict = "FAIL(no-LEG_OUT)"
for line in out.splitlines():
    if line.startswith("LEG_OUT: "):
        verdict = line[len("LEG_OUT: "):]
ok = p.returncode == 0 and "=FAIL" not in verdict and "SKIP" not in verdict
# print: elapsed_ms<TAB>ok<TAB>exit<TAB>verdict
print(f"{(t1-t0)*1000.0:.1f}\t{1 if ok else 0}\t{p.returncode}\t{verdict.strip()}")
PY
}

LEGS=("PopcornDemo.Live" "PopcornDemo.LiveMatrix" "PopcornDemo.LiveBlob")
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAILED=0
declare -a SUMMARY

for leg in "${LEGS[@]}"; do
  samples=()
  errors=0
  last_verdict=""
  for _ in $(seq 1 "$RUNS"); do
    IFS=$'\t' read -r ms ok exit_code verdict <<<"$(run_timed "$leg")"
    last_verdict="$verdict"
    if [ "$ok" = "1" ]; then
      samples+=("$ms")
    else
      errors=$((errors + 1))
      echo "  [ERROR] $leg exit=$exit_code: $verdict" >&2
    fi
  done

  if [ "${#samples[@]}" -eq 0 ]; then
    echo "FAIL: $leg produced zero good runs" >&2
    FAILED=1
    continue
  fi

  STATS="$(printf '%s\n' "${samples[@]}" | python3 -c '
import sys, statistics
v = [float(x) for x in sys.stdin]
print(f"{statistics.median(v):.1f} {max(v):.1f}")
')"
  median="${STATS% *}"
  max="${STATS#* }"

  # ratio fence vs previous row for this leg (row-to-row, never an absolute ms bound)
  FENCE="n/a"
  if [ -s "${RESULT}" ]; then
    PREV="$(python3 - "$RESULT" "$leg" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
prev = [r["median_ms"] for r in rows if r.get("leg") == sys.argv[2]]
if prev:
    print(f"{2 * float(prev[-1]):.1f}")
PY
)"
    if [ -n "$PREV" ]; then
      if python3 -c "import sys; sys.exit(0 if float('$median') > float('$PREV') else 1)"; then
        FENCE="REGRESSED(>2x prev median ${PREV}ms)"
        FAILED=1
      else
        FENCE="ok(fence ${PREV}ms)"
      fi
    fi
  fi

  printf '{"lane":"legs","leg":"%s","median_ms":%s,"max_ms":%s,"runs":%s,"ts":"%s","errors":%s,"machine":%s}\n' \
    "$leg" "$median" "$max" "$RUNS" "$TS" "$errors" "$MACHINE" >>"${RESULT}"
  SUMMARY+=("$leg median=${median}ms max=${max}ms errors=${errors} fence=${FENCE}")
done

echo "== results (${RESULT})"
for s in "${SUMMARY[@]}"; do echo "  $s"; done
echo "BENCH_LEGS: done ts=${TS} runs=${RUNS}"
exit "$FAILED"
