# Bench Results — v26.10.18

Aggregated from `docs/jira/v26.10.18/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.18/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b7 — store-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| put | 120000 | 368056 | 0.00 | 0.00 | 0.00 | 0 |
| get | 120000 | 1362212 | 0.00 | 0.00 | 0.00 | 0 |
| compare_and_swap | 120000 | 135634 | 0.00 | 0.01 | 0.01 | 0 |
| concurrent_put_get_32p | 512000 | 1326652 | 0.00 | 0.00 | 0.00 | 0 |
| list_prefix_10k | 10000 | 1451379 | 0.00 | 6.89 | 0.00 | 0 |
## Non-op records

- `have-11-drill.jsonl`: 7 non-op record(s) (alert_policy_eval, boot_private_substrate, meta_watchdog_dry_run, sigkill_midwrite, storage_probe_mutation_witness, storage_verify_clean_open, telemetry_emit_all) — see file for full run data.

---
End of generated bench report.
