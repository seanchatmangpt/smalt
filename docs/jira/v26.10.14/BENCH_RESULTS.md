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

## a9 — arm-auth-enforce

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| challenge-flood-tokenless-401 | 20000 | 19802 | 1.00 | 6.00 | 8.00 | 0 |
| token-attach-5050 | 20000 | 20000 | 1.00 | 7.00 | 8.00 | 0 |
| all-valid-signed-reads-baseline | 10000 | 9901 | 1.00 | 4.00 | 4.00 | 0 |
| sustained-challenge-flood-20s | 1339656 | 66949 | 1.00 | 3.00 | 7.00 | 0 |
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
| producer-send | 5625 | 188 | 5.34 | 7.79 | 8.71 | 0 |
## b4 — servicebus

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| send | 0 | 0 | 0.00 | 0.00 | 0.00 | 3 |
| send+receive-complete-roundtrip | 4296 | 95 | 4207.92 | 5042.01 | 5682.55 | 2 |
| send | 2000 | 51 | 0.25 | 0.30 | 0.37 | 4 |
| send+receive-complete-roundtrip | 2000 | 50 | 370.98 | 569.32 | 577.04 | 3 |
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
| enqueue_1kib | 50000 | 753 | 0.00 | 0.00 | 0.00 | 0 |
| dequeue_ack_1kib | 50000 | 450 | 0.00 | 0.00 | 0.00 | 0 |
| session_delivery_rt | 4000 | 888 | 0.00 | 0.00 | 0.00 | 0 |
| frame_transfer_encdec | 50000 | 43872 | 0.00 | 0.00 | 0.00 | 0 |
| e2e_store_rt_1kib | 50000 | 37649 | 0.00 | 0.00 | 0.00 | 0 |
| enqueue_1kib_depth1 | 50000 | 63190 | 0.00 | 0.00 | 0.00 | 0 |
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
## c1 — blob-ts

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| archive-64kib-put | 100 | 2033 | 0.46 | 0.59 | 0.71 | 0 |
| composite-seq-archive-64kib | 76183 | 2539 | 0.37 | 0.49 | 0.67 | 0 |
## c1 — blob-ts-worm

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| worm-archive-under-legal-hold | 10 | 1271 | 0.73 | 1.38 | 1.38 | 0 |
## c1 — cosmos+blob

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| composite-ingest-plus-archive | 260691 | 4345 | 0.43 | 0.58 | 0.82 | 0 |
## c1 — cosmos-ts

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| ingest-2kib-upsert | 500 | 1704 | 0.43 | 0.74 | 4.43 | 0 |
| transform-continuation-walk | 500 | 36036 | 2.24 | 4.92 | 4.92 | 0 |
| composite-seq-ingest-2kib | 115132 | 3838 | 0.25 | 0.31 | 0.43 | 0 |
## c2 — cosmos

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| point-read-under-pipeline | 8857 | 2878 | 0.30 | 0.40 | 0.48 | 0 |
## c4 — cosmos

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| cosmos_create_plaintext | 200 | 1984 | 0.48 | 0.72 | 0.79 | 0 |
| cosmos_read_plaintext | 200 | 2619 | 0.34 | 0.57 | 0.98 | 0 |
## c4 — envelope

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| envelope_write_kv_dek_per_doc | 200 | 843 | 1.15 | 1.57 | 1.68 | 0 |
| envelope_read_kv_decrypt_per_doc | 200 | 457 | 2.10 | 2.77 | 3.55 | 0 |
| keyreuse_write_cached_dek | 200 | 1774 | 0.46 | 0.77 | 1.15 | 0 |
| keyreuse_read_cached_dek | 200 | 2311 | 0.39 | 0.70 | 0.94 | 0 |
## c4 — keyvault-crypto

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| kv_encrypt | 100 | 1367 | 0.70 | 0.94 | 1.01 | 0 |
| kv_decrypt | 100 | 400 | 2.45 | 2.98 | 4.04 | 0 |
## c6 — resourcegraph

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| rg_project_top100 | 5998 | 600 | 1.62 | 1.91 | 2.17 | 0 |
## c6 — sentinel

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| dcr_ingest_500B_rows | 5000 | 33774 | 2.05 | 2.34 | 46.33 | 0 |
| kql_where_order_project_take_idle | 30 | 96 | 9.79 | 14.08 | 22.47 | 0 |
| kql_where_order_project_take_under_ingest | 148 | 15 | 94.03 | 430.19 | 496.70 | 0 |
| kql_take100000_cap_under_load | 11 | 1 | 784.18 | 1865.68 | 1865.68 | 0 |
## lc1 — cloud-chain-blob-journal

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop6 | 200 | 2387 | 0.42 | 0.57 | 0.78 | 0 |
## lc1 — cloud-chain-cosmos-cas

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop3 | 200 | 1167 | 0.86 | 1.06 | 1.41 | 0 |
## lc1 — cloud-chain-e2e

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| cycle | 200 | 176 | 5.67 | 7.76 | 8.54 | 0 |
## lc1 — cloud-chain-eventhubs

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop5 | 200 | 3080 | 0.33 | 0.42 | 0.54 | 0 |
## lc1 — cloud-chain-kv-sign

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop4 | 200 | 645 | 1.55 | 1.82 | 2.06 | 0 |
## lc1 — cloud-chain-next-ingest

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop2 | 200 | 1238 | 0.81 | 1.20 | 1.62 | 0 |
## lc1 — cloud-chain-resource-graph

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop7 | 200 | 2426 | 0.41 | 0.59 | 0.86 | 0 |
## lc1 — cloud-chain-sentinel-ryw

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop8 | 200 | 1163 | 0.86 | 1.07 | 1.20 | 0 |
## lc1 — cloud-chain-sts

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| hop1 | 200 | 2240 | 0.45 | 0.60 | 0.94 | 0 |
## n2 — next16-server-action

| op | n | ops/sec | p50 ms | p95 ms | p99 ms | errors |
|---|---|---|---|---|---|---|
| action-storm | 0 | 1016 | 196.28 | 369.15 | 8176.80 | 0 |
| action-storm | 0 | 1045 | 176.44 | 430.01 | 10381.96 | 0 |
| action-storm | 0 | 1129 | 87.66 | 129.81 | 141.85 | 0 |
## Non-op records

- `a1-change-feed.jsonl`: 2 non-op record(s) (baseline, stall) — see file for full run data.
- `a2-cas-contention-sdk.jsonl`: 21 non-op record(s) (cas_contention, cas_contention_agg, cleanup_err, done, meta) — see file for full run data.
- `a2-cas-contention.jsonl`: 65 non-op record(s) (cas_contention, done, meta, round_proof) — see file for full run data.
- `a3-cross-partition.jsonl`: 10 non-op record(s) (?) — see file for full run data.
- `a4-crypto.jsonl`: 14 non-op record(s) (azure_cost_rows, ecdsa_p256_sign, ecdsa_p256_verify, ed25519_sign_cached, ed25519_sign_pattern, ed25519_verify, openssl_spawn_par_conc16, openssl_spawn_seq, receipt_signer_roundtrip, receipt_signer_sign, receipt_signer_verify, rs256_sign, rs256_verify, sha256_digest) — see file for full run data.
- `a6-port-exhaustion.jsonl`: 2 non-op record(s) (bench_start, preflight_fail) — see file for full run data.
- `a9-auth-flood-rss.jsonl`: 5 non-op record(s) (?) — see file for full run data.
- `b10-soak-spike.jsonl`: 3 non-op record(s) (soak_15min_mixed_50rps, spike_10x500x5) — see file for full run data.
- `b11-chaos.jsonl`: 3 non-op record(s) (chaos_kill, phase-record, tls_churn) — see file for full run data.
- `b4-messaging-ts-run2.jsonl`: 4 non-op record(s) (meta, result, uncaught-exceptions) — see file for full run data.
- `b4-messaging-ts.jsonl`: 3 non-op record(s) (meta, result) — see file for full run data.
- `b6-lro-sdk.jsonl`: 9 non-op record(s) (phase-record) — see file for full run data.
- `b7-store-beam.jsonl`: 23 non-op record(s) (beam_meta, done, insert_new_race_64, list_prefix_10k) — see file for full run data.
- `c2-sb-cosmos.jsonl`: 11 non-op record(s) (meta, preload, provision-check, result, summary) — see file for full run data.
- `c4-kv-cosmos.jsonl`: 1 non-op record(s) (crypto_tax_summary) — see file for full run data.
- `c5-arm-storm.jsonl`: 1 non-op record(s) (phase-record) — see file for full run data.
- `c7-cross-soak.jsonl`: 14 non-op record(s) (erlang-memory, meta, sample) — see file for full run data.
- `c8-chaos-cross.jsonl`: 47068 non-op record(s) (?) — see file for full run data.
- `c9-cost-model.jsonl`: 16 non-op record(s) (64k-put-block, 8k-put-block, UNMEASURED, b10-soak-50rps-mixed (blob+cosmos+sb+eh), beam-send-1kib, dcr-ingest-500B, envelope-read-kv-decrypt-per-doc, full-query-1000doc, kv-decrypt, kv-encrypt, point-read, producer-send, py-8k-put, read-storm-8981/s + lro-23.65/s, rg-project-top100, send+recv-complete-RT) — see file for full run data.
- `lifecycle-8hop.jsonl`: 2 non-op record(s) (cost-ledger-1M, kd-absent) — see file for full run data.
- `n1-grid.jsonl`: 13 non-op record(s) (?) — see file for full run data.
- `n3-rsc-race.jsonl`: 275 non-op record(s) (n3-rsc-race) — see file for full run data.
- `n4-ingest.jsonl`: 3 non-op record(s) (?) — see file for full run data.
- `n5-compute.jsonl`: 4 non-op record(s) (boot, interaction-60hz-under-compute, post-termination-reclaim, verdict) — see file for full run data.
- `n6-isr.jsonl`: 5 non-op record(s) (?) — see file for full run data.
- `n7-sse-herd.jsonl`: 15 non-op record(s) (?) — see file for full run data.
- `n8-soak.jsonl`: 15 non-op record(s) (heapsnapshot, metrics, summary) — see file for full run data.
- `recon-soak.jsonl`: 5389 non-op record(s) (mem-telemetry-sample) — see file for full run data.

---
End of generated bench report.
