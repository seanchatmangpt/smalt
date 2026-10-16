# Bench Lane Registry — v26.10.14

Shared infra owned by lane B-1 (`scripts/bench/lib.sh`, `justfile.d/15-bench.just`,
`scripts/bench/report.py`, this file). Every lane B-2..B-12:

```bash
source /Users/sac/smalt/scripts/bench/lib.sh
pid=$(bench_boot b3)          # private port block, MIX_ENV=test, anonymous auth
# ... run ops, collect latencies (ms) ...
read p50 p95 p99 <<<"$(latencies | bench_percentile)"
BENCH_LANE=b3 bench_emit "$(bench_result_file b3)" <surface> <op> <n> <ops_per_sec> $p50 $p95 $p99 <errors>
bench_down "$pid"
```

Port law: lane `bN` -> ports `39000+10N` .. `39000+10N+5`
(ARM, egress/data, AMQP, event_hubs, arm_tls, mcp). Pre-flight collision check in
`bench_boot` refuses to boot on a held port.

Result files: one `.jsonl` per lane in `docs/jira/v26.10.14/bench/`. Row schema:
`{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}`.

| lane | result file | scope (assigned by coordinator) |
|---|---|---|
| b1 | b1.jsonl | core harness (this dir, lib.sh, report.py, 15-bench.just, BENCH_RESULTS.md) |
| b2 | b2-blob-ts.jsonl | blob SDK (TypeScript) |
| b3 | b3-cosmos-ts.jsonl | Cosmos SDK (TypeScript) |
| b4 | b4-arm-ts.jsonl | ARM / resource management SDK (TypeScript) |
| b5 | b5-blob-py.jsonl | blob SDK (Python) |
| b6 | b6-lro-sdk.jsonl | LRO / SDK latency (observed on disk 2026-10-15) |
| b7 | b7-store-beam.jsonl | in-BEAM native store ops (observed on disk 2026-10-15) |
| b8 | b8-servicebus-py.jsonl | Service Bus SDK (Python) |
| b9 | b9-eventhubs.jsonl | Event Hubs SDK |
| b10 | b10-cli.jsonl | smalt CLI surface |
| b11 | b11-beam-native.jsonl | in-BEAM native (no HTTP) op latency |
| b12 | b12-http-raw.jsonl | raw HTTP client (no SDK) front-door latency |

Disjointness: lanes write ONLY their own result file and must not edit
`scripts/bench/`, `justfile.d/15-bench.just`, `Justfile`, or this file.
