#!/usr/bin/env bash
# W2-11 — popcorn_demo cook + boot budget lane (lane "cook").
#
# (1) times `mix popcorn.cook --out-dir public/out` (pinned 29.0.6 toolchain
#     PATH per popcorn_demo/README), (2) times the browser boot end-to-end via
#     `node scripts/browser_smoke.mjs` (substrate must be UP; node's exit code
#     is passed through: 0=live=OK / 1=FAIL / 3=SKIP per docs/TESTBED.md),
# (3) appends rows to popcorn_demo/bench/cook.jsonl:
#       {"lane":"cook","phase":...,"median_ms":...,"runs":2,"runs_ms":[a,b],
#        "ts":...,"errors":0}
#     2 runs per phase, median of the two; both raw values reported (runs_ms).
#     No sleeps — the runs themselves are the observations.
#
# A lane writes ONLY its own result file: bench/cook.jsonl (plain append —
# own row shape, not the {surface,op,p50,p95,p99} rows of bench_emit; same
# precedent as scripts/bench_legs.sh). Fence law: relative-only, see
# BENCH_COOK.md (regression = >1.5x the previous recorded median, same phase).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_DIR="${REPO_ROOT}/popcorn_demo"
RESULT="${DEMO_DIR}/bench/cook.jsonl"
RUNS="${RUNS:-2}"
SUBSTRATE_URL="http://127.0.0.1:9443/metadata/endpoints"

mkdir -p "$(dirname "${RESULT}")"

# -------------------------------------------------- pinned toolchain (README)
export PATH="$HOME/.asdf/installs/erlang/29.0.6/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
for bin in erl elixir mix; do
  command -v "$bin" >/dev/null || { echo "BLOCKED: $bin not on pinned PATH" >&2; exit 2; }
done

# ---------------------------------------------------------------- preflight
if ! curl -sf -m 3 "${SUBSTRATE_URL}" >/dev/null 2>&1; then
  echo "BLOCKED: substrate down at ${SUBSTRATE_URL} -> just substrate-up" >&2
  exit 2
fi
echo "substrate: UP"

cd "${DEMO_DIR}"

# ------------------------------------------------------------- timed phases
# python3 wraps each run purely as the measurement clock (time.perf_counter);
# the child's real exit code is propagated (browser boot exit contract intact).
# Note: local python3 does not forward post-'-' args to sys.argv, so the label
# and command travel via env vars, never argv.
timed() { # timed <label> <cmd...>
  local label="$1"; shift
  COOK_LABEL="$label" COOK_CMD="$*" python3 - <<'PY'
import json, os, shlex, subprocess, sys, time
label = os.environ["COOK_LABEL"]
cmd = shlex.split(os.environ["COOK_CMD"])
t0 = time.perf_counter()
p = subprocess.run(cmd)
ms = round((time.perf_counter() - t0) * 1000)
# persist one raw sample to a scratch sidecar keyed by phase
side = os.environ.get("COOK_SAMPLES", "/tmp/cook_samples.jsonl")
with open(side, "a") as f:
    f.write(json.dumps({"phase": label, "ms": ms, "rc": p.returncode}) + "\n")
print(f"{label}: {ms} ms (exit {p.returncode})")
sys.exit(p.returncode)
PY
}

rm -f /tmp/cook_samples.jsonl
FAIL=0

for i in $(seq 1 "${RUNS}"); do
  timed cook mix popcorn.cook --out-dir public/out || FAIL=1
done
for i in $(seq 1 "${RUNS}"); do
  timed boot node scripts/browser_smoke.mjs || FAIL=1
done

# ------------------------------------------------------------------- emit
RUNS="$RUNS" RESULT_FILE="$RESULT" python3 - <<'PY'
import json, os, statistics, time
result = os.environ["RESULT_FILE"]
samples = {}
for line in open("/tmp/cook_samples.jsonl"):
    s = json.loads(line)
    samples.setdefault(s["phase"], []).append(s)
ts = int(time.time())
with open(result, "a") as f:
    for phase, ss in samples.items():
        ms = [s["ms"] for s in ss]
        row = {"lane": "cook", "phase": phase,
               "median_ms": round(statistics.median(ms)),
               "runs": len(ms), "runs_ms": ms,
               "ts": ts, "errors": sum(1 for s in ss if s["rc"] != 0)}
        f.write(json.dumps(row) + "\n")
        print(json.dumps(row))
PY

# --------------------------------------------------- relative fence (1.5x)
# Compares THIS run's median against the PREVIOUS row for the same phase
# already in the jsonl (row-to-row, never an absolute ms constant). First
# recording establishes the baseline and cannot fire.
RESULT_FILE="$RESULT" python3 - <<'PY'
import json, os, sys
rows = [json.loads(l) for l in open(os.environ["RESULT_FILE"]) if l.strip()]
by_phase = {}
for r in rows:
    if r.get("lane") == "cook":
        by_phase.setdefault(r["phase"], []).append(r)
bad = 0
for phase, rs in by_phase.items():
    if len(rs) < 2:
        print(f"FENCE: {phase}: first recording — baseline established, no fence")
        continue
    prev, cur = rs[-2], rs[-1]
    if prev["median_ms"] > 0 and cur["median_ms"] > 1.5 * prev["median_ms"]:
        print(f"FENCE: {phase} median {cur['median_ms']}ms > 1.5x prev {prev['median_ms']}ms")
        bad = 1
if not bad:
    print("FENCE: PASS (all phases within 1.5x previous recorded median)")
sys.exit(bad)
PY

exit "${FAIL}"
