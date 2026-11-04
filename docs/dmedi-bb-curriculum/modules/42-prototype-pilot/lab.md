# Module 42 Lab — Run the CPPC Pilot Exit Checks

**Data** (all in `modules/42-prototype-pilot/data/`, seed 42016, python3 `random.gauss`):
- `pilot-bore-30day.csv` — 30 days × 8 subgroups × n=5, columns `day,subgroup,obs,bore_mm`
- `pilot-ra-daily.csv` — 30 daily Ra values (`day,ra_um`)
- `pilot-scrap-daily.csv` — 30 days of `day,produced,scrap` at 150 pieces/day
- Generators: `gen_pilot.py`, `gen_scrap.py`

**Spec**: LSL 11.975 / USL 12.025 mm. **Gate**: Cpk ≥ 1.33, LCB ≥ 1.33.
**Planned rate**: 150 pieces/day; 8 subgroups/day (every 2 h over two shifts), n=5.

## Part 1 — Lot-size derivation (do this first, on paper + python3)
1. Write the SE formula: SE(Cpk) = sqrt(1/(9n) + Cpk²/(2(n−1))).
2. With design-predicted Cpk = 1.50, find the smallest n whose 95% LCB reaches 1.33 (z = 1.645).
3. Round up to a multiple of the daily measurement structure (40/day) → pilot lot.
4. Confirm: what is the SE and LCB at n = 1200 (the 30-day run)?

## Part 2 — Capability exit (criterion 1)
Compute from `pilot-bore-30day.csv`:
- mu, s, Cp, Cpk (spec 11.975–12.025), count out of spec.
- SE and 95% LCB on Cpk at n = 1200.

## Part 3 — Stability exit (criterion 2)
Compute per-subgroup means and ranges (240 subgroups):
- X-double-bar, R-bar, limits with A2=0.577, D3=0, D4=2.114 (n=5).
- Count rule-1 violations (point beyond 3-sigma limits) on X-bar and R charts.

## Part 4 — Surface-finish exit (criterion 3)
Compute from `pilot-ra-daily.csv`:
- I-MR limits on daily Ra (E2 multiplier 2.66 for MR of span 2; MR-bar × 3.267 for the MR chart).
- Two-sample t: first 10 vs last 10 daily Ra, pooled sd, t statistic vs critical 2.101 (df=18, alpha=0.05, two-sided).

## Part 5 — Scrap exit (criterion 4)
Compute from `pilot-scrap-daily.csv`:
- Total scrap, rate vs the 0.5% target (target derivation in the solution key).
- Exact binomial decision: exit passes if total scrap X ≤ 14 of n = 4500 (Clopper–Pearson 95% upper bound ≤ 0.5% at X=14; > 0.5% at X=15).

## Part 6 — Write the pilot receipt
Five fields: identity (datasets + seed), authority (week-21 gate), consequence (your numbers), replay (your commands), standing (PASS/FAIL per criterion). Compare against `keys/solution-key.md`.

## Timing (per activity)

| Part | Activity | Time |
|---|---|---|
| 1 | Lot-size derivation | (15 min) |
| 2 | Capability exit (criterion 1) | (20 min) |
| 3 | Stability exit (criterion 2) | (15 min) |
| 4 | Surface-finish exit (criterion 3) | (15 min) |
| 5 | Scrap exit (criterion 4) | (20 min) |
| 6 | Write the pilot receipt | (15 min) |

Total 100 min — consistent with the slides-outline estimate (lab 1.5 h).
