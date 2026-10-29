# Bench Results — v26.10.22

Aggregated from `docs/jira/v26.10.22/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.22/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## t35-lro — arm

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| lro-namespace-provision-e2e | 20 | 11 | 89.00 | 119.00 | 119.00 | 0 |
| arm-queue-put-sync | 20 | 606 | 2.00 | 2.00 | 3.00 | 0 |
| lro-namespace-provision-e2e | 20 | 65 | 12.00 | 31.00 | 39.00 | 0 |
| arm-queue-put-sync | 20 | 526 | 2.00 | 3.00 | 4.00 | 0 |
## Non-op records

- `t35-lro.jsonl`: 2 non-op record(s) (lro-poll-contract) — see file for full run data.

---
End of generated bench report.
