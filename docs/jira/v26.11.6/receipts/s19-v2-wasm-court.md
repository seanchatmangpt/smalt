# RECEIPT: S19-V2 wasm bytes-path fidelity court (JS-flatten projection, ratio fence)

Standing: PARTIAL (v2 court ALIVE and REFUTED-honest on the ratio fence; fidelity + population fences PASS; see scope)

## What ran (2026-11-05, lane S19-V2, two full executions)

`node s19-v2.mjs` (headless chromium-headless-shell, playwright) — run 1 exit 0-tail/verdict
REFUTED, run 2 exit 1 (REFUTED verdict, by design of the fail-closed ratio fence). Full
log run 2: `/tmp/s19v2-run.log`. Harness: `popcorn_demo/duckdb-spike/s19-v2.mjs` (extends
the landed v0 `verify.mjs` pattern; the machine advisory's syspolicyd wedge did NOT park
this run — the pre-provenanced chromium-headless-shell launched and executed twice).

    corpus_rows=46 corpus_sha256=f8ce4277de0fdd5f4d7afe0940fe46fb756172cd9ead3f5e952c691eac675e93
    declared_scalar_columns=["phase","n","verified","ramp_wall_ms","p50_us","p99_us","vm_wall_ms","mem_processes_kb","mem_total_kb","mem0_total_kb","lane","run"]
    declared_dropped_nested_keys=["extra"]
    count_by_phase:        sql_p99_median=535us scalar_p99_median=5us  ratio=107x fence(<=10x)=REFUTED agree=true
    median_vm_wall_ms_by_n: sql_p99_median=645us scalar_p99_median=10us ratio=64.5x fence(<=10x)=REFUTED agree=true
    max_p99_us:            sql_p99_median=430us scalar_p99_median=5us  ratio=86x  fence(<=10x)=REFUTED agree=true
    S19_C2_VERDICT=REFUTED
    EXIT=1

(First run same shape: 113×/62.5×/101× — verdict reproducible.)

## Fidelity fence decision (task item 1): scalar-columns-only projection

DECIDED: project the SAME scalar column set as the native v1a rung (12 columns, listed
above); nested `extra` is typed-dropped, NOT added as a column.

Justification:
1. All three court ops (count_by_phase, median(vm_wall_ms) by n, max(p99_us)) read
   scalar fields only — a nested column would fence nothing any op touches.
2. `extra` is non-uniform in the corpus: 1 of 46 rows carries a `memory` sub-object,
   45 are `{}` — projecting it yields a NULL-heavy struct column and a wasm-SQL-vs-
   scalar comparison over a column neither leg computes on.
3. The v1a native rung's *compared* surface is the same scalar columns
   (read_json_auto's extra STRUCT is never referenced by the court SQL), so scalar-only
   keeps the v2 fence comparable to v0/v1a at census volume.

The drop is typed, not silent, and fenced fail-closed in-page every run:
- (a) observed scalar key set must equal the declared set (else `FIDELITY_FENCE` throw);
- (b) observed dropped-key set must equal the declared nested set (`["extra"]`,
  dropped_count=1 — witnessed true in all 3 runs of both executions);
- (c) wasm-SQL result vs JS scalar baseline must agree over the IDENTICAL column set.

## Fences (all named, all fail-closed)

| fence | law | result |
|---|---|---|
| population | corpus rows >= 1 (host side + every run) | PASS (46 rows, both runs) |
| fidelity (projection) | observed scalar set == declared set | PASS (12 columns, 3 runs × 2 executions) |
| fidelity (drop) | dropped keys == declared nested keys | PASS (`["extra"]`, count 1) |
| agreement | wasm-SQL == scalar baseline, 9/9 per execution | PASS (18/18 across both runs) |
| ratio (measured-then-fenced) | SQL_p99_us_median <= 10 × scalar_p99_us_median, N=10, 3 runs median | **REFUTED** (107×/64.5×/86×) |

## Verdict: REFUTED-honest (same verdict shape as v0 — reproduced under the typed fidelity fence)

duckdb-wasm SQL is 64–113× the in-process JS scalar baseline at census volume (46 rows).
This reproduces v0's finding (125×/67×/92×) under the v2 typed projection fence: the
overhead is the wasm worker round-trip + per-query planning, not the engine — the native
v1a rung passed the same fence at 0.13–0.19×. The wasm rung is NOT a fit for census-volume
OLAP; the fence now proves that with the bytes-path projection typed and witnessed.
Exit 1 is the fence's lawful fail-closed verdict, not a harness failure.

## Fixture

- Corpus: `popcorn_demo/duckdb-spike/scvd.jsonl`, 46 rows, sha256
  `f8ce4277de0fdd5f4d7afe0940fe46fb756172cd9ead3f5e952c691eac675e93` — byte-identical
  to the v0/v1a corpus fixture, embedded in every bench row.
- Bench rows: `popcorn_demo/bench/bench-s19-v2.jsonl` (6 rows = 2 executions × 3 ops),
  sha256 `e53bdfca9e48e1e93464bc731f64f7640557776bc364412f74c00d5418f53152`
  (final run's file). `bench_emit` jsonl per BENCH_SPEC.

## Court harness

`popcorn_demo/duckdb-spike/s19-v2.mjs` — same playwright launch/discovery as the landed
v0 `verify.mjs` (chromium-headless-shell from ms-playwright cache, COOP/COEP headers,
EH wasm bundle from local node_modules). No Process.sleep: only the sanctioned
deadline-checked 500 ms status poll on the real `#status` observable (90 s deadline).
Typed BLOCKED exit 3 wired for chromium-launch/SPIKE-timeout (not exercised — the
advisory wedge did not fire on this pre-provenanced binary).

## Scope / NOT claimed

- KD-199 (wasm parquet unverified in-bundle) STAYS OPEN: this court exercises the JSON
  path only (JS flatten → Arrow → insertArrowTable); no parquet read/write through the
  wasm bundle is attempted or claimed. (KD-198's parquet leg was closed at the native
  pin in the v1a receipt, not here.)
- The µs-true scalar baseline here is in-process JS (no subprocess startup inflation —
  unlike v1a's disclosed bash+awk-inclusive baseline), so the 64–113× ratios are
  directly comparable to v0's 125×/67×/92×, not to v1a's 0.13–0.19×.
- No throughput/production claims; census-volume (46-row) typed spike fence only.
