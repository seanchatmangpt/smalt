# Bench Results — v26.10.20

Aggregated from `docs/jira/v26.10.20/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.20/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b10 — arm_systemtopics

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| crud_witness | 1 | 0 | 0.00 | 0.00 | 0.00 | 0 |
## cost5 — servicebus

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| sendrecv-c128 | 1024 | 1988 | 6.91 | 425.68 | 479.63 | 0 |
## ctq2 — txn

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| cold | 5 | 2 | 511.22 | 511.91 | 511.91 | 5 |
| warm | 5 | 2 | 507.29 | 514.22 | 514.22 | 5 |
| cold | 50 | 56 | 12.91 | 16.15 | 25.96 | 0 |
| warm | 50 | 105 | 8.65 | 9.52 | 9.93 | 0 |
| cold | 50 | 90 | 7.64 | 10.51 | 11.88 | 0 |
| warm | 50 | 171 | 5.21 | 5.71 | 6.40 | 0 |

### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| verdict | FAIL | 10 | 10 |  |
| verdict | PASS | 100 | 0 |  |
| verdict | PASS | 100 | 0 |  |

## ctq4-memory — host-beam-substrate


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| rss_during_tier1_ramp | WITNESSED | 70 | 0 |  |

## scvd-airgap — airgap-court

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| PASS (non-vacuous: 10 loopback ESTABLISHED samples observed) | 1 | 0 | 0.00 | 0.00 | 0.00 | 0 |
## scvd-airgap — cosmos-http

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| put | 200 | 1177 | 0.46 | 0.75 | 10.68 | 0 |
| get | 200 | 3001 | 0.32 | 0.44 | 0.55 | 0 |
## scvd-chaos-conn — cosmos-data-plane-tls-9444


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| conn_exhaustion_chaos | FAIL | 2000 | 0 |  |
| conn_exhaustion_chaos | PASS | 2000 | 0 |  |

## scvd-t1 — cosmos


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 |  |

## scvd-t12 — blob

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| putget-c128 | 512 | 1194 | 94.90 | 180.64 | 213.78 | 0 |
| putget-c128 | 128 | 601 | 194.01 | 209.28 | 211.31 | 0 |
| putget-c128 | 512 | 880 | 134.41 | 219.37 | 258.02 | 0 |
## scvd-t12 — servicebus

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| sendrecv-c128 | 1024 | 4214 | 2.82 | 204.59 | 226.87 | 0 |
| sendrecv-c128 | 256 | 795 | 280.88 | 309.52 | 311.56 | 0 |
| sendrecv-c128 | 1024 | 4511 | 2.52 | 190.61 | 211.23 | 0 |
## scvd-t13 — cosmos


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| soak_put_get_16legs_60s | FAIL | 154300 | 0 |  |
| soak_put_get_16legs_60s | FAIL | 131368 | 0 |  |

## scvd-t18 — eventhubs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| send-c128 | 512 | 2612 | 12.25 | 127.35 | 145.11 | 0 |
| send-c8 | 40 | 1212 | 1.93 | 18.64 | 23.66 | 0 |
| send-c128 | 640 | 2520 | 21.71 | 122.23 | 151.00 | 0 |
## scvd-t21 — arm

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| putgetdelete-c128 | 512 | 31 | 4052.52 | 6661.94 | 6933.71 | 0 |
| putgetdelete-c128 | 512 | 57 | 1820.53 | 3280.93 | 3615.53 | 0 |
| putgetdelete-c128 | 512 | 24 | 4844.89 | 9052.45 | 9972.72 | 0 |
| putgetdelete-c128 | 768 | 32 | 3763.29 | 6092.59 | 6656.47 | 0 |
| putgetdelete-c128 | 768 | 34 | 3294.62 | 6058.73 | 6348.21 | 0 |
| putgetdelete-c128 | 768 | 21 | 5127.65 | 13307.20 | 13996.53 | 0 |
| putgetdelete-c128 | 512 | 13 | 10058.50 | 10222.36 | 10280.45 | 0 |
| putgetdelete-c128 | 512 | 21 | 5827.50 | 8121.92 | 8604.57 | 0 |
## scvd-t4 — cosmos

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| tail_put_get_c1 | 200 | 1170 | 0.82 | 1.11 | 1.38 | 0 |
| tail_put_get_c1 | 200 | 1297 | 0.75 | 0.93 | 1.00 | 0 |
| tail_put_get_c1 | 200 | 1419 | 0.69 | 0.84 | 0.91 | 0 |
| tail_put_get_c16 | 3200 | 2752 | 5.33 | 8.17 | 15.97 | 0 |
| tail_put_get_c16 | 3200 | 2764 | 5.41 | 8.57 | 13.00 | 0 |
| tail_put_get_c16 | 3200 | 2899 | 5.33 | 8.08 | 9.24 | 0 |
| tail_put_get_c128 | 25600 | 1841 | 61.41 | 145.22 | 186.30 | 0 |
| tail_put_get_c128 | 25600 | 1538 | 68.53 | 192.63 | 334.61 | 0 |
| tail_put_get_c128 | 25600 | 2044 | 54.71 | 134.47 | 171.80 | 0 |
| tail_put_get_c1 | 200 | 1346 | 0.70 | 1.01 | 1.26 | 0 |
| tail_put_get_c1 | 200 | 995 | 0.72 | 1.95 | 5.23 | 0 |
| tail_put_get_c1 | 200 | 1063 | 0.76 | 1.14 | 4.28 | 0 |
| tail_put_get_c16 | 3200 | 3254 | 4.72 | 6.96 | 8.11 | 0 |
| tail_put_get_c16 | 3200 | 3362 | 4.64 | 6.87 | 7.69 | 0 |
| tail_put_get_c16 | 3200 | 3117 | 4.88 | 7.53 | 12.66 | 0 |
| tail_put_get_c128 | 25600 | 2294 | 48.28 | 121.86 | 157.61 | 0 |
| tail_put_get_c128 | 25600 | 2199 | 50.73 | 124.95 | 161.59 | 0 |
| tail_put_get_c128 | 25600 | 2100 | 52.02 | 133.39 | 188.16 | 0 |
## scvd-tier2 — cosmos-docs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| putget-c128 | 512 | 2560 | 43.22 | 80.80 | 107.48 | 512 |
| putget-c128 | 512 | 2876 | 39.06 | 73.99 | 86.36 | 512 |
| putget-c128 | 512 | 2738 | 41.47 | 74.27 | 86.05 | 512 |
| putget-c128 | 1024 | 2246 | 43.79 | 115.04 | 150.61 | 0 |
| putget-c128 | 1024 | 2421 | 42.61 | 108.18 | 136.58 | 0 |
| putget-c128 | 1024 | 2349 | 44.22 | 110.50 | 136.50 | 0 |
| putget-c128 | 1024 | 2381 | 44.34 | 103.35 | 134.83 | 0 |
## scvd-tier3 — cosmos-docs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| ramp-512 | 4096 | 1614 | 249.46 | 721.50 | 940.78 | 0 |
| ramp-1024 | 8192 | 1254 | 632.80 | 1803.39 | 2389.47 | 0 |
| ramp-2048 | 16384 | 975 | 1615.78 | 4689.09 | 6206.56 | 0 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
| ramp-4096 | 16384 | 834 | 3616.00 | 10918.02 | 14305.14 | 0 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
| ramp-8192 | 15850 | 509 | 11605.20 | 29975.85 | 30499.41 | 534 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
| ramp-512 | 4096 | 1672 | 237.30 | 677.93 | 901.42 | 0 |
| ramp-1024 | 8192 | 1467 | 549.84 | 1521.74 | 1963.67 | 0 |
| ramp-2048 | 16384 | 1340 | 1150.22 | 3371.43 | 4391.84 | 0 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
| ramp-512 | 4096 | 1447 | 272.86 | 783.78 | 991.66 | 0 |
| ramp-1024 | 8192 | 1314 | 599.19 | 1748.21 | 2260.86 | 0 |
| ramp-2048 | 16384 | 1017 | 1530.71 | 4567.85 | 5847.79 | 0 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
| ramp-512 | 4096 | 1394 | 293.28 | 805.20 | 1000.14 | 0 |
| ramp-1024 | 8192 | 1209 | 654.51 | 1950.55 | 2569.19 | 0 |
| ramp-2048 | 16384 | 1009 | 1542.35 | 4575.12 | 5951.56 | 0 |
| wall-summary | 0 | 0 | 0.00 | 0.00 | 0.00 | 0 |
## Non-op records

- `cost5-sb-price.jsonl`: 2 non-op record(s) (sb-price, sb-workload-measured) — see file for full run data.
- `ctq4-memory.jsonl`: 3 non-op record(s) (browser_js_heap_peak, browser_page_memory_measureUserAgentSpecificMemory, wasm_linear_arena_direct_size) — see file for full run data.
- `scvd-floor.jsonl`: 3 non-op record(s) (?) — see file for full run data.
- `scvd-soak2.jsonl`: 1 non-op record(s) (paired_soak_5x30s_load_vs_idle_baseline) — see file for full run data.
- `scvd-tail.jsonl`: 3 non-op record(s) (fence_definition, tail_invariance_verdict) — see file for full run data.
- `scvd-wasm-vs-host.jsonl`: 3 non-op record(s) (ramp16_p99_vs_host_p99, ramp16_wall_vs_host_p50, ramp256_wall_host_equiv_unavailable) — see file for full run data.
- `spc-watch.jsonl`: 1 non-op record(s) (scvd_tier1_spc_rule) — see file for full run data.
- `spc-watch2.jsonl`: 1 non-op record(s) (scvd_tier1_spc_rule_disambiguation) — see file for full run data.
- `wire-parity.jsonl`: 1 non-op record(s) (sdk-e2e-6cell) — see file for full run data.

---
End of generated bench report.
