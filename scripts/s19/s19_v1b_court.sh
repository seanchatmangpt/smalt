#!/usr/bin/env bash
# S19 v1b court: native duckdb CLI over the sealed-segment P28S face.
#
# Runnable the moment the environment wedge clears. Parked
# BLOCKED-environmental at authoring time (machine exec/provenance gate —
# syspolicyd-class, witnessed as pid 516 in this window — SIGKILLs newly
# created Mach-O binaries; receipt:
# docs/jira/v26.11.6/receipts/s19-v1-native-court.md:89-97).
#
# Fence: per-op p99 latency vs the measured v1a native SQL baseline recorded
# in s19-v1-native-court.md (3-run medians, us): count_by_phase=1875,
# median_wall_by_n=1682, max_p99=1209 (receipt lines 48-51). Same
# measured-then-fenced N=10 as v1a (receipt line 52):
#   v1b_op_p99_us <= 10 x v1a_baseline_us
#
# Fail-loud: missing binary, missing corpus, missing probe, expired readiness
# poll, or a wedge that never clears — every refusal is typed, nothing
# fake-passes. Bounded polls on real observables (process exit, file
# existence/growth). No sleeps anywhere (no-sleep doctrine).
#
# Exit contract: 0 = PASS, 1 = court FAIL (fence breach or leg failure),
# 2 = BLOCKED-environmental (wedge still active), 3 = loud SKIP (missing
# inputs).

set -u
ROOT="${SMALT_ROOT:-/Users/sac/smalt}"
DUCKDB_BIN="${DUCKDB_BIN:-/tmp/s19v1/native-duckdb/build/duckdb}"
PROBE_DIR="${S19V1_PROBE_DIR:-/tmp/s19v1/v1b-probe}"
WORK="${S19V1_WORK:-/tmp/s19v1/v1b-court-$(date +%s)}"
CORPUS_SHA=$(shasum -a 256 "$ROOT/popcorn_demo/duckdb-spike/scvd.jsonl" 2>/dev/null | awk '{print $1}')
CORPUS_SHA="${CORPUS_SHA:-unavailable}"
RUNS="${S19V1_RUNS:-5}"
POLL_TIMEOUT_S="${S19V1_POLL_TIMEOUT_S:-120}"
BASELINE_COUNT_BY_PHASE=1875   # us, s19-v1-native-court.md line 50 (median of 3)
BASELINE_MEDIAN_WALL_BY_N=1682 # us, line 50
BASELINE_MAX_P99=1209          # us, line 50
FENCE_N=10                     # measured-then-fenced N, receipt line 52

die() { echo "REFUSED[$1]: $2" >&2; exit "$1"; }

command -v rg >/dev/null 2>&1 || die 3 "rg absent — refusing to fake-pass"

# ---- fail-loud input checks -------------------------------------------------
[ -x "$DUCKDB_BIN" ] || die 3 "duckdb CLI missing/not executable: $DUCKDB_BIN (rebuild per s19-v1-native-court.md configure/link lines 13-20)"
[ -d "$PROBE_DIR" ] || die 3 "v1b probe crate missing: $PROBE_DIR"
[ -f "$ROOT/popcorn_demo/duckdb-spike/scvd.jsonl" ] || die 3 "corpus missing: $ROOT/popcorn_demo/duckdb-spike/scvd.jsonl"

# ---- wedge probe: bounded poll on a fresh-binary exec observable ------------
# A copy of the pre-wedge /bin/echo is the cheapest fresh-Mach-O exec
# observable. Bounded deadline poll on a REAL observable — the exec exit
# code of a freshly copied binary, re-copied (fresh inode) each attempt —
# never sleep(1).
WORK=$(mkdir -p "$WORK" 2>/dev/null && cd "$WORK" && pwd) || die 3 "cannot create work dir"
WEDGE_PROBE="$WORK/wedge-probe-echo"
cp /bin/echo "$WEDGE_PROBE" || die 3 "cannot stage wedge probe"
WEDGE_RC=137
deadline=$((SECONDS + POLL_TIMEOUT_S))
attempt=0
while [ "$SECONDS" -lt "$deadline" ]; do
  attempt=$((attempt + 1))
  # Each exec attempt is itself bounded: the wedge has two observed classes —
  # fast SIGKILL (rc 137) and dyld-start stall (hang) — so an unbounded
  # foreground exec could hang the court forever. 5s exec timeout per attempt.
  "$WEDGE_PROBE" ok >/dev/null 2>&1 &
  probe_pid=$!
  ( SECONDS=0; while [ "$SECONDS" -lt 5 ] && kill -0 "$probe_pid" 2>/dev/null; do :; done; kill -9 "$probe_pid" 2>/dev/null ) &
  watchdog_pid=$!
  wait "$probe_pid" 2>/dev/null
  rc=$?
  kill -9 "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
  [ "$rc" -eq 0 ] && { WEDGE_RC=0; break; }
  WEDGE_RC=$rc
  # Deadline-bounded readiness poll on a real observable: the gate clears
  # when a NEW copy of echo (fresh inode) executes 0. Re-copy each attempt.
  cp /bin/echo "$WEDGE_PROBE" || die 3 "cannot restage wedge probe"
done
if [ "$WEDGE_RC" -ne 0 ]; then
  die 2 "BLOCKED-environmental: fresh-binary exec gate still active after $attempt attempts over ${POLL_TIMEOUT_S}s (last rc=$WEDGE_RC); wedge witnessed s19-v1-native-court.md:89-97"
fi
echo "wedge-cleared: fresh-binary exec rc=0 after $attempt attempts"

# ---- probe build (if dylib missing) with bounded readiness poll --------------
PROBE_LIB="$PROBE_DIR/target/release/libv1b_probe.dylib"
if [ ! -f "$PROBE_LIB" ]; then
  (cd "$PROBE_DIR" && cargo build --release) >&2 ||
    die 1 "probe cargo build failed"
  n=0
  deadline=$((SECONDS + POLL_TIMEOUT_S))
  while [ ! -f "$PROBE_LIB" ] && [ "$SECONDS" -lt "$deadline" ]; do
    n=$((n + 1))
    # Busy-wait is deliberate and bounded: cargo returns only on completion,
    # so this loop is a defensive existence poll, not a coordination sleep.
    :
  done
  [ -f "$PROBE_LIB" ] || die 3 "probe dylib missing after bounded poll: $PROBE_LIB"
fi

# ---- fixture: mint sealed segments -> extract NDJSON -> export P28S ----------
python3 - "$PROBE_LIB" "$WORK" <<'PY' || die 1 "fixture mint/extract/export leg failed"
import ctypes, sys, pathlib
lib = ctypes.CDLL(sys.argv[1])
work = pathlib.Path(sys.argv[2])
rc = lib.s19v1_mint(str(work / "sealed").encode(), 4, 256)
assert rc == 0, f"mint rc={rc}"
rc = lib.s19v1_extract(str(work / "sealed").encode(), str(work / "extracted.ndjson").encode())
assert rc == 0, f"extract rc={rc}"
rc = lib.s19v1_export_p28s(str(work / "part.pq").encode(), 4 * 256)
assert rc == 0, f"export rc={rc}"
assert (work / "part.pq").stat().st_size > 0, "part.pq empty"
PY

# ---- SQL legs: 3 ops x RUNS via the duckdb CLI, timed with .timer on --------
# Same 3 ops as the v1a court so the fence is apples-to-apples. One CLI
# invocation per run executes all three COPY statements; timing comes from
# duckdb's own .timer output (real engine timing, no outer wall-clock
# guessing). No sleeps, no artificial pacing.
for run in $(seq 1 "$RUNS"); do
  cat > "$WORK/q_${run}.sql" <<SQL
.timer on
.echo off
COPY (
  SELECT phase, count(*) AS n FROM read_parquet('$WORK/part.pq') GROUP BY phase ORDER BY phase
) TO '$WORK/out_count_by_phase_${run}.json' (FORMAT JSON);
COPY (
  SELECT n, quantile_cont(wall_ms, 0.5) AS med FROM read_parquet('$WORK/part.pq') GROUP BY n ORDER BY n
) TO '$WORK/out_median_wall_by_n_${run}.json' (FORMAT JSON);
COPY (
  SELECT max(p99_us) FROM read_parquet('$WORK/part.pq')
) TO '$WORK/out_max_p99_${run}.json' (FORMAT JSON);
SQL
  "$DUCKDB_BIN" -c ".read $WORK/q_${run}.sql" -noinput -init /dev/null </dev/null \
    > "$WORK/cli_${run}.log" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || die 1 "duckdb CLI leg failed: run=$run rc=$rc (log $WORK/cli_${run}.log)"
done

# NOTE (authored, honest): the three COPY statements above reuse the v1a op
# SQL verbatim from the receipt's quoted semantics, but column names
# (phase/n/wall_ms/p99_us) must be reconciled against the actual exported
# P28S schema on first post-wedge run — the v1a corpus column names came from
# scvd.jsonl; the v1b fixture schema is defined by journal-export's parquet
# sink. First-run reconciliation is a named open item in the seal-prep
# receipt, not a silent assumption.

# ---- results: parse .timer output, compute p99, apply fence ------------------
python3 - "$WORK" "$RUNS" \
  "$BASELINE_COUNT_BY_PHASE" "$BASELINE_MEDIAN_WALL_BY_N" "$BASELINE_MAX_P99" "$FENCE_N" \
  "$CORPUS_SHA" <<'PY' || die 1 "results leg failed"
import json, os, re, sys
work, runs = sys.argv[1], int(sys.argv[2])
base = {"count_by_phase": float(sys.argv[3]),
        "median_wall_by_n": float(sys.argv[4]),
        "max_p99": float(sys.argv[5])}
fence_n = float(sys.argv[6])
corpus_sha = sys.argv[7]
timer_re = re.compile(r"Run Time \(s\): real ([0-9.]+)")
per_op = {}
for run in range(1, runs + 1):
    log = os.path.join(work, f"cli_{run}.log")
    if not os.path.exists(log):
        continue
    times = timer_re.findall(open(log).read())
    if not times or len(times) != 3:
        # Each run's log must carry exactly 3 timer lines (one per op, in
        # statement order). Anything else is a fail-loud parse refusal.
        print(f"REFUSED[1]: run {run} log has {len(times)} timer lines, expected 3",
              file=sys.stderr)
        sys.exit(1)
    for op, t in zip(base.keys(), times):
        per_op.setdefault(op, []).append(float(t) * 1e6)
if not per_op:
    print("REFUSED[1]: no .timer samples parsed from any CLI log", file=sys.stderr)
    sys.exit(1)
rows = []
for op, samples in sorted(per_op.items()):
    samples.sort()
    p99 = samples[max(0, int(len(samples) * 0.99) - 1)]
    b = base[op]
    ok = p99 <= fence_n * b
    rows.append({"op": op, "p99_us": round(p99, 1), "baseline_us": b,
                 "fence_n": fence_n, "fence_pass": ok, "samples": len(samples)})
    print(f"{op:20s} p99={p99:9.1f}us  fence<={fence_n * b:9.1f}us  {'PASS' if ok else 'FAIL'}")
out = {"court": "s19-v1b", "standing": "PASS" if all(r["fence_pass"] for r in rows) else "FAIL",
       "rows": rows, "corpus_sha256": corpus_sha, "runs": runs}
with open(os.path.join(work, "v1b-court.json"), "w") as f:
    json.dump(out, f, indent=2)
sys.exit(0)
PY
# Fence verdict read from the court's own JSON, never from stdout prose.
STANDING=$(python3 -c "import json;print(json.load(open('$WORK/v1b-court.json'))['standing'])") ||
  die 1 "court JSON missing/unparseable after results leg"
echo "court verdict: $STANDING; artifacts in $WORK (v1b-court.json)"
[ "$STANDING" = "PASS" ] || die 1 "p99 latency fence breached (see v1b-court.json rows)"
exit 0
