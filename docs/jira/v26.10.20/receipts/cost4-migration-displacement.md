# COST-4 — smalt-migrate rehearsal displacement model (enterprise replatform)

**Standing:** PARTIAL_ALIVE
Lane: COST-4 (research/value) · Date: 2026-10-21 · Region: eastus · Currency: USD · All figures LIST
Notes: standing was COMPUTED-FROM-PUBLISHED-RATES — a provenance note, not a standing. Every rate is cited to a fetched meter (witnessed); the fleet mix and volumes are labeled SCENARIO assumptions, not repo measurements.

## Sources (all fetched, all cited per line)

- `popcorn_demo/azurite-spike/rate-card.json` — Azure Retail Prices API, eastus, fetched 2026-10-21T17:24:58Z (`_meta.fetched_at`), families: cosmos, storage, servicebus, keyvault, eventhubs.
- `popcorn_demo/azurite-spike/rate-card-egress.json` — eastus, fetched 2026-10-21T17:53:38Z, curated meter `6bd64e8e-5cb9-49d3-893d-800c9b28dca3` (Bandwidth / Standard Data Transfer Out, Routing Preference: Internet); tiers $0 (first 100 GB), $0.08, $0.065, $0.06, $0.04 per GB, monthly-cumulative.
- `popcorn_demo/bench/displacement.jsonl` + `popcorn_demo/bench/displacement-ledger.md` (COST-2; three measured workloads).
- `docs/jira/v26.10.20/receipts/scvd-value-discovery.md` (T10 value discovery, claims 1-3).
- `smalt-cli/README.md` — smalt-migrate PRD Module 1; NFR-2 budget ≤30 s for 50 resources, tested on a generated 50-resource fixture.

## 1. Per-resource-month dev/test floor (each row COMPUTED from a cited fetched meter)

| resource type | meter cited (rate-card.json family / meterId) | rate | monthly math | floor $/resource-mo | basis |
|---|---|---|---|---|---|
| Cosmos DB dev/test account (100 RU/s provisioned minimum) | cosmos, `100 RU/s` sku RUs, `65d4ded2-41ae-43a8-bb68-3c200e1ba864` | $0.008/hr | ×730 h | **$5.84** | MEASURED floor — displacement.jsonl `apex4-cas-1024` ($5.84128 incl. $0.00128 burst) and `witness-all-31-legs` ($5.840037) both land on it |
| Service Bus Standard base unit | servicebus, `Standard Base Unit` sku Standard, `9d0c5c5c-f0ff-48c2-8c68-9ee7ffd306af` | $0.013441/hr | ×730 h = $9.81193 | **$9.81** | SCENARIO (no priced SB workload in displacement.jsonl; rate from fetched card). Cross-check: the same card lists a literal $10/1/Month Standard Base Unit meter (`d5034e45-00c1-48c6-8c00-c866f788e033`), $0.19 apart — consistent. $9.83 under a 731-h month; this receipt uses 730 h. |
| Key Vault Standard | keyvault, `Operations` sku Standard, `0f824807-2376-435c-95c9-f992b67a07b0` | $0.03/10K ops | $0 base + ops | **$0.00 base** | MEASURED that ops are negligible: `witness-all-31-legs` priced 5 KV ops at $0.000015/run; base floor $0 is computed from the card (KV bills no hourly meter at Standard tier) |
| Blob Storage Hot LRS | storage, `Hot LRS Data Stored` $0.021/GB-mo; `Hot LRS Read Operations` $0.005/10K; `Hot LRS Write Operations` $0.065/10K | $0.021/GB-mo | 10 GB scenario → $0.21 | **$0.00 base + $0.021/GB-mo** | MEASURED op rates (apex2-intake-500: 2,500 ops + 0.004292 GB-mo = $0.0133 total); the 10 GB volume is the SCENARIO dial |
| ARM control plane | n/a — no meter | $0.00 | — | **$0.00** | MEASURED — ledger records ~37 control-plane ops at $0.00 |

## 2. Scenario fleet: 50 resources (the NFR-2 fixture scale)

The fleet MIX IS AN ASSUMPTION — no measured fleet composition exists anywhere in the repo, so it is labeled SCENARIO: 25 Cosmos dev/test accounts + 10 SB Standard namespaces + 10 storage accounts (10 GB each) + 5 KV vaults = 50 resources.

| line | count | $/unit-mo | monthly | basis |
|---|---|---|---|---|
| Cosmos 100 RU/s floor | 25 | $5.840 | $146.03 | rate MEASURED floor; count SCENARIO |
| SB Standard base | 10 | $9.81193 | $98.12 | rate COMPUTED from card (730 h); count SCENARIO |
| Blob stored, 10 GB-mo | 10 | $0.21 | $2.10 | rate MEASURED meter; volume SCENARIO |
| KV base floor | 5 | $0.00 | $0.00 | both |
| **Monthly displacement at list** | | | **$246.25** | |
| **Annual displacement at list** | | | **$2,955.01** | |

Every rate above is COMPUTED-FROM-PUBLISHED-RATES; fleet composition and blob volume are SCENARIO; the Cosmos anchor is corroborated by two measured ledger rows.

## 3. Migration-rehearsal egress displacement (ties COST-3 into the fleet model)

| line | value | basis |
|---|---|---|
| Measured per-run egress displacement | **$0.00** — apex2-intake-500 displaced 0.004292 GB, entirely inside the free first-100-GB tier of meter `6bd64e8e` | MEASURED |
| Measured per-run total displacement (all meters) | **$0.0133** (apex2-intake-500: reads $0.00025 + writes $0.013 + capacity $0.00009) | MEASURED |
| 500 GB rehearsal run | **$32.00** (= 100 GB free + 400 GB × $0.08; rate-card-egress.json `derived.rehearsal_500gb_usd`) | SCENARIO |
| Weekly 500 GB cadence, per team | **$1,664/yr** (52 × $32) | SCENARIO |

This egress line is per-team/per-rehearsal-run and is NOT additive to the Section 2 fleet line unless a cadence and a data-volume-per-run are both assumed.

## 4. The chain, stated plainly

At list prices the bill is dominated by floors, not usage: a Cosmos dev/test account bills $5.84/mo for 16 ops or 1,024 writes alike (MEASURED — both ledger rows land on $5.84), an SB Standard namespace bills $9.81/mo at zero messages (COMPUTED from the card's $0.013441/hr meter, cross-checked against the card's own $10/mo meter), and KV/blob carry no base floor at all. The honest chain is therefore floors × fleet size; usage-based lines (burst RUs, egress, KV ops, blob ops) measure cents. For a 50-resource fleet at the NFR-2 fixture scale with the stated mix, smalt-migrate's loopback-only rehearsal surface displaces **~$246/mo ≈ ~$2,955/yr at list**, scaling linearly in fleet size at ~$5.84 per Cosmos account and ~$9.81 per SB namespace per month.

## 5. What remains UNKNOWN — and the measurement that would close each

| # | UNKNOWN | Why it is unknown | Exact measurement that closes it |
|---|---|---|---|
| U1 | Fleet composition for a real enterprise replatform (how many Cosmos / SB / storage / KV resources per 50, or in total) | No inventory exists in the repo; the 25/10/10/5 mix is a stand-in | Run `smalt-cli migrate scan` against a real Terraform/Bicep estate and count `azurerm_*` blocks by type; the scan output IS the fleet table and plugs straight into Section 2 |
| U2 | Whether target accounts are provisioned or serverless Cosmos | The fetched card's serverless meter ($0.25/1M RUs) exists, but no workload priced serverless; the $5.84 floor does not apply to serverless accounts | Re-price the displacement ledger with `PopcornDemo.AzureCost.price/3` against the `1M RUs` meter (`f7aeda1d-30d1-5681-b35a-e2f35760a007`) using measured RU consumption from one real account's metrics export |
| U3 | SB Standard message-volume displacement | No priced SB workload exists; only the base floor is quantified | Run one SB emulator rehearsal workload (e.g. the AMQP legs) with op counts captured, price via `Standard Messaging Operations` ($0-0.8/1M tiered) through the same price/3 path |
| U4 | Actual egress GB per rehearsal run at enterprise data volume | The only measured run moved 4.3 MB; the 500 GB/$32 line is a scenario | Instrument one full-scale rehearsal (blob intake at production dataset size) and read total bytes served off the loopback endpoint — one number, plugs into the tier table |
| U5 | EA/reservation/private-rate discounts | All figures are LIST per COST-2 methodology; no enterprise agreement data in repo | Obtain the customer's rate sheet (or amortized invoice line items) and re-run the same table; the model is rates-in/rates-out |
| U6 | Whether parity holds at enterprise workload scale (bounds "at parity" elimination claims) | Measured envelope is ≤1,024-op bursts and ramps to L4096; typed wall at L8192; chaos posture not production-equivalent | A tier-3-style ramp against a production-shaped fixture until the typed wall moves; the wall location is the parity boundary |

## Boundary notes (carried, not papered over)

- List prices only; EA/reservations vary (U5).
- Egress tiers are monthly-cumulative; intra-month aggregation nuance ignored (per COST-3).
- Same-region target assumed; inter-AZ / cross-region egress is a separate unquantified channel.
- Cosmos serverless purchase option outside the floor claim (U2).
- App Config ops have no meter in the fetched card — excluded and named (per COST-2 ledger).

## 6. UPDATED (COST-5, 2026-10-21) — UNKNOWN#3 closed: SB workload measured and priced

One real AMQP workload against the live substrate (T12 shape: 128 workers × 4 send/receive
cycles, per-worker queues, real `@azure/service-bus` SDK over 5672): **1,024 ops** (512 sends +
512 receives), **1,048,576 payload bytes** (2,048 B/msg), wall 515 ms, 1,988 ops/s, **0 errors**.
Raw row: `tmp/bench/cost5-sb-measured.jsonl`; harness `tmp/bench/cost5_sb_price.mjs`; priced
receipt `tmp/bench/cost5-sb-price.jsonl`.

Priced through `PopcornDemo.AzureCost.price/3` with `%{sb_ops: 1024}`, hours 730, against
`popcorn_demo/azurite-spike/rate-card.json` (fetched 2026-10-21T17:24:58Z):

| line | meter | rate | qty | $/mo |
|---|---|---|---|---|
| sb_base_unit | Standard Base Unit | $0.013441/hr | 730 | **$9.81193** |
| sb_ops | Standard Messaging Operations | $0.0/1M (first tier) | 0.001024 | **$0.00** |

`price/3` also returns a Premium MU line ($0.9275/hr × 730 = $677.075) — a mutually-exclusive
SKU, not additive to Standard; excluded from the Standard-tier bill (raw `price/3` total
$686.88693, both figures in the jsonl). The measured 1,024-op workload bills $0.00 in messaging
ops — the entire $9.81193/mo is **$0.013441/hr floor attribution**, confirming Section 4's
floors-dominate chain with a measured workload. Standing: **COMPUTED-FROM-PUBLISHED-RATES**.

---

## Exit-captured replay verification (2026-10-22, lane BK-SUSP3)

Section 4's floors-dominate chain and the COST-5 addendum still anchor: the
cited rate cards and measured jsonl artifacts are on disk with unchanged
`_meta.fetched_at` pins, and the per-resource floors + scenario line reproduce
exactly from the card meters. Typed as claims-still-anchor, NOT
RETIRED-successor.

```
$ python3 replay (artifact existence): rate-card.json, rate-card-egress.json,
  displacement.jsonl, cost5-sb-measured.jsonl, cost5-sb-price.jsonl,
  cost5_sb_price.mjs — all present; exit=0
$ python3 replay (meterId-checked arithmetic) ->
  cosmos_provisioned_rus meterId 65d4ded2-… unitPrice 0.008 → $5.84000/mo (receipt: $5.84) MATCH
  sb_standard_base_unit meterId 9d0c5c5c-… unitPrice 0.013441 → $9.81193/mo (receipt: $9.81193) MATCH
  egress tier_minimum_gb=100 → usd_per_gb $0.08 → 500 GB scenario $32.00 (receipt: $32.00) MATCH
  REPLAY PASS; exit=0
```
