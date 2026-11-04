# Worksheet 05 — MGPP Worksheet (python3-derived)

MGPP = Market, Growth, Profit, Position — the four business-case legs every
gate review must re-price. This worksheet carries the CPPC program's MGPP with
each number's derivation command or source pin. Derived here, cited elsewhere:
**$13.30/unit gap**, **$28.50 ceiling**, volume from the program plan.

## CPPC MGPP (filled)

| Leg | Metric | Baseline | Target | Value of closing | Source / derivation |
|---|---|---|---|---|---|
| Market | on-time delivery to drone-program customer | 0/40 sampled orders <= 7 d (Module 02 CSV) | >= 95% orders <= 7 d (W15) | retains the SR-71 sole-source slot | `data/../../02-define-overview/data/order-lead-time.csv` |
| Growth | new-program capacity (gimbal line throughput) | line not qualified (Cpk 0.72) | qualified line, Cpk >= 1.33 sustained 30 d (W21) | unlocks the 3-year gimbal frame order | RUNNING-CASE.md pinned pair |
| Profit | unit cost | $41.80 | <= $28.50 | **$13.30/unit** x planned volume | $30.00 x (1 - 5% ROS) = $28.50; gap decomposed in Module 06 worksheet 03 |
| Position | escape rate / brand (aerospace supplier scorecard) | USL tail binds (2.16 sigma, Module 03 key ans. 3) | supplier scorecard >= 95, zero escapes at W26 | defends existing airframe contracts | RUNNING-CASE.md + Module 09 tail arithmetic |

## Program-level value (the only arithmetic this worksheet derives)

`profit_leg = gap_per_unit * planned_volume`. With the course-planned volume
V = 10,000 units/yr (stated in the program plan, not derived): 
$13.30 x 10,000 = **$133,000/yr** profit leg at target; every month of slip
defers $11,083.

## Blanked worksheet (student copy)

| Leg | Metric | Baseline | Target | Value of closing | Source |
|---|---|---|---|---|---|
| Market | | | | | |
| Growth | | | | | |
| Profit | | | | | |
| Position | | | | | |

Rules: (1) every cell carries a number or UNVERIFIED + action row; (2) the
profit leg is the only leg allowed to multiply (per-unit x volume), and both
factors must be sourced; (3) gate W5 re-prices all four legs — an MGPP that
never moves is narration.
