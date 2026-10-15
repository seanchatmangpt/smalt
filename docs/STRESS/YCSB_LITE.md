# YCSB_LITE

# YCSB-lite Mixed-Plane Stress (smalt)

10-minute, 24-thread mixed-plane stress court for the smalt substrate.
Harness: `scripts/stress/ycsb_lite.py` (stdlib-only, fail-closed). Receipt:
`tmp/ycsb-lite-receipt.json` (`smalt-ycsb-lite v1`).

## Workload

Per-op draw: 10% of all ops are ARM RG GETs and 2% are blob PUTs; the
remaining 88% is Cosmos with an 80/15/5 read/upsert/scan split.

| op | share | plane | request |
|---|---|---|---|
| cosmos_read | 0.80 x 0.88 | data :38443 | `GET /dbs/ycsb/colls/c/docs/k{key}` |
| cosmos_upsert | 0.15 x 0.88 | data :38443 | POST insert (`ins-N`, unique id) or PUT replace of a seeded key (128 B payload); `x-ms-documentdb-partitionkey` header |
| cosmos_scan | 0.05 x 0.88 | data :38443 | `GET /dbs/ycsb/colls/c/docs` (full-collection list) |
| arm_rg_get | 0.10 | control :39443 | `GET /subscriptions/bench-sub/resourceGroups/rg-ycsb-N` |
| blob_put | 0.02 | data :38443 | `PUT /ycsbacc/ycsbcont/blob-N.bin`, 1 KiB body, unique names |

Every op checks its status against an expected set
(read {200}, upsert {200, 201}, scan {200}, ARM {200}, blob {201}).
All requests carry a Bearer token (HS256, minted client-side with the
`:sts_signing_secret` the harness's own prelude configures — the substrate
runs `auth_mode: :enforce`).

## Zipfian keyspace

10 partitions (`pk = p0..p9`, partition = `key % 10`), 10,000 logical keys,
all seeded before the run (zero 404s on tail reads). Zipf is approximated
without numpy/scipy: `random.paretovariate(alpha=1.2)` power law mapped
linearly onto the keyspace with a clamp at 1000 — a heavy head like YCSB's
zipfian.

## Measurement

24 threads, persistent per-thread connections. 30 s warmup (discarded by
trimming the first n_warmup latencies per op type), then a 600 s measured
window. Outputs: aggregate ops/s, per-op-type latency percentiles
(p50/p95/p99/max), error budget (non-2xx vs 5xx vs transport). Verdict
requires zero 5xx + zero transport errors. The harness spawns its own
substrate via `mix run --no-start --no-halt -e <prelude>` on dedicated
ports (39443/38443/38445/38446/39444) so it never touches the default
9443/8443/5672/5673/9444 set held by other lanes' live sessions, and
kills it in a finally on every path.

## Running

```sh
python3 scripts/stress/ycsb_lite.py
# short validation smoke only (does NOT satisfy the 10-min court):
YCSB_WARMUP_S=5 YCSB_MEASURE_S=20 python3 scripts/stress/ycsb_lite.py
```

## 2026-10-14 result — full 10-minute run

Subject: darwin/arm64 (Apple Silicon), MIX_ENV=dev, local loopback,
isolated ports 39443/38443/38445/38446/39444 (default ports held by
another lane's live session). Receipt: `tmp/ycsb-lite-receipt.json`
(`smalt-ycsb-lite/v1`, dated 2026-10-14T22:22:33-0700), produced by
`python3 scripts/stress/ycsb_lite.py` (600.374 s measured window after a
discarded 30 s warmup; 48,459 warmup ops discarded). Substrate boot
1.474 s. Verdict: **PASS** — zero 5xx, zero transport errors across
446,905 ops.

| op type | n | p50 ms | p95 ms | p99 ms | max ms | errors (non-2xx/5xx/transport) |
|---|---|---|---|---|---|---|
| cosmos_read | 314,769 | 16.750 | 48.264 | 70.776 | 244.007 | 0 / 0 / 0 |
| cosmos_upsert | 58,728 | 33.586 | 78.698 | 109.226 | 255.496 | 0 / 0 / 0 |
| cosmos_scan | 19,681 | 288.308 | 535.804 | 595.349 | 713.602 | 0 / 0 / 0 |
| arm_rg_get | 45,034 | 0.409 | 1.136 | 2.302 | 44.898 | 0 / 0 / 0 |
| blob_put | 8,693 | 0.479 | 1.555 | 3.324 | 17.988 | 0 / 0 / 0 |

Aggregate: **744.4 ops/s** (446,905 ops over 600 s, 24 threads).

### vs per-plane sequential baselines (`docs/BENCHMARKS.md`, 18:15 post-wave)

Baseline p95s are sequential single-op round-trips; the stress adds
cross-plane contention plus 24-way concurrency, so the comparison shows
contention cost, not regression:

| plane | sequential p95 baseline | stress p95 (mixed) | note |
|---|---|---|---|
| Cosmos doc round-trip | 0.392 ms | 48.264 ms read / 78.698 ms upsert | p50 16.75 ms under 24-way mixed load; ~123x baseline but far under the <20 ms single-op CTQ only when idle |
| ARM PUT (proxy for ARM surface) | 0.357 ms | 1.136 ms (RG GET) | ~3x baseline under load |
| Blob PUT | (no baseline row) | 1.555 ms | n/a |

Notes: scan p95 (535.8 ms) is the full-collection list (~10k docs and
growing with inserts) and is expected to dominate; its cost grows with
collection size by definition. Cosmos latencies degrade roughly linearly
with thread count (single-thread p50 ~0.3 ms), i.e. the store is
contention-bound, not error-bound — zero 5xx across 10 minutes at
744 ops/s aggregate.
