# Module 34 Solution Key (all numbers python3-re-derived; see courts/court.py)

## Part 1 — Baseline (from data/gate-review-waits.csv)
- Calendar total = 25+20+30+30+25 = **130 working days** (= 26 weeks x 5; exact check).
- Work = 18+14+22+21+17 = **92 d**; internal wait = 4+3+5+6+5 = **23 d**; gate wait =
  3x5 = **15 d**. Sum: 92+23+15 = 130 exact.
- Flow efficiency = 92/130 = **70.8%**.

## Part 2 — Wait ranking
- Pools descending: Develop internal 6, Explore internal 5, Implement internal 5, Define
  internal 4, gate waits 3 each (x5), Measure internal 3.
- Half of the 23-day internal wait sits in **Develop + Explore** (6+5 = 11 of 23).
- Recomputed with gate wait counted as value-added: FE = 92/(130-15) = **80.0%**. The ranking
  conclusion does NOT change — internal waits still dominate the wait budget (23 vs 15).

## Part 3 — Scenario F
- New internal waits: 2+1+2+3+2 = 10 d; gate wait 1x5 = 5 d.
- New program length = 92+10+5 = **107 d = 21.4 weeks**; saved = 130-107 = **23 working days
  (4.6 weeks)**.
- New flow efficiency = 92/107 = **86.0%**.
- Gate-only sensitivity: 15->5 saves 10 d -> 120 d (24 weeks); FE = 92/120 = **76.7%**.
  Gate cadence alone is 43% of the opportunity; WIP/queue work is the larger half.

## Part 4 — Checklist audit (pinned program)
1. Single-piece gate packages: FAIL (phase-end batch review).
2. Visible dependency queues: FAIL (waits are not instrumented — they are reconstructed
   retrospectively, which is exactly what this CSV is).
3. Decision SLA: FAIL (3-day average gate wait, no named SLA).
4. Bounded rework: PARTIAL (gates exist; re-open scope not defined).
5. Cadence matches decision takt: FAIL (phase-end reviews, not review-when-ready).
6. WIP caps per lane: FAIL (no caps pinned in the program plan).

## Exercise answers
1. Decision takt: baseline 130/5 = **26 working days per decision**; scenario F 107/5 =
   **21.4 d**. A weekly review = 5 d per decision slot — far below either, which is precisely
   why the binding constraint is batch-then-wait, not reviewer capacity. Conclusion: adopt
   review-when-ready (single-piece), not a fixed takt.
2. Serial: 6 x (5+0.5) = **33 d**. WIP-limit model (assumption: two people work in parallel on
   2 of the 3 allowed WIP packages, each package still incurs its own 0.5 d dependency wait,
   waits do not parallelize): content 30 person-days / 2 = 15 d + 6 x 0.5 = **18 d**.
   Risk: "perfect parallelism" ignores skill overlap, shared-review capacity, and integration
   contention — treat 18 d as a floor, not a forecast.
3. Expected Develop duration, first-pass p = 0.7: 30 + 0.3 x (6.3 + 3) = **32.79 d**.
   With 2-day peer review and p = 0.9: (30+2) + 0.1 x 9.3 = **32.93 d** — a WASH, marginally
   WORSE. Breakeven review cost c: 30 + c + 0.93 = 32.79 -> **c <= 1.86 work-days** (or the
   review must push first-pass above ~0.95). Teaching point: process-improvement claims must
   be netted; a "quality practice" can be flow-negative.
4. L = lambda x W = (1/4 per day) x 3 d = **0.75 packages** average in the gate queue.
   Instability threshold (M/M/1): utilization rho = lambda/ mu = lambda x (1 day per decision)
   >= 1, i.e. arrivals faster than **1 package/day** grow the queue without bound; more
   precisely the queue explodes as rho -> 1, so the SLA needs rho <= ~0.7 (arrivals <= ~0.7
   per day) for a 1-day SLA to hold at the 95th percentile.

## Court
`python3 courts/court.py` re-derives: 130/92/23/15 split, FE 70.8%, adjusted FE 80.0%,
scenario F 107 d / 23 d saved / FE 86.0%, gate-only 120 d / FE 76.7%, exercise Little's-Law
value 0.75. Exit 0 = match.
