# Bench Results — v26.10.25

Aggregated from `docs/jira/v26.10.25/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.25/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b2-release — ctq

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| arm_put | 200 | 0 | 0.54 | 0.74 | 1.00 | 0 |
| cosmos_roundtrip | 400 | 0 | 0.67 | 0.95 | 1.05 | 0 |
| amqp_first_frame | 50 | 0 | 0.99 | 1.24 | 5.46 | 0 |
| substrate_boot | 5 | 0 | 1607.00 | 2301.00 | 2301.00 | 0 |
---
End of generated bench report.
