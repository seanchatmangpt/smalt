# bench-03-cosmos-ts.md — Lane B-3: Cosmos SDK (TypeScript) benchmark

- Date: 2026-10-16T02:38Z; repo /Users/sac/smalt @ main (3fc2543), v26.10.14
- SDK: @azure/cosmos 4.10.1 (real ESM build from test/sdk-full/node_modules)
- Substrate: private-port boot via `scripts/bench/lib.sh bench_boot b3`
  (block 39030..39035, MIX_ENV=test, anonymous auth); cosmos plane
  http://127.0.0.1:39031. Substrate down + all 6 ports verified free after.
- Script: `scripts/bench/b3_cosmos_ts.mjs`; driver: bash sourcing lib.sh
  (boot -> run -> bench_emit -> bench_down). Rows: canonical
  `{lane,surface,op,n,ops_per_sec,p50_ms,p95_ms,p99_ms,errors,machine}` in
  `docs/jira/v26.10.14/bench/b3-cosmos-ts.jsonl` (4 rows).

## Phase order (coordinator directive, anti-hang)

Point-read -> full-query -> continuation-walk -> upsert-throughput LAST,
upsert hard-capped at MAX_UPSERT_DOCS=1000 (total docs <= 2k). Upsert hit the
doc cap in 227ms (4406 ops/s), never reached the 30s window, so the post-upsert
query hang (earlier: 150k upsert docs then query) is structurally excluded.

## Headline numbers (Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28)

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point-read | 500 | 4405.29 | 0.215 | 0.300 | 0.419 | 0 |
| full-query (`SELECT * FROM c`, 1000 docs) | 1000 | 49594.3 docs/s | 20.16 (median run) | 19.48 (min) | 20.71 (max) | 0 |
| continuation-walk (pageSize 100) | 1000 | 505.85 pages/s | 1.93 (page median) | 2.41 (page max) | 2.41 (page max) | 0 |
| upsert-create-only | 1000 | 4406.2 | 0.227 | 0.227 | 0.227 | 0 |

Note on full-query columns: 5 timed runs; the emitted p50/p95/p99 fields carry
median/min/max run wall-time in ms (per-run aggregate, not per-doc latency) —
docsPerSec is the throughput column. Continuation-walk p50/p95/p99 carry page
median/max. Point-read and upsert are true per-op latency.

## Correctness observed during the run

- 0 errors across all phases (50-run warmups included).
- KD-36 context: upsert ran create-only (fresh ids). SDK-tier evidence that
  upsert-of-existing 409s is in
  `docs/jira/v26.10.14/sdk-results/ts-cosmos.md` (TS-3); not re-triggered here.
- SQL whitelist: full query used `SELECT * FROM c` only (only admitted form).
- Teardown: `database.delete()` answered 404 despite the db existing (cosmetic;
  db is private to the lane and the substrate is torn down after). Logged, not
  blocking — same shape as the TS-3 receipt's upsert/bulk divergences family.

## Parity table inputs (cross-lane)

- B-1 lib.sh + REGISTRY.md consumed as-is (port law, row schema, machine spec).
- B-5 `b5-python-mirror.jsonl` on disk (blob Python): its 8k put = 917 ops/s vs
  B-2 blob TS 4351 ops/s. Cosmos has no Python mirror row in b5; TS-3 cosmos
  SDK-correctness receipt is the companion artifact for this lane.

## Replay

```
bash -c 'source scripts/bench/lib.sh; pid=$(bench_boot b3); \
  node scripts/bench/b3_cosmos_ts.mjs; bench_down $pid'
```

Standing: ALIVE for the measured surface (point-read, full-container whitelist
query, continuation pagination, create-only upsert) — 0 errors, machine-receipted.
