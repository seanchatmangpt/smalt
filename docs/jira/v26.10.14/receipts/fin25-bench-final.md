# Receipt: fin25-bench-final

- **Lane**: FIN-25 (final benchmark consolidation)
- **Date**: 2026-10-16
- **Repo / subject**: /Users/sac/smalt @ main (518b31a), working tree, no commits
- **Owns**: `docs/jira/v26.10.14/BENCH_RESULTS.md` (regenerated),
  `scripts/bench/report.py` (2 minimal patches), supersede-note + addendum in
  `receipts/bench-08-amqp-beam.md` / `receipts/bench-12-consolidation.md`, this receipt.

## B-4 completion poll

Polled `bench/b4-messaging-ts*.jsonl` and running writers for ~20 min
(60 s interval). Outcome: **B-4 complete** via both channels:

1. `b4-messaging-ts-run2.jsonl` — the x8 remeasure, 7 rows, complete
   (SB send 0/s n=0 err 3; SB RT 95.2 ops/s n=4296; EH producer 323.1/s n=9693
   0 errs; EH wire-tier consumer 0 events; 1 uncaught-exceptions marker).
2. `receipts/x8-messaging-remeasure.md` — landed, supersedes the contaminated
   122.6 ops/s SB RT (recycle-contaminated) with 95.2 ops/s (run2) and a later
   canonical rerun: SB RT **289 ops/s** (n=13200), EH producer **348/s** (n=10454),
   SB send still starved (2.2/s, n=96, 6 errors) — KD-20-class SB sender
   credit starvation remains open, unchanged.

## bench-report runs (real gate)

`just bench-report` run twice back-to-back, three separate times during the
session (mid-run interference from concurrent lanes rewrote b4 mid-flight):
final consecutive double-run:

- run 1: `[BENCH-REPORT] 17 file(s), 60 rows -> .../BENCH_RESULTS.md`
- run 2: `17 file(s), 60 rows` — **identical**, MD5 equal
  (5c2d0676dfea6a0d2793a94ec3510191). Idempotent.

## Coverage: all 17 landed jsonl files included

b2, b2b, b3, b3b, b4 (canonical + run2), b5, b6, b7, b7b, b8, b8b, b9, b9b,
b10-soak-spike, b11-chaos, recon-soak. wave-telemetry not present (never
landed; not expected). 16 lane sections + Methodology + Non-op records.

## report.py fixes (minimal)

1. **Truncated-row recovery** (`parse_line`): the b8 rerun rows (7–12) were cut
   mid-record inside the machine block (trailing comma). All op-row fields
   survive the cut, so repair-and-accept only when every required field is
   present; 6 rows recovered → b8 section now shows both runs (826/419/870/
   41312/35959/86189 and 729/433/891/43807/44257/91756 ops/s). Non-repairable
   lines still warn+skip.
2. **recon-soak classification**: 5389 telemetry sampler rows (proc_count /
   binary_leak_delta shape) previously classified "?" — now
   `mem-telemetry-sample`.

## Pending-lane notes → final standing

- `receipts/bench-12-consolidation.md`: B-3/B-8 "PENDING" and B-4 "meta-only"
  all landed; final consolidation addendum appended (history not rewritten).
- `receipts/bench-08-amqp-beam.md`: 122.6-based multiplier table marked
  SUPERSEDED by the x8 remeasure receipt, retained as pre-fix record.

## Commands / exits

| command | exit |
|---|---|
| polling loop (b4 writers, 60 s interval, ~20 min) | 0 |
| `just bench-report` (x6 total across session, final pair consecutive identical) | 0 |
| `md5 docs/jira/v26.10.14/BENCH_RESULTS.md` | 0 |
| python byte-level inspection of b8 truncation | 0 |

## Final counts (as of 2026-10-16 20:35 local)

- **17 jsonl files**, **60 op rows** in `BENCH_RESULTS.md`, 5400+ non-op records
  summarized (incl. 5389 recon-soak telemetry samples, 23 b7 meta/done records).
- report.py: 141 → 173 lines.

## Falsifier

This receipt is falsified if: (a) `just bench-report` run twice now does not
produce identical output; (b) any of the 17 jsonl files is absent from
BENCH_RESULTS.md; (c) bench-12's PENDING lanes (B-3/B-8/B-4) lack landed jsonl
rows (they have them); (d) the 122.6 ops/s figure is cited as current anywhere
outside the superseded pre-fix tables (bench-08, x8 "before" column).

## Standing

ALIVE (final consolidation executed; report idempotent; all landed lanes
covered; b4 standing per x8 receipt: SB send defect open, EH producer at
BEAM-tier parity ~1.06x).
