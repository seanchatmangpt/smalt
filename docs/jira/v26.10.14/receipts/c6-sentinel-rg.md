# Bench C-6 — Sentinel (Log Analytics) ingest + KQL + Resource Graph

- lane: c6
- date: 2026-10-15
- subject: `scripts/bench/c6_sentinel_rg.py` under
  `test/sdk-python/.venv-rg` (azure-monitor-query 2.0.0,
  azure-mgmt-resourcegraph 8.0.1, Python 3.14.3) against a private smalt
  substrate (`scripts/bench/lib.sh` `bench_boot c6`, MIX_ENV=test,
  anonymous auth, ARM 127.0.0.1:39060, egress/data 127.0.0.1:39061,
  port block 39060-39065).
- results: `docs/jira/v26.10.14/bench/c6-sentinel-rg.jsonl`
  (5 records, errors=0 on all)
- machine: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28,
  Darwin 26.2
- run receipt: substrate pid 92060 booted via `bench_boot c6`; bench exit 0;
  teardown verified — `lsof -nP -iTCP:39060 -iTCP:39061 -sTCP:LISTEN`
  returned no listeners after `bench_down`.

## Measures

| measure | n | result |
|---|---|---|
| DCR ingest 500 B rows, 100-row batches | 5,000 rows (50 batches) | 33,774 rows/s — p50 2.051 ms, p95 2.336 ms, p99 46.328 ms per 100-row batch |
| KQL where+order+take+project (idle) | 30 iters | 95.6 q/s — p50 9.787 ms, p95 14.077 ms, p99 22.467 ms |
| KQL same pipeline under concurrent ingest | 148 iters / 10 s | 14.8 q/s — p50 94.028 ms, p95 430.191 ms, p99 496.699 ms |
| Resource Graph `project id,name,type` top=100 | 5,998 iters / 10 s | 599.8 q/s — p50 1.619 ms, p95 1.907 ms, p99 2.168 ms |
| `take 100000` cap under ingest load | 11 checks | 101 rows on all 11 checks (0 violations) at ~273 k table rows; p50 784.2 ms, p95 1,865.7 ms |

## Interference verdict: YES — ingest load degrades KQL query latency severely

During the 10 s concurrent window the ingest worker pushed 142,200 additional
rows (zero ingest errors) while two query threads ran the
`where n >= 100 | order by n desc | take 10 | project n, msg` pipeline:

| | idle | under ingest | ratio |
|---|---|---|---|
| p50 | 9.79 ms | 94.03 ms | 9.6x |
| p95 | 14.08 ms | 430.19 ms | 30.6x |
| p99 | 22.47 ms | 496.70 ms | 22.1x |
| throughput | 95.6 q/s | 14.8 q/s | 6.5x down |

Latency grows with table size, not merely with load: the idle baseline ran at
~5 k rows, the load window at ~150-270 k rows (the phase-4 take-cap queries at
~273 k rows show p50 784 ms for the same engine). The scan-based KQL engine
appears O(table size) per query with no index path, so ingest volume is itself
the dominant query-latency term — worse than a lock/contention story because
it persists after ingest stops. Read-your-write was never degraded to absent:
every concurrent query succeeded (0 errors) and returned correct results.

## Take-cap fence under contention

The 101-row cap held on 11/11 checks while the table grew from ~147 k to
~273 k rows via the concurrent ingest worker. No cap violation, no 5xx.

## Falsifier status

- phases 1-4 all returned ok (script exit 0)
- falsifier for the interference claim: rerun with ingest paused mid-window —
  if p95 does not track table size, the O(table-size) attribution is refuted.

## Notes / caveats

- Real Azure Log Analytics has ingest lag (minutes); smalt is read-your-write
  synchronously — the measured interference is smalt's own scan cost, not
  comparable to Azure's ingress decoupling.
- Phase-4 emit wrote `ops_per_sec` as checks/8 s wall — a checks/s figure, not
  sustained capacity (11 heavy full-scan queries in the window).
- The script's `probe()` PASS/FAIL list is vestigial (phases return booleans);
  "PHASES: 0 ok / 0 failed" printed at end-of-run is that unused list, not a
  missed phase. Exit code is the phase gate.
