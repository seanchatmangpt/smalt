# Bench Results — v26.10.14

Aggregated from `docs/jira/v26.10.14/bench/*.jsonl` by `just bench-report`
(scripts/bench/report.py). One row per recorded op. Generated, not hand-edited.

## Methodology

Op rows below are `{lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms,
errors, machine}` per `scripts/bench/REGISTRY.md`. SDK lanes measure the Azure
SDK against the smalt substrate; b7/b8/b9 measure the in-BEAM native surface.
SDK-vs-BEAM multiplier narrative lives in the per-lane receipts
(`docs/jira/v26.10.14/receipts/bench-*.md`), not restated here. Non-op record
classes (chaos/TLS run records, phase blobs, meta lines) are listed per lane,
not rendered as op rows.

## b2 — blob-ts-sdk

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| 8k-put-block-blob | 130535 | 4351 | 0.22 | 0.30 | 0.41 | 0 |
| 64k-put-block-blob | 87351 | 2912 | 0.33 | 0.42 | 0.53 | 0 |
| download-byte-equality | 40 | 1333 | 0.64 | 0.95 | 3.69 | 0 |
| list-blobs-flat-fullpage | 50 | 101 | 9.45 | 11.33 | 19.31 | 0 |
## b2b — blob-ts-sdk-hdr

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| 8k-put-block-blob | 124644 | 4155 | 0.23 | 0.29 | 0.36 | 0 |
## b3 — cosmos-ts-sdk

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point-read | 500 | 4405 | 0.21 | 0.30 | 0.42 | 0 |
| full-query | 1000 | 49594 | 20.16 | 19.48 | 20.71 | 0 |
| continuation-walk | 1000 | 506 | 1.93 | 2.41 | 2.41 | 0 |
| upsert-create-only | 1000 | 4406 | 0.23 | 0.23 | 0.23 | 0 |
## b3b — cosmos-ts-sdk-hdr

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point-read | 500 | 3492 | 0.27 | 0.36 | 0.52 | 0 |
| full-query | 1000 | 42044 | 23.65 | 23.35 | 23.78 | 0 |
## b4 — eventhubs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| producer-send | 9693 | 323 | 3.06 | 5.01 | 6.38 | 0 |
| producer-send | 10454 | 348 | 2.95 | 4.02 | 5.34 | 0 |
## b4 — servicebus

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| send | 0 | 0 | 0.00 | 0.00 | 0.00 | 3 |
| send+receive-complete-roundtrip | 4296 | 95 | 4207.92 | 5042.01 | 5682.55 | 2 |
| send | 96 | 2 | 0.37 | 1.19 | 11.69 | 6 |
| send+receive-complete-roundtrip | 13200 | 289 | 719.88 | 2100.77 | 30393.09 | 34 |
## b5 — blob

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| put_block_blob_8k | 9172 | 917 | 1.05 | 1.33 | 1.57 | 0 |
| download_1mib | 20 | 744 | 1.34 | 1.43 | 1.56 | 0 |
## b5 — cosmos

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point_read | 500 | 295 | 3.23 | 4.21 | 6.01 | 0 |
| query_select_all_1000docs | 1000 | 30814 | 32.45 | 33.90 | 33.90 | 0 |
## b7 — store-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| put | 120000 | 1037470 | 0.00 | 0.00 | 0.01 | 0 |
| get | 120000 | 1828098 | 0.00 | 0.00 | 0.00 | 0 |
| compare_and_swap | 120000 | 282350 | 0.00 | 0.00 | 0.00 | 0 |
| concurrent_put_get_32p | 512000 | 15742705 | 0.00 | 0.00 | 0.00 | 0 |
## b7b — store-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| get | 1000000 | 1822172 | 0.50 | 0.00 | 1.00 | 0 |
| put | 1000000 | 1126201 | 0.83 | 0.00 | 1.29 | 0 |
| compare_and_swap | 1000000 | 280229 | 3.33 | 0.00 | 4.50 | 0 |
## b8 — amqp-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| enqueue_1kib | 50000 | 826 | 0.00 | 0.00 | 0.00 | 0 |
| dequeue_ack_1kib | 50000 | 419 | 0.00 | 0.00 | 0.00 | 0 |
| session_delivery_rt | 4000 | 870 | 0.00 | 0.00 | 0.00 | 0 |
| frame_transfer_encdec | 50000 | 41312 | 0.00 | 0.00 | 0.00 | 0 |
| e2e_store_rt_1kib | 50000 | 35959 | 0.00 | 0.00 | 0.00 | 0 |
| enqueue_1kib_depth1 | 50000 | 86189 | 0.00 | 0.00 | 0.00 | 0 |
| enqueue_1kib | 50000 | 729 | 0.00 | 0.00 | 0.00 | 0 |
| dequeue_ack_1kib | 50000 | 433 | 0.00 | 0.00 | 0.00 | 0 |
| session_delivery_rt | 4000 | 891 | 0.00 | 0.00 | 0.00 | 0 |
| frame_transfer_encdec | 50000 | 43807 | 0.00 | 0.00 | 0.00 | 0 |
| e2e_store_rt_1kib | 50000 | 44257 | 0.00 | 0.00 | 0.00 | 0 |
| enqueue_1kib_depth1 | 50000 | 91756 | 0.00 | 0.00 | 0.00 | 0 |
## b8b — amqp-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| frame_transfer_encdec | 1000000 | 218694 | 4.21 | 0.00 | 8.21 | 0 |
| enqueue_1kib_depth1 | 853975 | 178233 | 5.58 | 0.00 | 6.25 | 0 |
| e2e_store_rt_1kib | 377700 | 77144 | 12.75 | 0.00 | 16.12 | 0 |
| session_delivery_rt | 243079 | 49313 | 19.67 | 0.00 | 26.17 | 0 |
| dequeue_ack_1kib | 7850 | 1571 | 623.14 | 0.00 | 987.96 | 0 |
## b9 — eh-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| send_event_1kib | 25000 | 344 | 2.81 | 5.74 | 6.12 | 0 |
| receive_events_drain_1kib | 25000 | 216999 | 2.28 | 3.12 | 6.13 | 0 |
| next_sequence | 50000 | 210236 | 0.00 | 0.00 | 0.00 | 0 |
| reserve_processing | 20000 | 126774 | 0.00 | 0.00 | 0.00 | 0 |
| send_event_1kib | 25000 | 336 | 2.69 | 5.97 | 6.38 | 0 |
| receive_events_drain_1kib | 25000 | 208677 | 2.28 | 3.22 | 6.73 | 0 |
| next_sequence | 50000 | 193135 | 0.00 | 0.00 | 0.00 | 0 |
| reserve_processing | 20000 | 131537 | 0.00 | 0.00 | 0.00 | 0 |
## b9 — sb-lock

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| lock_acquire_release | 20000 | 299531 | 0.00 | 0.00 | 0.00 | 0 |
| lock_acquire_release | 20000 | 266152 | 0.00 | 0.00 | 0.00 | 0 |
## b9b — eh-beam

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| lock_acquire_release | 1000000 | 340573 | 2.75 | 0.00 | 4.42 | 0 |
| next_sequence | 926116 | 193801 | 4.58 | 0.00 | 11.88 | 0 |
| reserve_processing | 860867 | 179594 | 4.79 | 0.00 | 11.12 | 0 |
| receive_events_drain_1kib | 20467 | 2050283 | 240.96 | 0.00 | 318.81 | 0 |
| send_event_1kib | 3351 | 670 | 1456.79 | 0.00 | 1972.54 | 0 |
## Non-op records

- `b10-soak-spike.jsonl`: 3 non-op record(s) (soak_15min_mixed_50rps, spike_10x500x5) — see file for full run data.
- `b11-chaos.jsonl`: 3 non-op record(s) (chaos_kill, phase-record, tls_churn) — see file for full run data.
- `b4-messaging-ts-run2.jsonl`: 4 non-op record(s) (meta, result, uncaught-exceptions) — see file for full run data.
- `b4-messaging-ts.jsonl`: 4 non-op record(s) (meta, result, uncaught-exceptions) — see file for full run data.
- `b6-lro-sdk.jsonl`: 9 non-op record(s) (phase-record) — see file for full run data.
- `b7-store-beam.jsonl`: 23 non-op record(s) (beam_meta, done, insert_new_race_64, list_prefix_10k) — see file for full run data.
- `recon-soak.jsonl`: 5389 non-op record(s) (mem-telemetry-sample) — see file for full run data.

---
End of generated bench report.
