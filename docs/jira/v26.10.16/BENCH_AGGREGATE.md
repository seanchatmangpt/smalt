# Cross-Window Benchmark Aggregate — v26.10.16

Generated: 2026-10-16. Sources read directly from disk (jsonl parsed row by row);
no numbers fabricated. Standing: PARTIAL_ALIVE (aggregation of receipts, no new
execution).

## Machine fingerprint

`just bench-machine`:

```json
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

All measurement lanes in both windows ran on this single host (`darwin/arm64
local`, 16 cores / 48 GB). Rows from non-M3-Max machines: **none found**.
Schema note: most jsonl rows omit the `machine` field entirely (lane-schema
drift across v26.10.14 lanes); the only rows embedding the fingerprint dict
inline are `c1-cosmos-blob.jsonl` (7 rows) and the a1/a2/a3 meta rows. No
contradicting fingerprint appears anywhere in the corpus.

## Provenance table (file → parsed rows → machine → window date)

All under `docs/jira/`. "std rows" = rows carrying the standard
`{lane,surface,op,n,ops_per_sec,...}` bench row; "rich" = lane-specific event
schemas (also valid JSON, counted separately). Malformed = non-JSON lines.

### v26.10.14 window (`v26.10.14/bench/`, files stamped 2026-10-15)

| File | std rows | rich/other rows | machine | note |
|---|---|---|---|---|
| a1-change-feed.jsonl | 0 | 2 | M3 Max (inline) | rich a1 pipeline schema |
| a2-cas-contention.jsonl | 0 | 65 | M3 Max (meta rows) | CAS contention courts |
| a2-cas-contention-sdk.jsonl | 0 | 21 | M3 Max (meta) | SDK-tier CAS |
| a3-cross-partition.jsonl | 0 | 10 | M3 Max (meta) | atomicity court, 2 runs |
| a4-crypto.jsonl | 0 | 14 | M3 Max (meta) | beam-crypto, `ops_per_s` field |
| a6-port-exhaustion.jsonl | 0 | 1 | M3 Max (meta) | 1 malformed tail line |
| a7-hns-rename.jsonl | 0 | 0 | — | **9 malformed (Erlang-term) lines — SKIP, see below** |
| a8-lro-storm.jsonl | 0 | 0 | — | **7 malformed (Erlang-term) lines — SKIP, see below** |
| a9-auth-flood.jsonl | 4 | 0 | M3 Max | auth flood std rows |
| a9-auth-flood-rss.jsonl | 0 | 5 | M3 Max (meta) | RSS sidecar |
| b2-blob-ts.jsonl | 4 | 0 | M3 Max | blob TS SDK bench |
| b2b-blob-hdr.jsonl | 1 | 0 | M3 Max | header-variant rerun |
| b3-cosmos-ts.jsonl | 4 | 0 | M3 Max | cosmos TS SDK bench |
| b3b-cosmos-hdr.jsonl | 2 | 0 | M3 Max | header-variant rerun |
| b4-messaging-ts.jsonl | 3 | 3 | M3 Max | SB/EH SDK bench (run 1) |
| b4-messaging-ts-run2.jsonl | 3 | 4 | M3 Max | run 2 |
| b5-python-mirror.jsonl | 4 | 0 | M3 Max | Python SDK mirror |
| b6-lro-sdk.jsonl | 9 | 0 | M3 Max | LRO SDK bench |
| b7-store-beam.jsonl | 4 | 23 | M3 Max | BEAM store bench |
| b7b-store-beam.jsonl | 3 | 0 | M3 Max | 1M-op rerun |
| b8-amqp-beam.jsonl | 6 | 18 | M3 Max | AMQP BEAM bench (re-run 2026-10-16 08:09) |
| b8b-amqp-beam.jsonl | 5 | 0 | M3 Max | AMQP rerun |
| b9-eh-beam.jsonl | 10 | 10 | M3 Max | EH BEAM bench |
| b9b-eh-beam.jsonl | 5 | 0 | M3 Max | EH rerun |
| b10-soak-spike.jsonl | 0 | 3 | M3 Max | pointer rows to tmp receipts |
| b11-chaos.jsonl | 3 | 0 | M3 Max | chaos-kill / tls-churn pointers (exit 0, PASS) |
| c1-cosmos-blob.jsonl | 7 | 0 | **M3 Max (inline dict)** | composite pipelines |
| c2-sb-cosmos.jsonl | 1 | 11 | M3 Max | SB→Cosmos pipeline |
| c4-kv-cosmos.jsonl | 0 | 9 | M3 Max | KV+cosmos crypto (rich `ops_per_s`) |
| c5-arm-storm.jsonl | 0 | 1 | M3 Max | ARM read storm summary row |
| c6-sentinel-rg.jsonl | 5 | 0 | M3 Max | sentinel/KQL ingest |
| c7-cross-soak.jsonl | 0 | 14 | M3 Max | 600 s cross-plane soak samples |
| c8-chaos-cross.jsonl | 0 | 47,068 | M3 Max | per-probe chaos samples + kill events |
| c9-cost-model.jsonl | 0 | 16 | M3 Max | directional Azure cost model |
| lifecycle-8hop.jsonl | 0 | 0 | — | **EMPTY (0 bytes) — gap, see below** |
| n1-grid.jsonl | 0 | 13 | M3 Max | topo grid interaction |
| n2-action-storm.jsonl | 0 | 3 | M3 Max | action storm summary |
| n3-rsc-race.jsonl | 0 | 275 | M3 Max | RSC race ledger |
| n4-ingest.jsonl | 0 | 3 | M3 Max | 5000 rps ingest windows |
| n5-compute.jsonl | 0 | 4 | M3 Max | worker-pool compute |
| n6-isr.jsonl | 0 | 5 | M3 Max | ISR stampede |
| n7-sse-herd.jsonl | 0 | 15 | M3 Max | SSE herd |
| n8-soak.jsonl | 0 | 15 | M3 Max | 500-cycle memory soak |
| recon-soak.jsonl | 0 | 5,389 | M3 Max | recon soak process/RSS samples |

### v26.10.16 window (`v26.10.16/bench/`, files stamped 2026-10-15/16)

| File | rows | machine | note |
|---|---|---|---
| a1-change-feed.jsonl | 4 (rich) | M3 Max | baseline/stall × 2 runs |
| b7-store-beam.jsonl | 5 std rows | M3 Max | store-beam re-measure |
| wave-telemetry-run2.jsonl | 11 (rich) | — | lane verdict telemetry (not perf ops) |

## Malformed-line note (loud)

16 non-JSON lines exist, exactly as inherited: `a7-hns-rename.jsonl` (9 lines)
and `a8-lro-storm.jsonl` (7 lines) are written in Erlang-term format
(`{depth_levels=8,lane="a7",...}`), not JSON. They are **skipped by this
aggregate**; their qualitative content (HNS rename GAP(blob-hns-atomic-rename),
LRO storm) is covered in v26.10.14 receipts instead. `a6-port-exhaustion.jsonl`
has 1 malformed tail line; its 1 parseable row is counted. Nothing was edited
in the source files.

## Delta table — ops measured in BOTH windows

Only two surfaces have cross-window measurements. Delta = v26.10.16 minus
v26.10.14 (best comparable run in each).

### store-beam (b7)

| op | v26.10.14 (b7/b7b) | v26.10.16 (b7) | delta |
|---|---|---|---|
| put | 1,126,201 ops/s (b7b 1M-op) | 1,006,610 ops/s | −10.6% |
| get | 1,822,172 ops/s (b7b) | 1,694,796 ops/s | −7.0% |
| compare_and_swap | 280,229 ops/s (b7b) | 263,479 ops/s | −6.0% |
| concurrent_put_get_32p | 15,742,705 ops/s (b7) | 11,945,034 ops/s | −24.1% |
| list_prefix_10k | (in b7 rich rows, no std row) | 1,539,172 ops/s | n/a |

The v26.10.16 store-beam re-measure is 6–24% below the v26.10.14 peak. Same
machine fingerprint. The concurrent 32-parallel figure carries the widest
spread (−24%); the single-op numbers are within ~10%. No runtime change
receipt accompanies the delta in either window's receipts dir — recorded, not
explained.

### a1 change-feed pipeline (e2e upsert→archive latency)

| op | v26.10.14 (baseline) | v26.10.16 (baseline, best of 2) | delta |
|---|---|---|---|
| e2e p50 | 21.0 ms | 36.0 ms | +71% |
| e2e p95 | 96.0 ms | 359.0 ms | +274% |
| e2e p99 | 133.0 ms | 444.0 ms | +234% |
| cosmos_upserts/s | 3,724 | (stage table absent in v26.10.16 rows) | n/a |
| stall p50 (adversarial) | 1,560 ms | 1,724 ms | +10.5% |

v26.10.16 a1 rows do not carry the per-stage `stages_per_s` breakdown the
v26.10.14 rows had — stage-level delta not computable; only the e2e latency
and stall windows compare. Baseline e2e tail degraded notably; stall-mode
numbers are close.

## Top-line per class (best measured, with provenance)

- **BEAM store (fastest class)**: `concurrent_put_get_32p` 15.74M ops/s
  (v26.10.14 b7-store-beam.jsonl); get 1.83M, put 1.13M, CAS 280K ops/s
  (b7b 1M-op rerun). v26.10.16 re-measure: 11.9M / 1.69M / 1.01M / 263K.
- **AMQP beam**: frame_transfer_encdec 218,694 ops/s, enqueue_1kib depth-1
  178,233 ops/s, e2e store RT 77,144 ops/s (b8b-amqp-beam.jsonl); re-run
  2026-10-16 (b8): enqueue 86,189, frame encdec 41,312, e2e 35,959 ops/s.
- **Event Hubs beam**: receive-drain 1kib 2,050,283 ops/s
  (b9b, drain-of-100 batch amortized), lock_acquire_release 340,573, next_seq
  193,801 ops/s (b9/b9b).
- **Blob (TS SDK)**: 8k put-block 4,351 ops/s, 64k 2,912 ops/s, byte-equality
  download 1,333 ops/s (b2); header-variant 4,155 ops/s (b2b).
- **Cosmos (TS SDK)**: full 1000-doc query 49,594 ops/s (~20 ms wall per
  1000-doc page), point-read 4,405 ops/s, upsert-create-only 4,406 ops/s
  (b3). Python mirror: query 30,814 ops/s, put 917 ops/s (b5).
- **Crypto (a4, BEAM-native)**: sha256 2,149,228 ops/s; ECDSA P-256 sign
  36,799 / verify 16,179 ops/s; RS256 verify 25,334 / sign 1,113 ops/s;
  ed25519 sign-cached 13,759 ops/s; receipt-signer roundtrip 1,004 ops/s;
  openssl-spawn par(16) 1,446 ops/s aggregate.
- **Auth flood (a9)**: sustained challenge flood 66,949 ops/s over 1.34M
  requests at p99 7 ms, 0 errors; token-attach 20,000 ops/s.
- **Cross-plane composite (c1)**: transform-continuation-walk 36,036 ops/s;
  composite ingest+archive 4,345 ops/s (M3 Max inline fingerprint).
- **Soak (c7)**: 600 s cross-plane soak; sustained mixed throughput ~
  blob 1,202 / cosmos 1,096 / sb 720 / eh 322 ops/s at start, RSS ~300–360 MB.
- **Chaos (c8 + B-11 + stress receipts)**: 47,068 probe samples across
  cosmos/eh/blob with 2 SIGKILL cycles; kill/reboot recovery witnessed
  (t90 reboot 4.53 s, first success 2.77 s — tmp/chaos-kill-receipt.json via
  b11-chaos.jsonl). Spike: 10 cycles, 500 clients, p95 222 ms, recovery < 1 ms,
  0 5xx (tmp/spike-receipt.json). Flood (autocannon, load harness — not a lane):
  2,501 req/s per cycle, p99 42 ms, 0 5xx.
- **Lifecycle (n1–n8)**: consolidated in
  `v26.10.14/bench/NEXTJS_LIFECYCLE_RESULTS.md` — 8/8 lanes free of linear
  heap growth; N-4 ingest 4,988 rps achieved of 5,000 target at p99 11 ms;
  N-7 SSE herd 5,000 clients, 0 permanent drops; open defects N-3 (React
  #412 pageerror, 1×/50 rounds) and N-5 (worker memory reclaim +93%
  over baseline). Note: `lifecycle-8hop.jsonl` is **empty (0 bytes)** —
  the "8-hop" consolidated row was never emitted to this file; the
  consolidation lives in the markdown, not jsonl.
- **Cost model (c9, directional)**: at measured throughputs, Azure-equivalent
  monthly provisioned cosmos for the b3 point-read rate ≈ $25.7K/month
  (directional list prices, knowledge-cutoff priced).

## Explicit gaps (honest)

- v26.10.16 has only **3 files / ~9 op-rows**: a1 (4 rich rows), b7
  (5 std rows), wave-telemetry (11 verdict rows, not perf ops). There is no
  v26.10.16 bench wave comparable to the 44-file v26.10.14 corpus. Nothing
  fabricated to fill it.
- `v26.10.14/bench/lifecycle-8hop.jsonl` is 0 bytes — no 8-hop jsonl row
  exists anywhere.
- 16 malformed legacy lines (a7/a8) skipped, per the loud note above.
- a2/a3/c4/c5/c7/recon/soak lanes use lane-specific schemas, not the standard
  bench row; their numbers are not in `ops_per_sec` form and are cited
  qualitatively/inline above.
- No non-M3-Max rows exist, so no cross-machine comparison is possible.

## Ladder gates this aggregate does NOT satisfy

This is an aggregation receipt, not a bench run: no substrate was booted, no
ports taken, no result rows were emitted to any lane jsonl by this lane.

## Measurement plan — re-run queue (lane I17, 2026-10-17, plan only — no re-runs in this window)

Two regressions from the current window need a clean re-run before any verdict
is drawn from them:

1. **b7 `concurrent_put_get_32p` −24.1%** (vs the v26.10.14 baseline).
   Re-run plan: quiet host (no concurrent lanes, `substrate-status` empty),
   best-of-3 full `b7_store_beam.exs` runs, per-run `just bench-machine` in the
   receipt; accept the re-run only if the delta reproduces within ±5% —
   otherwise close as noise with all three runs receipted.
2. **a1 `a1-change-feed` p95 +274%**. Re-run plan: same quiet-host/best-of-3
   protocol; additionally the a1 receipt MUST re-capture `stages_per_s` —
   if the stage throughput figure cannot be reproduced, receipt its loss
   explicitly (do not carry the stale number forward).

Both re-runs write only their own lane's result file and follow the
REGISTRY.md port law; neither ran in this window (plan only).
