# RECEIPT: S19 v1b seal-prep — court script staged, BLOCKED-environmental

Standing: BLOCKED (environmental — machine exec/provenance gate now stalls fresh process spawns at _dyld_start, witnessed live this session on the court harness itself, see §3; upstream wedge receipt docs/jira/v26.11.6/receipts/s19-v1-native-court.md:89-97; gate site: scripts/s19/s19_v1b_court.sh wedge-probe leg, typed `die 2` exit — unreachable this tick because the gate stalls the harness spawn pre-script)

## What landed this tick (2026-11-05, lane S19-V1B)

### 1. Court script staged (authored, NOT executed to verdict)

`/Users/sac/smalt/scripts/s19/s19_v1b_court.sh` (bash -n clean, chmod +x).

Design:
- Native CLI invocation of the duckdb binary (default
  `DUCKDB_BIN=/tmp/s19v1/native-duckdb/build/duckdb`, env-overridable), fail-loud
  `REFUSED[3]` if the binary is missing or not executable.
- Fixture leg via the real v1b probe cdylib
  (`/tmp/s19v1/v1b-probe` → `libv1b_probe.dylib`, path deps on cgap-arrow +
  journal-export): `s19v1_mint` → `s19v1_extract` → `s19v1_export_p28s`
  through the real `segment_source` + `ipc_walk::walk_verified` +
  `parquet_sink::write_lane_block` gates.
- SQL legs: same 3 ops as the v1a court (count_by_phase, median_wall_by_n,
  max_p99) via the duckdb CLI with `.timer on`; p99 parsed from duckdb's own
  timer output (real engine timing, no outer wall-clock guessing).
- Fence: per-op p99 ≤ N × v1a measured baseline (3-run medians, receipt
  s19-v1-native-court.md lines 48-52): count_by_phase=1875us,
  median_wall_by_n=1682us, verdict-op max_p99=1209us, N=10 — the same
  measured-then-fenced N v1a used, so the fence is apples-to-apples.
- Bounded polls on real observables only: wedge-probe polls fresh-binary exec
  rc (deadline POLL_TIMEOUT_S, default 120s, re-staged copy each attempt);
  probe-dylib existence poll after cargo build. **Zero sleeps** — every wait
  is deadline-bounded on an observable.
- Exit contract: 0 PASS / 1 court FAIL (fence breach, leg failure,
  unparseable court JSON) / 2 BLOCKED-environmental (wedge probe fails after
  bounded attempts) / 3 loud SKIP (missing binary/corpus/probe).

### 2. Backlog falsifier re-pointed (append-only, one line)

`docs/jira/v26.11.5/strata-backlog.md:59` — S19 row falsifier cell now names
`scripts/s19/s19_v1b_court.sh` as the staged court. Verified on disk by grep
after the edit (no corruption; row still single line, table shape intact).

### 3. Wedge witness — re-confirmed LIVE this session (stronger than exit-2)

The court script was executed twice at authoring time; neither run reached
the in-script wedge probe, because the gate now stalls the harness spawn
itself:

- Run 1 (defaults): moved to harness background at the 120s foreground
  timeout while silent, killed via TaskStop.
- Run 2 (`S19V1_POLL_TIMEOUT_S=25 S19V1_WORK=/tmp/s19v1/v1b-court-witness`):
  silent for 108s, then `sample <pid> 2` returned the live stack —
  `_dyld_start` only, zero frames of user code — i.e. the freshly spawned
  `/usr/bin/env bash scripts/s19/s19_v1b_court.sh` process never left the
  dynamic loader. SIGKILL via kill -9; wrapper observed `court rc=137`.
- Work dir `/tmp/s19v1/v1b-court-witness/` was never created: the stall
  predates the script's first statement. The gate has tightened past the
  v1a receipt's class (fresh-newly-created-binaries) to stall even a
  re-exec of the pre-existing `/usr/bin/env`. The in-script typed `die 2`
  BLOCKED exit exists but was unreachable this tick — the environment
  refuses the court's own process before the probe can run.

This is a receipt-grade live witness of BLOCKED-environmental, observed
rather than assumed. No verdict is claimed for the fence legs; the script's
first post-wedge run must produce the exit-2/0/1 verdict on its own.

## Named open items (first post-wedge run)

1. **Column-name reconciliation** (disclosed in-script): the three COPY
   statements reuse v1a op SQL verbatim; the v1a corpus column names came from
   scvd.jsonl, but the v1b fixture schema is defined by journal-export's
   parquet sink. Reconcile `phase/n/wall_ms/p99_us` against the actual
   exported schema on first run — named in-script, not a silent assumption.
2. Probe dylib currently missing (`/tmp/s19v1/v1b-probe/target/release/`
   absent at authoring time) — the script builds it via cargo on first run;
   exec of the fresh dylib load is itself wedge-gated, so expect exit 2 until
   the wedge clears (CTDLL of new dylibs stalls per the v1a receipt).

## Re-arm command

```
bash /Users/sac/smalt/scripts/s19/s19_v1b_court.sh
# exit 0 PASS / 1 fence-or-leg FAIL / 2 wedge still active / 3 loud SKIP
```

Falsifier (backlog S19): the court exits 0 only when all three ops clear the
p99 fence vs the v1a measured baseline; a court that exits 0 through the
wedge, or that accepts a fence breach, is the failure mode this script is
fenced against.
