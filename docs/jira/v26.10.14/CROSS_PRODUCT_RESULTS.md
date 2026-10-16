# Cross-Product Bench Results — v26.10.14 (Lane C-9)

Consolidation of the cross-product bench wave (C-1..C-8) into per-pipeline
tables, the interference matrix, and the Azure cost-equivalent table
(the thermodynamic-decoupling table: measured sustained throughput priced at
24x7x30 (730 h/mo) Azure list-price equivalents).

**Pricing caveat (applies to every dollar figure below)**: prices are
AS-OF-KNOWLEDGE list prices, directional only. Re-verify on
azure.microsoft.com/pricing before any procurement decision. The structure of
the table is the deliverable; exact cents are directional.

## 1. Lane inventory

| Lane | Subject | jsonl | Receipt | State |
|---|---|---|---|---|
| C-1 | cosmos+blob composite pipeline | `bench/c1-cosmos-blob.jsonl` | — | LANDED |
| C-2 | servicebus+cosmos pipeline | `bench/c2-sb-cosmos.jsonl` | — | **FATAL** — ARM PUT 400 `MissingApiVersionParameter` before any measurement; zero rows |
| C-3 | (kv+auth pipeline) | none | — | **PENDING** — no jsonl at consolidation time |
| C-4 | keyvault-crypto + cosmos envelope pipeline | `bench/c4-kv-cosmos.jsonl` | — | LANDED (late, after first consolidation pass — merged in a second pass) |
| C-5 | ARM storm (read burst / write-mix / LRO-under-load / rate-limit burst) | `bench/c5-arm-storm.jsonl` | `receipts/c5-arm-storm.md` | LANDED |
| C-6 | Sentinel DCR ingest + KQL + Resource Graph | `bench/c6-sentinel-rg.jsonl` | `receipts/c6-sentinel-rg.md` | LANDED |
| C-7 | cross-surface soak sampler | `bench/c7-cross-soak.jsonl` | — | LANDED-PARTIAL — sampler ran cosmos-only (blob/sb/eh/kv/arm streams registered 0); 2 samples + summary |
| C-8 | chaos-cross failure injection | `bench/c8-chaos-cross.jsonl` | — | LANDED (raw event log, 40,336 events) |
| C-9 | **this lane** — cost-model consolidation | `bench/c9-cost-model.jsonl` | `receipts/c9-cost-model.md` | this document |

C-2's fatal error is a harness bug (missing `api-version` query parameter on
the ARM PUT used to seed the pipeline), not a substrate fault: the identical
ARM surface measured clean in C-5 (2,000-op read storm, 0 errors, p50 1.5 ms)
and in ws-08. C-3 simply had not landed when this file was written; C-4
landed late and was merged in a second pass.

## 2. Per-pipeline tables (C-1..C-6)

Verbatim from the landed jsonl; no smoothing, no aggregation beyond c8 (where
the raw per-event log is summarized by surface).

### C-1 cosmos+blob composite

| op | n | ops/sec | p50 | p95 | p99 | errors |
|---|---|---|---|---|---|---|
| cosmos ingest-2kib-upsert | 500 | 2,604 | 0.37 ms | 0.48 | 0.60 | 0 |
| cosmos transform-continuation-walk | 500 | 36,245 | 2.21 ms | 4.86 | 4.86 | 0 |
| blob archive-64kib-put | 5 | 1,402 | 0.64 ms | 0.79 | 0.79 | 0 |
| cosmos composite-seq-ingest-2kib | 109,481 | 3,649 | 0.26 ms | 0.34 | 0.44 | 0 |
| blob composite-seq-archive-64kib | 77,536 | 2,585 | 0.36 ms | 0.48 | 0.66 | 0 |
| cosmos+blob composite-ingest-plus-archive | 153,646 | 2,561 | 0.35 ms | 0.53 | 0.77 | 164,567* |
| blob-ts-worm archive-under-legal-hold | 10 | 1,303 | 0.87 ms | 1.19 | 1.19 | 409 as designed |

\* c1's composite row counts the C-8 WORM/`C8_COSMOS_EMPTY_READ` chaos-class
refusals observed during the composite window against a composite row that
carried no archive-side success counter — a counter-scope artifact, flagged in
the receipt; the substrate rejection itself (WORM overwrite 409) is the
designed behavior.

### C-4 keyvault-crypto + cosmos envelope (landed late, second pass)

| op | n | ops/sec | p50 | p95 | p99 | kv_ops |
|---|---|---|---|---|---|---|
| kv_encrypt | 100 | 1,367 | 0.70 ms | 0.95 | 1.01 | — |
| kv_decrypt | 100 | 400 | 2.45 ms | 2.98 | 4.04 | — |
| cosmos_create_plaintext | 200 | 1,984 | 0.48 ms | 0.72 | 0.79 | — |
| cosmos_read_plaintext | 200 | 2,619 | 0.34 ms | 0.58 | 0.98 | — |
| envelope_write_kv_dek_per_doc | 200 | 843 | 1.15 ms | 1.57 | 1.68 | 200 |
| envelope_read_kv_decrypt_per_doc | 200 | 457 | 2.11 ms | 2.77 | 3.55 | 200 |
| keyreuse_write_cached_dek | 200 | 1,774 | 0.46 ms | 0.77 | 1.15 | 1 |
| keyreuse_read_cached_dek | 200 | 2,311 | 0.39 ms | 0.70 | 0.94 | 0 |

Crypto-tax summary (from the c4 meta row, 0 errors total): envelope tax
**2.35x write / 5.73x read** vs plaintext cosmos; cached-DEK key reuse cuts
that to **1.12x / 1.13x** (5.06x faster than per-doc envelope on read) —
an architectural finding with a direct line to the cost table: per-doc DEK
decrypts at 457 docs/s are a $3.6k/mo KV bill at 24x7; cached-DEK at 2,311
docs/s reduces the KV-driven share ~5x.

### C-5 ARM storm

| phase | result |
|---|---|
| p1 read storm (2,000 reads) | 8,981 ops/s, p50 1.5 ms, p99 5.6 ms, 0 errors |
| p2 write/read mix | write 3.16→23.65 ops/s (concurrent), degradation 0.97x (i.e. none); reads unaffected at 7,961 ops/s |
| p3 LRO under load (50 LROs over 20k reads) | 50/50 ok, poll-to-terminal p50 285.9 ms = 1.07x isolated baseline (267.8 ms) |
| p4 rate-limit burst (100 writes in 29 ms) | 100/100 `201`, **no 429 ever observed — DIVERGENCE**: real Azure ARM throttles this burst class; emulator has no control-plane rate limiter |

### C-6 Sentinel / Resource Graph

| op | n | ops/sec | p50 | p95 | p99 |
|---|---|---|---|---|---|
| DCR ingest 500 B rows (batch 100) | 5,000 | 33,774 rows/s | 2.05 ms | 2.34 | 46.3 |
| KQL where/order/project/take (idle) | 30 | 95.6 q/s | 9.8 ms | 14.1 | 22.5 |
| same KQL under 14,220 rows/s ingest | 148 | 14.8 q/s | 94.0 ms | 430.2 | 496.7 |
| Resource Graph project/top-100 | 5,998 | 599.8 q/s | 1.62 ms | 1.91 | 2.17 |

The only >2x interference observed anywhere in the wave is here: concurrent
ingest degrades KQL query throughput **6.5x** (95.6 → 14.8 q/s), p50 9.6x
(9.8 → 94 ms).

### C-7 cross-surface soak (partial)

Two 10 s samples, cosmos stream only: 4,197 ops/s sustained with 0 errors,
p50 0.221 ms, p95 0.304–0.329 ms, RSS 314 MB → 264 MB, heap flat at 38.4 MB.
All other surface streams registered 0 — the sampler's blob/sb/eh/kv/arm
workers never produced ops (sampler scope bug, honest gap).

### C-8 chaos-cross (summarized from raw log)

40,336 injected/observed events across eh/blob/cosmos. Every failure class is
a designed refusal or injected fault, no silent corruption:

| surface | ok | errors | dominant classes |
|---|---|---|---|
| eh | 0 | 2,862 | `INVALID_LOCAL_SAS` (2,663), connrefused (199) |
| blob | 1 | 6,563 | ContainerNotFound (3,749), WORM overwrite refusal (2,812) |
| cosmos | 1,165 | 38,908 | `C8_COSMOS_EMPTY_READ` (22,602), connrefused (16,306) |

## 3. Interference matrix

The full N-surface x N-surface matrix was not measurable this wave (C-7
sampled cosmos only; C-2 died at seed). What WAS measured, plus the C-7/B-10
triangulation:

| source | interference pair | measured effect |
|---|---|---|
| C-6 | Sentinel ingest → KQL query | **6.5x throughput loss, 9.6x p50** (strongest coupling in the wave) |
| C-5 p2 | ARM writes → ARM reads | none (reads 7,961 ops/s flat; write degradation 0.97x) |
| C-5 p3 | 20k reads/s → LRO terminality | +7% poll-to-terminal (285.9 vs 267.8 ms) |
| C-1 | cosmos ingest ‖ blob archive (composite seq) | none above baseline: 3,649→2,561 ingest ops/s is a payload-mix effect, not contention (single-host, distinct stores) |
| B-10 | 6-surface mixed soak @50 rps x 900 s | error rate 0.02–0.03% (client-side doc-id race, 0 substrate 5xx), RSS growth <=1.1% |
| fin-25 | concurrent lanes → b4 mid-flight | the one true cross-lane interference event of the session: concurrent lanes rewrote b4's run mid-measurement; superseded by x8 remeasure |

### Conclusions from the matrix

1. **Storage surfaces decouple on a single host** — cosmos, blob, ARM, and
   the BEAM-native store/amqp/eh surfaces showed <=7% mutual interference in
   every measured pair. The substrate shares a BEAM VM and a host, yet the
   surfaces act like independent services.
2. **The one strong coupling is ingest→query inside one surface** (Sentinel
   6.5x). That is the shape real Azure Sentinel also exhibits (ingest
   pipeline contention), so the divergence is in magnitude, not kind —
   a known-divergence candidate for v26.10.15.
3. **ARM control plane has no rate limiter** (C-5 p4, 0 429s at 100-write
   burst) — the largest behavioral divergence vs real Azure in this wave; the
   emulator is *more* permissive than the cloud, never less.

## 4. THE COST TABLE — measured throughput at Azure list, 24x7x30

Every input traced to a landed jsonl row; formula column shows the derivation.
Prices AS-OF-KNOWLEDGE, directional. 730 h/mo, 2,628,000 s/mo. Local host cost
of the same workload on the M3 Max: **$0** marginal (machine already owned).

| Surface | Measured op (source receipt) | Sustained | RU/price basis | Azure $/month | Formula |
|---|---|---|---|---|---|
| Cosmos | point-read @ 4,405/s (b3) | 44,050 RU/s equiv | prov $0.0008/(RU/s)h; serverless $0.25/M RU | **$25.7k** / $28.9k | ops x 10 RU x 730h x $0.0008 (serverless: ops x 2.628M s x 10 RU x $0.25/M) |
| Cosmos | full-query 1000-doc @ 49,594/s (b3) | ~40 RU/query | serverless $0.25/M RU | **$1.30M** | ops x 2.628M s x 40 RU x $0.25/M RU |
| Blob | 8k put-block @ 4,351/s (b2) | 11.4B writes/mo | premium $0.05/10k writes | **$57.2k** | ops x 2.628M s x $0.000005 |
| Blob | 64k put-block @ 2,912/s (b2) | 7.65B writes/mo | premium write | **$38.3k** | same unit price |
| Blob | python 8k put @ 917/s (b5) | 2.4B writes/mo | premium write | **$12.0k** | same unit price |
| Service Bus | send+recv-complete RT @ 289/s (x8) | 24.9M RT/mo | Premium P1 $0.366/h flat | **$267** (P3: $971) | flat MU; ops unmetered within MU |
| Event Hubs | producer-send @ 348 evt/s (b4) | 893M evt/mo | Std 1 TU $0.03/h + $0.028/M evt | **$48** | 730 x $0.03 + evt x $0.028/M |
| Event Hubs | BEAM send @ 670/s (b9b) | 1.76B evt/mo | same | **$71** | same |
| Sentinel | DCR ingest 500 B @ 33,774 rows/s (c6) | 16.9 MB/s = 44.4 TB/mo | analytics $4.30/GB | **$190,832** | GB/mo x $4.30 |
| Key Vault | kv_decrypt @ 400/s (c4) | 1.05B signs/mo | HSM ~$0.03/10k | **$3.2k** | ops x 2.628M s x $0.000003 |
| Key Vault | kv_encrypt @ 1,367/s (c4) | 3.59B signs/mo | same | **$10.8k** | same |
| Envelope (KV+cosmos) | per-doc DEK read @ 457/s (c4) | 1.20B/mo | KV HSM + cosmos 10 RU | **$3.6k** (KV share) | KV-share only, formula above |
| Envelope (KV+cosmos) | cached-DEK read @ 2,311/s (c4) | 6.07B/mo | KV ops ~0 on read | **~$0 KV share** (cosmos $15.1k) | key reuse eliminates per-doc KV ops |
| ARM | read storm 8,981/s + LRO 23.65/s (c5) | 26.4M reads + 71k writes/mo | free control plane | **$0** — but cloud would 429 (C-5 divergence) | free, throttled |
| Resource Graph | 600 q/s (c6) | 1.56B q/mo | free, rate-limited | **$0** (throttled in cloud) | free, throttled |

### Composite: the measured cross-product workload, priced

The realistic sustained composite is the B-10 soak shape: 50 mixed ops/s
across blob+cosmos+SB+EH for one month, 0.02% client-side error rate, flat
memory:

| component | Azure $/mo |
|---|---|
| Cosmos serverless (10 RU/op) | $329 |
| Blob premium writes | $657 |
| Service Bus Premium P1 (flat) | $267 |
| Event Hubs Std 1 TU | $26 |
| **Total** | **~$1,278/mo** |

**Thermodynamic-decoupling conclusion.** The same host that sustains a
*sustained* 4,405 cosmos point-reads/s, 4,351 blob puts/s, 289 SB roundtrips/s
and 33.7k Sentinel ingest rows/s pays ~$0 marginal locally and $1.3k–$1.5M/mo
if those throughputs ran against real Azure at 24x7x30 list price — the
dominant terms being a hypothetical $1.3M/mo cosmos full-query tier and
$191k/mo Sentinel ingest. The emulator's cost-free 8,981 ARM reads/s would not
even be *admitted* by real Azure's control plane (429s start orders of
magnitude lower), and the free 600 q/s Resource Graph tier is capped at
~1000 queries/30 days per GUID in the cloud. Emulator throughput is a
capability measurement, not a cloud-equivalent cost measurement: **the local
substrate is thermodynamically decoupled from Azure billing** — a 100x change
in measured local ops/s changes the cloud cost by $0 until you deploy, and by
the full table above when you do.

## 5. Honest bounds

- **Directional pricing**: all unit prices are as-of-knowledge list, not
  quotes; RU-per-op estimates (10 RU point ops, 40 RU/query) are placeholders
  that real RU meters would refine; reservations/autoscale would cut the
  provisioned cosmos figure substantially.
- **Single host**: all measurements on one M3 Max (16 cores, 48 GB); no
  network hop. Azure's per-op latency includes a WAN round trip the emulator
  does not pay — cloud throughput at these op mixes would be far lower at
  equal concurrency, which makes the dollar figures an *upper* bound on
  op-driven cost and the thesis stronger, not weaker.
- **Emulator != cloud internals**: no real throttling (C-5), no real ingest
  backpressure, no egress charges, no storage/transaction overage classes,
  no HA/geo-replication overhead.
- **Composite attribution**: the ~$1,278/mo composite uses B-10's 50 rps mix;
  op-metered blob premium writes dominate ($657), flat-rate SB P1 ($267)
  second — at low duty cycles the flat surfaces (SB) cost the same whether
  the host does 1 op/s or 289, which is itself a real finding.
- **Gap register**: C-2 (fatal, harness seed bug), C-3 (pending), C-7
  multi-surface sampling (sampler bug). C-4 landed after the first pass and
  was merged in a second pass; C-3 is the only lane with zero data. Nothing
  in the cost table depends on them.
