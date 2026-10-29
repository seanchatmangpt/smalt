# Bench Results — v26.10.19

Aggregated from `docs/jira/v26.10.19/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.19/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b2 — blob

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| 8k-put-block-blob | 87173 | 2906 | 0.29 | 0.61 | 0.93 | 0 |
| 64k-put-block-blob | 70822 | 2361 | 0.38 | 0.64 | 0.94 | 0 |
| download-byte-equality | 40 | 1212 | 0.67 | 1.35 | 4.29 | 0 |
| list-blobs-flat-fullpage | 50 | 104 | 9.23 | 11.04 | 20.14 | 0 |
---
End of generated bench report.
