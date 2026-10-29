# Displacement ledger — measured workloads priced at published Azure rates

Standing: **COMPUTED-FROM-PUBLISHED-RATES**
Context: full
Lane: COST-2 · Date: 2026-10-21 · Region: eastus · Currency: USD

## Methodology

- Op counts are MEASURED from the witnessed runs (not modeled): APEX-2 from
  `docs/jira/v26.10.20/receipts/apex-2-intake.md` (500/500 submissions, byte-equal
  GETs, zero egress violations); APEX-4 from
  `docs/jira/v26.10.20/receipts/apex-4-ratelimit-falsifier.md` (run 2);
  witness-all from the executed success paths of the leg modules
  (`popcorn_demo/lib/popcorn_demo/live_*.ex`), verb-level counts read off the
  `req(:method, ...)` / `request(%{method: ...})` call sites taken by the OK legs
  of the 2026-10-21T075835Z witness-all receipt.
- Every dollar = measured op count x published retail rate, priced through
  `PopcornDemo.AzureCost.price/3` (COST-1's module) against the FETCHED rate card
  `popcorn_demo/azurite-spike/rate-card.json`
  (Azure Retail Prices API, eastus, fetched 2026-10-21T17:24:58Z; 10 meters). No
  price is hardcoded in this ledger — each line cites meter + retailPrice + unit.
- Local cost: $0 compute. The emulator runs on an owned M3 Max; serving the same
  op profile locally displaces the Azure bill without incurring one.
- Enterprise discounts / reservations / EA pricing vary; these are LIST prices.

## Measured op profiles

| workload | ops profile (measured) |
|---|---|
| apex2-intake-500 | 500 submissions x (3 Put Block + 1 Put Block List + 1 GET blob) = **2,000 blob write tx + 500 blob read tx + 4,500 KiB capacity-month**; policy + flag legs in-memory (0 Azure-billable ops) |
| apex4-cas-1024 | 1,024 granted CAS ops modeled as Cosmos writes at the simulated 100 RU/s bucket; the 1,150 throttled 429 attempts carry no RU charge at list prices |
| witness-all-31-legs | OK-leg executed path: cosmos reads 5 (cas 3, matrix 1, param 1), cosmos writes 11 (cas 5, matrix 3, param 3), KV ops 5, blob write tx 1 (blob leg's 403 create attempt); ~37 ARM control-plane ops (containers/export/lifecycle/rg/rules/tags/live/appconfig) at $0.00 — Azure ARM control plane is free at list prices; App Config ops have no meter in the fetched card (excluded, named here) |

## Displacement table

| workload | ops profile | Azure bill (list, eastus) | local cost |
|---|---|---|---|
| apex2-intake-500 | 2,500 blob tx + 0.0043 GB-mo | **$0.0133** (reads $0.00025 + writes $0.013 + capacity $0.00009) | **$0.00** |
| apex4-cas-1024 | 1,024 Cosmos writes @ 100 RU/s | **$5.8413** (provisioned 100 RU/s-hr x 730 = $5.84 + burst $0.00128) | **$0.00** |
| witness-all-31-legs | 16 Cosmos ops + 1 blob tx + 5 KV ops | **$5.8400** (provisioned floor $5.84 + $0.000037 metered) | **$0.00** |

## Per-line rate citations

- Hot LRS Read Operations: $0.005 / 10K tx
- Hot LRS Write Operations: $0.065 / 10K tx
- Hot LRS Data Stored: $0.021 / GB-month
- Cosmos DB 100 RU/s (provisioned): $0.008 / hour -> $5.84 / 730-hr month
- Cosmos DB burst: $0.25 / 1M RUs
- Key Vault Operations: $0.03 / 10K ops
- (SB Standard base unit $0.013441/hr, SB Premium MU $0.9275/hr, EH Standard TU
  $0.03/hr are in the fetched card; no priced workload drew them.)

## Typed findings

- **The provisioned-throughput floor, not the workload, is the bill.** The 16-op
  witness walk costs the same $5.84/month as the 1,024-write CAS run: at list
  prices the minimum Cosmos reservation at 100 RU/s dominates every metered
  line. Serverless/purchase-option modeling is outside the fetched card — named
  as the open boundary, not papered over.
- APEX-2's 2,500-op blob profile displaces only 1.3 cents/month at list rates —
  the honest claim is displacement of the BILL, not of a large one; the
  executive case rests on $0 local compute against the published-rate floor.
- Throttled 429 attempts (1,150 in APEX-4 run 2) are excluded from billing per
  published RU-metering semantics; including them would not change the floor.
- ARM control-plane equivalence: the 31-leg walk's ~37 ARM ops displace $0.00 of
  Azure bill — listed so the ledger doesn't overclaim.

## Result files

- `popcorn_demo/bench/displacement.jsonl` (3 rows, lane cost2, one per workload;
  each row carries the meter-by-meter pricing string + fetched_at)
- Machine (`just bench-machine`):
  `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
- Lane runtime: elixir 1.20.3-otp-28, `MIX_BUILD_ROOT=_build-cost2` (deleted below).
- Compile-freeze disclosure (SLA): this lane applied a minimal unblock fix to
  COST-1's `popcorn_demo/lib/popcorn_demo/azure_cost/line.ex` — the zero-weight
  clause matched literal integer `0` while `Profile.normalize/1` floats every
  weight (`* 1.0`), so any profile with a zero field crashed
  `price/3` with FunctionClauseError. Fix: zero clause is now
  `def build(_key, w, _rate, _opts) when w == 0 or w == 0.0`. This lane did not
  otherwise touch COST-1's files.
