# Lifecycle TCO — the 8-Hop Cost Ledger (LC-2)

Consolidated total-cost-of-ownership view of the 8-hop cloud-chain tax
pipeline measured by LC-1 (`receipts/lc1-8hop-tax-chain.md`,
`bench/lifecycle-8hop.jsonl`). Four layers: measured pipeline latency,
the directive's 1M-cycle Azure invoice, the measured local equivalent,
and the arbitrage ratio with honest bounds.

**Pricing caveat (applies to every dollar figure below)**: all Azure rates
are AS-OF-KNOWLEDGE list prices, directional only — not quotes. Re-verify
on azure.microsoft.com/pricing before any procurement decision. The
structure of the ledger is the deliverable; exact cents are directional.

## 1. The measured 8-hop pipeline (LC-1, N=200 cycles, 0 errors)

Every hop measured on the smalt substrate (loopback), 200 complete
lifecycle cycles (~1,600 API ops), 8 sequential hops per cycle, hop-8
read-your-write verified 200/200. Mapping labels per LC-1.

| Hop | Cloud-Chain | smalt surface (mapping) | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|---|
| 1 | Entra auth | STS `POST /oauth2/v2.0/token` (REAL) | 0.804 | 2.359 | 3.956 |
| 2 | APIM | workspace `next start` `/api/v1/ingest`, token-bucket (NEAREST_ANALOG) | 1.581 | 3.410 | 4.975 |
| 3 | Cosmos CAS | `@azure/cosmos` create + ifMatchEtag replace (REAL) | 1.585 | 4.635 | 7.651 |
| 4 | KV/HSM sign | KV `POST /keys/lc1-tax-key/sign` RS256 (REAL) | 2.151 | 4.133 | 4.749 |
| 5 | EH ingress | `@azure/event-hubs` producer, AMQP (SDK) | 0.565 | 2.038 | 3.568 |
| 6 | Blob journal | block-blob PUT to `compliance-lc1` (PUT-journal) | 0.874 | 2.407 | 3.315 |
| 7 | Search | Resource Graph project over seeded acct (NEAREST_ANALOG) | 0.847 | 2.041 | 3.252 |
| 8 | Sentinel RYW | DCR ingest + KQL read-back, TxId verified (REAL) | 1.640 | 4.175 | 10.315 |

**End-to-end (N=200)**: p50 **11.146 ms**, p95 **23.293 ms**, p99
**31.994 ms**; ~89.7 cycles/s; 200/200 complete; 0 transport or
semantic errors; RYW 200/200.

## 2. The directive's 1M-cycle Azure invoice

The cost directive's published rates, per 1M lifecycle runs (one run =
one full 8-hop cycle). **As-of-knowledge / directional throughout.**

| Hop | Service | Directive rate basis | Azure $/1M cycles |
|---|---|---|---|
| 1 | Entra ID | token issuance | $3.00 |
| 2 | APIM | $2,802.50/mo amortized over 1M cycles | $2,802.50 |
| 3 | Cosmos DB | RU-tier per cycle | $2.00 |
| 4 | Key Vault (HSM) | RSA-2048 sign, $0.03/10k | $18.20 |
| 5 | Event Hubs | $0.028/1M events | $0.40 |
| 6 | Blob Storage | $0.05/10k writes | $8.10 |
| 7 | Cognitive Search | per-query tier | $4,000.00 |
| 8 | Log Analytics | $4.30/GB ingest (~500 B/row) | $6.90 |
| | **Total** | | **~$6,841 / 1M lifecycle runs** |

Structural note: this invoice is **flat/amortized-rate dominated** —
APIM ($2,802.50) + Search ($4,000) are $6,802.50 of the $6,841 (99.5%).
LC-1's op-metered ledger (`bench/lifecycle-8hop.jsonl` row
`cost-ledger-1M`, ~$68.65/1M) meters only per-op tiers and excludes
Cosmos and Search; the two models differ by design. This table is the
directive's invoice shape; LC-1's is the op-metered floor.

## 3. The measured local equivalent (1M cycles on the M3 Max)

**Measured wall-clock basis**: LC-1 ran 200 cycles in ~2.7 s wall
(13.5 ms/cycle actual; p50 11.146 ms/cycle). Extrapolation:

| quantity | value |
|---|---|
| cycles/s (measured, actual wall) | ~74/s (200 / 2.7 s); ~89.7/s at p50 |
| wall-clock for 1M cycles | **3.1–3.75 h** (11,148 s at p50 rate; 13,500 s at actual) |
| machine | Apple M3 Max, 16 cores, 48 GB |

**Amortization assumption (stated explicitly)**: M3 Max purchase price
$3,999, straight-line over 3 years of 24×7 use = $3,999 / 26,280 h =
**$0.152/h**. Power at ~40 W average draw, $0.30/kWh = $0.012/h.

| component | rate | 1M cycles (3.75 h) |
|---|---|---|
| M3 Max amortized capital | $0.152/h | $0.57 |
| Electricity | $0.012/h | $0.045 |
| **Total local** | | **~$0.62 / 1M cycles** |

Marginal local cost is effectively the electricity line — the machine is
already owned and idle capacity is consumed either way. All numbers
single-host, no redundancy, no HA.

## 4. Arbitrage ratio, with honest bounds

| | Azure (directive invoice) | Local (measured) |
|---|---|---|
| 1M lifecycle runs | ~$6,841 | ~$0.62 |

**Headline ratio: ~11,000×** ($6,841 / $0.62). A wider honest span:
op-metered Azure floor $68.65/1M (LC-1's ledger) vs $0.62 local is
~110×; the full directive invoice vs pure-electricity marginal cost
(~$0.045) is ~150,000×. The honest headline sits in the five-figure
band; quote it as "10³–10⁵×, point estimate ~11,000×" unless the
flat-rate APIM/Search tiers are guaranteed, in which case ~11,000×.

**Honest bounds (why the ratio is not exact)**:

- **Loopback ≠ WAN**: local hops pay no network round trip. Real Azure
  per-op latency includes a WAN hop the emulator does not — cloud
  throughput at equal concurrency would be lower, making the op-driven
  Azure share an *upper* bound and the ratio a *lower* bound on that
  axis.
- **Emulator ≠ cloud internals**: no real APIM gateway surface exists in
  smalt (hop 2 is a labeled NEAREST_ANALOG Next handler); no Cognitive
  Search surface (hop 7 is Resource Graph NEAREST_ANALOG); no real ARM
  rate limiting (C-5: zero 429s at a 100-write burst); no egress,
  geo-replication, or HA overhead. The Azure invoice prices the *real*
  services; the local pipeline runs their analogs — the ratio compares
  unlike things deliberately, as a decoupling statement, not a
  like-for-like benchmark.
- **Single-host numbers**: one M3 Max, no redundancy, no durability
  guarantees. A production-equivalent local deployment (replicated
  stores, HA) raises the local cost materially; $0.62 is a floor, not
  an offer.
- **SDK→BEAM performance layer**: the session's measured 238×–6204×
  SDK→BEAM multipliers (per `BENCH_RESULTS.md` and the per-lane
  receipts `receipts/bench-*.md`) are cross-referenced, not restated
  here — they measure the SDK-vs-native-BEAM throughput axis, a
  different axis from this cost ledger.

## 5. Related

- LC-1 measured pipeline: `receipts/lc1-8hop-tax-chain.md`,
  `bench/lifecycle-8hop.jsonl`
- C-9 cross-product cost table (throughput priced at 24×7×30 Azure
  list, the thermodynamic-decoupling table): `CROSS_PRODUCT_RESULTS.md`
  §4 — reference, not duplicated here. Its $0-marginal-local vs
  $1.3k–$1.5M/mo cloud-equivalent conclusion is the sustained-throughput
  complement to this per-lifecycle-run ledger.
- Generated bench report: `BENCH_RESULTS.md`
