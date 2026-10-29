# COST-3 receipt — egress displacement quantification

**Standing:** PARTIAL_ALIVE · Lane: COST-3 (research/value) · Date: 2026-10-21 · Region: eastus · Currency: USD
Notes: standing was COMPUTED-FROM-PUBLISHED-RATES — a provenance note, not a standing. Rate-card fetch and meter curation are witnessed real fetches; dollar projections are computed from published Azure rates plus measured rehearsal volumes; the 500 GB fleet legs are labeled SCENARIO assumptions, not repo measurements.
Closes the largest UNKNOWN from `docs/jira/v26.10.20/receipts/scvd-value-discovery.md` (claim 2 / honest-boundary note: "egress displacement is the largest unpriced upside and is UNKNOWN").

## 1. Egress rate-card fetch (COST-1 pattern, extended)

- Source: Azure Retail Prices API (`https://prices.azure.com/api/retail/prices`), public, no auth, real fetch run 2026-10-21.
- Filter: `serviceName eq 'Bandwidth' and armRegionName eq 'eastus' and contains(meterName, 'Data Transfer Out')` — 13 raw records.
- Curated meter: **`Bandwidth - Routing Preference: Internet` / `Standard Data Transfer Out`**, meterId `6bd64e8e-5cb9-49d3-893d-800c9b28dca3`, unit 1 GB, Consumption type. All 13 raw records retained in the card's `items`.
- Excluded families (kept in raw, excluded from curated tiers): `Rtn Preference: MGN` (incl. `- to China`, $0 rows — a different routing-preference product), `Standard Inter-Availability Zone Data Transfer Out` ($0.01/GB, inter-AZ only).
- Artifact: `popcorn_demo/azurite-spike/rate-card-egress.json` (`_meta.fetched_at` 2026-10-21, `raw_count` 13, curated `tiers` + one `derived` row). Same pattern as `fetch_rate_card.py` (paginate, curate by exact-match fields, `fetched_at`, raw + curated in one JSON); rerun with the same inline query to refresh.
- API quirk: `tierMaximumUnits` is null in the API response; tier upper bounds are the next tier's `tierMinimumUnits`.

## 2. Fetched standard Data Transfer Out tiers (eastus, USD/GB)

| Tier (GB/month) | Marginal $/GB | Source |
|---|---|---|
| 0 – 100 | $0.00 | fetched meterId 6bd64e8e tierMinimumUnits 0 |
| 100 – 10,100 | $0.08 | fetched tierMinimumUnits 100 |
| 10,100 – 50,100 | $0.065 | fetched tierMinimumUnits 10,100 |
| 50,100 – 150,100 | $0.06 | fetched tierMinimumUnits 50,100 |
| 150,100+ | $0.04 | fetched tierMinimumUnits 150,100 |

## 3. Measured rehearsal data volume (honest basis)

- The only measured byte volume in the repo's rehearsal artifacts is `displacement.jsonl` row `apex2-intake-500`: **blob_gb 0.004292 GB (~4.3 MB, 2,000 blob writes)**, total_usd $0.0133. No other bench JSONL (`tmp/bench/scvd-blob.jsonl`, `scvd-tier2/3.jsonl`, `c10-affidavit-seal.jsonl`, `apex_trade.jsonl`) carries byte-volume fields — they record ops, latency, and error counts only. The azurite `__blobstorage__` directory holds ~4 KB on disk.
- **The measured volume is tiny (~4.3 MB) and falls entirely in the $0 first-100-GB tier — measured egress displacement is $0.00.** Stated plainly, not rounded up.
- **SCENARIO (not a measurement): 500 GB pre-cutover rehearsal** — a realistic enterprise full-fidelity rehearsal volume. At the fetched tiers: first 100 GB free, 400 GB × $0.08 = **$32.00 per rehearsal run** (marginal $0.08/GB). Weekly rehearsal cadence (52 runs/yr) ≈ **$1,664/yr per team/environment**. This is a labeled scenario derived from published rates, not a repo measurement.

## 4. Ranked marginal $/GB table (all COMPUTED-FROM-PUBLISHED-RATES)

| Rank | Displacement channel | $/GB basis | Per 500 GB rehearsal | Per year (weekly cadence, scenario) |
|---|---|---|---|---|
|---|---|---|---|---|
| 1 | Internet egress avoided (100 GB–10.2 TB tier, the tier any 0.5–10 TB rehearsal lands in) | $0.08/GB (fetched) | $32.00 | ~$1,664/team-yr |
| 2 | Internet egress avoided (10.1–50 TB tier) | $0.065/GB (fetched) | n/a (≥10 TB runs) | $65/TB; ~$32.5K per 500 TB-yr equivalent |
| 3 | Internet egress avoided (50–150 TB tier) | $0.06/GB (fetched) | n/a | $60/TB; ~$300K per 5 PB-yr equivalent |
| 4 | Internet egress avoided (150 TB+ tier) | $0.04/GB (fetched) | n/a | $40/TB marginal at hyperscale |
| — | Measured rehearsal volume (4.3 MB) | first-100-GB free tier | **$0.00 measured** | $0 — the free tier fully covers measured runs |

The ranked order is flat by construction: every channel above 100 GB is the same meter at a declining marginal rate; the only structural break is the free first 100 GB.

## 5. Revised claim-2 row (replaces the row in scvd-value-discovery.md)

| # | Claim | Evidence pointer | Rate-card basis | Estimate |
|---|---|---|---|---|
| 2 | **Migration rehearsal without egress**: full pre-cutover rehearsal (31-leg witness walk + 2,500-op blob intake + 1,024-op CAS) runs entirely local, displacing both the Azure data-plane bill and the internet-egress line — rehearsal becomes free and repeatable, not a scoped one-shot | `displacement.jsonl` rows `witness-all-31-legs` ($5.84) + `apex2-intake-500` ($0.0133, blob_gb 0.004292); ledger methodology (APEX-2 500/500 byte-equal GETs, zero egress violations); ~37 ARM control-plane ops priced $0.00; `scvd-blob.jsonl` putget-c128 512 ops 0 errors on `https://127.0.0.1:9444` | Cosmos floor $5.84 + Hot LRS Read $0.005/10K + Write $0.065/10K + Stored $0.021/GB-mo (COST-1 card) **+ Data Transfer Out internet tiers: $0 (0–100 GB), $0.08, $0.065, $0.06, $0.04/GB (rate-card-egress.json, fetched 2026-10-21)** | **~$5.85/mo per reserved rehearsal environment; $0.0133 per measured 500-submission run; measured egress displacement $0.00 (4.3 MB is inside the free 100 GB tier).** SCENARIO (labeled, not measured): a 500 GB rehearsal run displaces **$32.00 of internet egress at list**; weekly cadence ≈ **$1,664/yr per team** — the largest single upside after the Cosmos floor, and the only claim row that scales linearly with data volume. |

## 6. Honest boundaries

- Measured volume (~4.3 MB) is 5 orders of magnitude below the 500 GB scenario; the $1,664/yr figure is a scenario, not a ledger row.
- Marginal-tier arithmetic ignores intra-month tier aggregation nuance (tiers are monthly cumulative); a single big run and 52 weekly runs land in the same tier for the $32/week figure.
- EA/reservation discounts not applied (list prices, per COST-2 methodology).
- Same-region target assumed (task framing): cross-region/inter-AZ egress ($0.01/GB inter-AZ meter, present in raw records) is a separate channel not quantified here.
- Rtn Preference: MGN rows include $0.00 "Data Transfer Out" records — excluded because they price a different routing-preference product, not because egress is free.

---

## Exit-captured replay verification (2026-10-22, lane BK-SUSP3)

The claims above still anchor: every cited artifact is on disk and the tier
arithmetic reproduces exactly from the fetched cards (fetched_at values
unchanged from the receipt's pin — 2026-10-21T17:24:58Z / 17:53:38Z). Typed
as claims-still-anchor, NOT RETIRED-successor.

```
$ python3 replay (artifact existence) -> OK rate-card.json, rate-card-egress.json,
  displacement.jsonl, cost5-sb-measured.jsonl, cost5-sb-price.jsonl, cost5_sb_price.mjs; exit=0
$ python3 replay (arithmetic vs fetched cards) ->
  cosmos floor = $0.008 × 730 = $5.84000 (receipt: $5.84)
  sb floor     = $0.013441 × 730 = $9.81193 (receipt: $9.81193)
  500 GB egress scenario = (500−100) GB × $0.08 = $32.00 (receipt: $32.00)
  REPLAY PASS; exit=0
```
