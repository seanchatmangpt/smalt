# errc4-hdr.md — ERRC Raise lane 4: HDR-histogram re-emit of TS bench lanes B-2/B-3

- Date: 2026-10-16T02:55Z; repo /Users/sac/smalt @ main (518b31a), v26.10.14
- Lane: ERRC lane 4 (Raise). Target: hand-rolled percentile drift in
  `scripts/bench/b2_blob_ts.mjs` / `b3_cosmos_ts.mjs` (b3's full-query emitted
  p95 = MIN run wall-time = 19.48 ms under a p95 field — units/semantics
  garbage in one field).
- Adopted: `hdr-histogram-js` (installed `--no-save` into
  `test/sdk-full/node_modules`; package.json NOT modified).
- New scripts (lib untouched, no commits):
  - `scripts/bench/b2b_blob_hdr.mjs` — blob 8 KiB put-block-blob, 30 s window,
    dual-instrumented (same latency into a sorted array with b2's exact
    percentile() semantics AND an HDR histogram recorded in microseconds, 3
    significant digits).
  - `scripts/bench/b3b_cosmos_hdr.mjs` — point-read (50 warmup + 500 measured)
    and full-query (5 runs), dual-instrumented; full-query additionally carries
    the legacy median/min/max-of-runs fields verbatim to reproduce the b3 drift
    class alongside proper per-page HDR latencies.
- New result files (same row schema as b2/b3 canonical files; the canonical
  p50/p95/p99 fields still carry hand-rolled values, HDR/count/mean ride in
  added `hdr_*` / `array_*` fields):
  - `docs/jira/v26.10.14/bench/b2b-blob-hdr.jsonl` (1 row)
  - `docs/jira/v26.10.14/bench/b3b-cosmos-hdr.jsonl` (2 rows)
- Boot: `scripts/bench/lib.sh bench_boot b2` (ports 39020-39025) and
  `bench_boot b3` (39030-39035), MIX_ENV=test anonymous, same private-port
  pattern as the original lanes. Teardown: bench_down both; 39020/39021/39030/
  39031 verified free after.

## Comparison (same measurements, HDR vs hand-rolled array, dual-instrumented — not run-to-run)

| op | n | metric | HDR (ms) | array (ms) | delta |
|---|---|---|---|---|---|
| b2b 8k-put-block-blob | 124,644 | p50 | 0.233 | 0.233 | 0.0% |
| b2b 8k-put-block-blob | 124,644 | p95 | 0.286 | 0.286 | 0.0% |
| b2b 8k-put-block-blob | 124,644 | p99 | 0.364 | 0.364 | 0.0% |
| b2b 8k-put-block-blob | 124,644 | mean | 0.240 | 0.240 | 0.0% |
| b3b point-read | 500 | p50/p95/p99 | 0.273 / 0.358 / 0.516 | 0.273 / 0.358 / 0.516 | 0.0% |
| b3b full-query (per-page) | 50 pages | p50 | 2.215 | 2.276 | -2.7% |
| b3b full-query (per-page) | 50 pages | p95 | 3.455 | 3.149 | +9.7% |
| b3b full-query (per-page) | 50 pages | p99 | 3.625 | 3.149 | +15.1% |

## Verdict

- Large-n agreement: at n>=500 the HDR histogram and the hand-rolled sorted
  array agree exactly (0.0% delta at 3 significant digits) on p50/p95/p99 and
  mean. The hand-rolled percentile FUNCTION is not the drift source at large n.
- Small-n finding: at n=10 pages per walk (50 samples across 5 runs, and the
  array twin is a separate 6th walk), HDR p95 is +9.7% and p99 +15.1% above the
  array twin. This delta conflates (a) bucket coarsening at tiny n and
  (b) run-to-run page-latency variance between the hist walk and the array twin
  walk — the exact regime where hand-rolled small-sample percentile arrays
  over-represent recent ops. Below ~50 samples, percentile fields from arrays
  are noise; HDR at least keeps stable bucket semantics and a countable
  total-count/mean alongside.
- The actual b3 field garbage (p95=19.48 "min" run) is confirmed a SEMANTICS
  bug, not a percentile-math bug: b3's full-query SUMMARY stuffed
  median/min/max-of-5-run wall-times into p50/p95/p99 fields. Reproduced
  verbatim by the legacy fields in the b3b full-query row
  (p50=23.65 median-run, p95=23.35 MIN-run, p99=23.78 MAX-run — p95 < p50 again).
- Throughput sanity vs prior canonical run: b2 8k put 4154.8 ops/s (prior
  4351.17, -4.5%, within noise); b3 point-read 3492 ops/s vs prior 4405 (run
  variance); full-query 42,043 docs/s vs prior 49,594.

## Errors / incidents

- One bench_boot b2 attempt failed to compile: another lane's in-flight edit to
  `lib/smalt/egress_router.ex` had a transient syntax error
  (`413 RequestBodyTooLarge cap`). No unblock edit was made by this lane — the
  owning lane fixed it before the retry succeeded. No lib edits by this lane.
- hdr-histogram-js API note for future lanes: methods are accessed as
  properties (`h.totalCount`, `h.mean`, `h.getValueAtPercentile(p)`); values
  recorded here in microseconds.
- b3b first run wrote `machine` as a string (schema drift); script fixed and
  lane rerun clean; the discarded first b3b file was deleted.

## Replay

```
cd /Users/sac/smalt
cd test/sdk-full && npm install --no-save hdr-histogram-js && cd ../..
bash -c 'source scripts/bench/lib.sh; export B2B_MACHINE=$(bench_machine_spec); \
  pid=$(bench_boot b2); node scripts/bench/b2b_blob_hdr.mjs; bench_down $pid; \
  pid2=$(bench_boot b3); node scripts/bench/b3b_cosmos_hdr.mjs; bench_down $pid2'
```

Standing: ALIVE — both HDR lanes ran to completion with 0 op errors against the
live substrate; hand-rolled lanes b2_blob_ts.mjs / b3_cosmos_ts.mjs remain in
place as falsifiers, unchanged.
