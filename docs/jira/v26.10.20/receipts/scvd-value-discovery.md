# SCVD value discovery — Fortune-5 80/20 displacement claims

**Standing:** PARTIAL_ALIVE (per-claim caveats below)
Notes: standing was COMPUTED-FROM-PUBLISHED-RATES — a provenance note, not a standing. Rates come from fetched rate cards and measured displacement workloads; assumption legs (fleet size, volumes) are labeled as such.
Context: full · Lane: SCVD-T10 (research/value) · Date: 2026-10-21 · Region: eastus · Currency: USD

## Sources

- `popcorn_demo/bench/displacement-ledger.md` + `popcorn_demo/bench/displacement.jsonl` (COST-2, 3 measured workloads, meters cited per line)
- `popcorn_demo/azurite-spike/rate-card.json` (COST-1; Azure Retail Prices API, eastus, fetched 2026-10-21T17:24:58Z, 10 meters)
- `popcorn_demo/lib/popcorn_demo/azure_cost.ex` — `PopcornDemo.AzureCost.price/3` / `displacement/2`; all pricing flows through fetched meters, no hardcoded prices
- `tmp/bench/scvd-tier1.jsonl`, `scvd-tier2.jsonl`, `scvd-tier3.jsonl` (plus `scvd-blob.jsonl`, `scvd-chaos-conn.jsonl` for context)

## Ranked table (top-3 by dollar)

| # | Claim | Evidence pointer | Rate-card basis | Estimate |
|---|---|---|---|---|
| 1 | **Provisioned-floor Cosmos displacement**: an enterprise Cosmos dev/test account at the 100 RU/s minimum carries a $5.84/730-hr-month list-price floor ($70/yr) regardless of workload — the emulator serves any of these profiles at $0 local compute | `displacement.jsonl` rows `apex4-cas-1024` ($5.84128) and `witness-all-31-legs` ($5.840037); `displacement-ledger.md` "provisioned-throughput floor" finding; tier2 `putget-c128 n=1024` PASS (456 ms wall, 0 errors, 2,245 ops/s) proves parity at n=1024 | Cosmos "100 RU/s" meter $0.008/hr x 730 = $5.84/mo (`rate-card.json` cosmos family, eastus) | **~$5.84/mo per dev/test Cosmos account = ~$70/account-yr at list.** A Fortune-5 with N dev/test accounts displaces ~$70 x N/yr; e.g. 100 accounts ≈ **$7K/yr**, 1,000 accounts ≈ **$70K/yr**. Account-count multiplier is an assumption — no measured fleet size in repo. |
> UPDATED 2026-10-21: claim-2 row and the egress boundary note below replaced per
> `docs/jira/v26.10.20/receipts/cost3-egress-quantification.md` (COST-3) — the egress
> meter was fetched (`popcorn_demo/azurite-spike/rate-card-egress.json`, eastus,
> fetched 2026-10-21, meterId `6bd64e8e-5cb9-49d3-893d-800c9b28dca3`) and the measured
> rehearsal volume quantified. Prior "UNQUANTIFIED: UNKNOWN" language retained in git
> history; not rewritten here.

| 2 | **Migration rehearsal without egress**: full pre-cutover rehearsal (31-leg witness walk + 2,500-op blob intake + 1,024-op CAS) runs entirely local, displacing both the Azure data-plane bill and the internet-egress line — rehearsal becomes free and repeatable, not a scoped one-shot | `displacement.jsonl` rows `witness-all-31-legs` ($5.84) + `apex2-intake-500` ($0.0133, blob_gb 0.004292); ledger methodology (APEX-2 500/500 byte-equal GETs, zero egress violations); ~37 ARM control-plane ops priced $0.00; `scvd-blob.jsonl` putget-c128 512 ops 0 errors on `https://127.0.0.1:9444` | Cosmos floor $5.84 + Hot LRS Read $0.005/10K + Write $0.065/10K + Stored $0.021/GB-mo (COST-1 card) **+ Data Transfer Out internet tiers: $0 (0–100 GB), $0.08, $0.065, $0.06, $0.04/GB (rate-card-egress.json, fetched 2026-10-21)** | **~$5.85/mo per reserved rehearsal environment; $0.0133 per measured 500-submission run; measured egress displacement $0.00 (4.3 MB is inside the free first-100-GB tier).** SCENARIO (labeled, not measured): a 500 GB rehearsal run displaces **$32.00 of internet egress at list**; weekly cadence (52 runs/yr) ≈ **$1,664/yr per team/environment** — the largest single upside after the Cosmos floor, and the only claim row that scales linearly with data volume. |
| 3 | **Load-test displacement**: capacity-discovery load runs (tier3 ramps to n=16,384, 40K+ ops per run, 0 errors to L4096) hit local storage at $0 instead of provisioned Cosmos that must be scaled up for the load window and scaled back down | `tmp/bench/scvd-tier3.jsonl`: ramp-512 n=4096 @1,614 ops/s, ramp-1024 n=8192 @1,254 ops/s, ramp-2048 n=16,384 @975 ops/s, ramp-4096 n=16,384 @834 ops/s (all errors:0, wall "unreached"); ramp-8192 hits the wall at L8192 (534 errors, p50 11.6 s) — the honest capacity ceiling; tier1: 16-leg put/get wall 63–66 ms, 2,540 ops/s, p99 ≤18 ms | Cosmos burst $0.25/1M RUs (fetched); a load window at, say, 10K RU/s for 4 h = 144M RUs ≈ $36/run burst-equivalent (derived from the card, not a measured row) | **~$36/burst-equivalent per 10K-RU/s 4-h load window** (derived); over a year of weekly load tests ≈ **$1.9K/yr per team**. Burstable-RU equivalence is an assumption — the card's provisioned floor dominates list-price billing, so the number is an upper-bound style derivation, not a ledger row. Below L8192 the emulator matched load with 0 errors; at/above L8192 the claim does not hold. |

## Honest-boundary notes (no UNSUPPORTED)

- Blob displacement is real but tiny: APEX-2's full 2,500-op profile = **$0.0133/mo** at list rates. The honest executive claim is "$0 local vs the Azure floor," not "big blob savings."
- **Dev/test PaaS spend elimination "at parity" is parity-qualified**: tier2 PASS at n=1024 (456 ms, 0 errors) but the c128 runs with 512 errors:512 stand FAIL; tier3 hits a typed wall at L8192. Parity holds to the measured envelope (≤1024-op bursts, ≤L4096 ramps); beyond it, the claim must be scoped down, not eliminated.
> UPDATED 2026-10-21: egress boundary note superseded by COST-3
> (`cost3-egress-quantification.md`) — see the UPDATED block above the claim-2 row.
- **Egress displacement (CLOSED by COST-3, 2026-10-21)**: no longer UNKNOWN. Measured
  egress displacement is **$0.00** — the only measured rehearsal volume is
  `apex2-intake-500` at 0.004292 GB (~4.3 MB), entirely inside the free first-100-GB
  tier of the fetched Data Transfer Out internet meter (`rate-card-egress.json`;
  tiers $0/0.08/0.065/0.06/0.04 per GB). Remaining boundaries: the 500 GB → $32.00/run
  and $1,664/team-yr figures are a labeled SCENARIO from published rates, not a
  measured row; tiers are monthly-cumulative (intra-month aggregation nuance ignored);
  list prices only; same-region target assumed (inter-AZ/cross-region egress is a
  separate unquantified channel).
- Cosmos serverless / purchase-option pricing is outside the fetched card (ledger names this as the open boundary) — if an enterprise's accounts are serverless, the $5.84 floor claim changes shape and the burst meter ($0.25/1M RUs) becomes the primary basis.
- Enterprise EA/reservation discounts vary; all figures are LIST prices (per COST-2 methodology).
- Chaos caveat: `scvd-chaos-conn.jsonl` shows the TLS endpoint accepted 2,000 connection floods without refusal ("accepted-all") and recovery initially failed on a CA-verification error — the emulator's overload posture is NOT production-equivalent; this bounds claim 1's "at parity" scope.

## Machine/runtime disclosure

- Emulator host: Apple M3 Max, 16 cores, 48 GB (COST-2 machine block; tier1-3 JSONL machine fields).
- Lane runtime: elixir 1.20.3-otp-28, `MIX_BUILD_ROOT=_build-cost2` (per ledger).
- Rate card: `popcorn_demo/azurite-spike/rate-card.json`, `_meta.fetched_at` 2026-10-21T17:24:58Z, `rate_count` 10, source Azure Retail Prices API eastus USD.
