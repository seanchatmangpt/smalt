# Bench Results — v26.10.21

Aggregated from `docs/jira/v26.10.21/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.21/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## impl21 — app-configuration


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| set_get_cas_delete_x50 | PASS | 50 | 0 |  |

## impl21 — blob


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| putget-c128 | PASS | 128 | 0 |  |
| putget-c128-c4 | PASS | 512 | 0 | canonical scvd_tier12.mjs c128x4 baseline shape |

## impl21 — cosmos


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| putget-c16 | PASS | 48 | 0 |  |
| concurrent_put_get_16legs | PASS | 160 | 0 | canonical scvd_tier1.mjs 16x5 shape |

## impl21 — sb-admin


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| create_delete_get404_queue | PASS | 5 | 0 |  |

## impl21 — servicebus


### Verdict rows (correctness probes, not throughput ops)

| op | verdict | n | errors | reason/note |
|---|---|---|---|---|
| sendrecv-c128 | PASS | 256 | 0 |  |
| sendrecv-c128-c4 | PASS | 1024 | 0 | canonical scvd_tier12.mjs c128x4 baseline shape |

## ja9 — conn_scaling

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| echo_connect_echo | 1000 | 2747 | 123.00 | 246.00 | 362.00 | 0 |
| echo_connect_echo | 8000 | 6650 | 254.00 | 635.00 | 1070.00 | 0 |
| echo_connect_echo | 32000 | 714 | 444.00 | 3746.00 | 5153.00 | 24689 |
## ja9 — honest_ceiling

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| port_push_to_limit | 1048576 | 36 | 0.00 | 0.00 | 0.00 | 0 |
| port_push_to_limit | 1048576 | 16248 | 0.00 | 0.00 | 0.00 | 1 |
## ja9 — process_ceiling

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| spawn_trivial_to_limit | 271483 | 1071429 | 9.33 | 11.00 | 12.00 | 0 |
## ja9 — wire_load

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| blob_put_16workers | 18 | 3 | 36.00 | 152.00 | 170.00 | 0 |
## pb1 — cosmos-sdk-tls-twin

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| settle_r0 | 150 | 280 | 3.56 | 4.17 | 4.61 | 0 |
| settle_r1 | 150 | 141 | 5.00 | 19.34 | 31.02 | 0 |
| settle_r2 | 150 | 131 | 7.59 | 8.84 | 10.80 | 0 |
| settle_r3 | 150 | 83 | 10.96 | 16.14 | 32.08 | 0 |
| settle_r4 | 150 | 58 | 13.81 | 32.81 | 85.34 | 0 |
| settle_r5 | 150 | 54 | 17.15 | 25.31 | 61.16 | 0 |
| settle_r6 | 150 | 54 | 16.06 | 32.19 | 68.12 | 0 |
| settle_r7 | 150 | 51 | 17.91 | 27.40 | 39.87 | 0 |
| settle_r8 | 150 | 41 | 20.79 | 43.92 | 86.97 | 0 |
| settle_r9 | 150 | 44 | 21.00 | 36.66 | 41.41 | 0 |
| settle_r10 | 150 | 30 | 29.18 | 55.47 | 73.98 | 0 |
## pb1 — fond-powl2-native

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| settle_r0 | 150 | 30763 | 0.03 | 0.05 | 0.07 | 0 |
| settle_r1 | 150 | 27154 | 0.04 | 0.05 | 0.06 | 0 |
| settle_r2 | 150 | 22335 | 0.04 | 0.06 | 0.09 | 0 |
| settle_r3 | 150 | 18164 | 0.05 | 0.09 | 0.10 | 0 |
| settle_r4 | 150 | 17464 | 0.06 | 0.07 | 0.10 | 0 |
| settle_r5 | 150 | 15963 | 0.06 | 0.08 | 0.12 | 0 |
| settle_r6 | 150 | 14650 | 0.07 | 0.08 | 0.10 | 0 |
| settle_r7 | 150 | 13534 | 0.07 | 0.09 | 0.09 | 0 |
| settle_r8 | 150 | 11605 | 0.08 | 0.11 | 0.14 | 0 |
| settle_r9 | 150 | 11264 | 0.09 | 0.11 | 0.15 | 0 |
| settle_r10 | 150 | 10808 | 0.09 | 0.11 | 0.14 | 0 |
## pb3 — powl2_executor_inproc

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| settle4_ramp | 64 | 1561 | 40.00 | 40.00 | 40.00 | 0 |
| settle4_ramp | 256 | 1024 | 238.00 | 248.00 | 249.00 | 0 |
| settle4_ramp | 512 | 1202 | 412.00 | 422.00 | 422.00 | 0 |
| settle4_ramp | 1024 | 713 | 1356.00 | 1413.00 | 1414.00 | 0 |
| settle4_ramp | 2048 | 1822 | 986.00 | 1009.00 | 1010.00 | 0 |
| settle4_ramp | 4096 | 2397 | 1166.00 | 1183.00 | 1185.00 | 0 |
| settle4_ramp | 8192 | 996 | 5950.00 | 5988.00 | 5991.00 | 0 |
## pb3x-bkcells — powl2_executor_inproc

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| settle4_ramp | 8192 | 4992 | 681.00 | 810.00 | 828.00 | 0 |
| settle4_ramp | 16384 | 2151 | 801.00 | 856.00 | 860.00 | 0 |
| settle4_ramp | 32768 | 482 | 4000.00 | 4114.00 | 4121.00 | 0 |
## powlbench — powl2-native

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point_read_etag3 | 10000 | 626763 | 0.00 | 0.00 | 0.00 | 0 |
| cas_put_if_match_200 | 10000 | 298080 | 0.00 | 0.00 | 0.01 | 0 |
| executor_settlement_4step | 200 | 9413 | 0.03 | 0.08 | 0.37 | 0 |
| point_read_etag3 | 10000 | 763359 | 0.00 | 0.00 | 0.00 | 0 |
| cas_put_if_match_200 | 10000 | 218996 | 0.00 | 0.01 | 0.05 | 0 |
| executor_settlement_4step_MUTANT_x2steps | 200 | 7233 | 0.11 | 0.16 | 0.23 | 0 |
## t42json — json

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| json_whole_term | 1 | 4 | 231.00 | 231.00 | 231.00 | 0 |
| json_whole_term | 1 | 3 | 315.00 | 315.00 | 315.00 | 0 |
| json_whole_term | 1 | 4 | 244.00 | 244.00 | 244.00 | 0 |
| jason_decode | 1 | 3 | 373.00 | 373.00 | 373.00 | 0 |
| jason_decode | 1 | 2 | 413.00 | 413.00 | 413.00 | 0 |
| jason_decode | 1 | 2 | 491.00 | 491.00 | 491.00 | 0 |
| json_sax_stream | 1 | 7 | 148.00 | 148.00 | 148.00 | 0 |
| json_sax_stream | 1 | 10 | 100.00 | 100.00 | 100.00 | 0 |
| json_sax_stream | 1 | 10 | 97.00 | 97.00 | 97.00 | 0 |
## Non-op records

- `bk33-warm-restart.jsonl`: 5 non-op record(s) (cold_boot, health_probe_post_restart, warm_restart_system_restart) — see file for full run data.
- `bkcells-floor.jsonl`: 2 non-op record(s) (?) — see file for full run data.
- `court_bench_20261021223808052.jsonl`: 3 non-op record(s) (?) — see file for full run data.
- `court_bench_20261021T223254.701Z.jsonl`: 3 non-op record(s) (?) — see file for full run data.
- `court_bench_20261021T225058.824Z.jsonl`: 3 non-op record(s) (?) — see file for full run data.
- `pb2-reductions-step.jsonl`: 7 non-op record(s) (?) — see file for full run data.
- `pb3-escalated-bkcells.jsonl`: 1 non-op record(s) (wall_summary) — see file for full run data.
- `pb3-executor-ceiling.jsonl`: 1 non-op record(s) (wall_summary) — see file for full run data.
- `pb6-dual-boundary.jsonl`: 10 non-op record(s) (1-lease, 2-validate, 3-cas, 4-seal, 5-observe) — see file for full run data.
- `t36-boot.jsonl`: 4 non-op record(s) (boot_1_wall_ms, boot_2_wall_ms, boot_3_wall_ms, verdict) — see file for full run data.
- `t42-json.jsonl`: 1 non-op record(s) (verdict) — see file for full run data.
- `t43-p99-hunt.jsonl`: 15 non-op record(s) (?) — see file for full run data.
- `t45-boot-phases.jsonl`: 6 non-op record(s) (cold-boot-1, cold-boot-2, cold-boot-3, cold-boot-4) — see file for full run data.
- `t47-release-boot.jsonl`: 9 non-op record(s) (boot_to_all_listeners, serve_probe, warm_restart_system_restart, warm_stop_start_cycle) — see file for full run data.
- `ttv6-cold-boot.jsonl`: 8 non-op record(s) (boot_to_all_listeners, health_probe, warm_restart_system_restart, warm_stop_start_cycle) — see file for full run data.
- `ttv7-warmed-p99.jsonl`: 2 non-op record(s) (graphlaw_guarded_cold, graphlaw_guarded_warm) — see file for full run data.
- `ttv7-warmed-p99.load132.jsonl`: 2 non-op record(s) (graphlaw_guarded_cold, graphlaw_guarded_warm) — see file for full run data.

---
End of generated bench report.
