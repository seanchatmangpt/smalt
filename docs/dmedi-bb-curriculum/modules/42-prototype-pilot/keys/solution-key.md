# Module 42 Solution Key — Pilot Exit Checks (all numbers python3-derived from the seeded CSVs)

**Baseline convention**: per Module 01 / defect CLD-01, the course uses the ADJUDICATED baseline pair (Cpk = 0.72, sigma = 7.407 µm — adjudicated 2026-11-04, see RUNNING-CASE.md). The pilot gate target (Cpk ≥ 1.33, LCB ≥ 1.33) is independent of that defect.

## Part 1 — Pilot lot size derivation

Standard error of Cpk (normal approximation):
SE(Cpk) = sqrt( 1/(9n) + Cpk² / (2(n−1)) ).

Design margin: the Develop-phase DOE settings predict Cpk = 1.50. The gate needs the
one-sided 95% lower confidence bound to clear 1.33, i.e.
1.50 − 1.645 · SE(1.50, n) ≥ 1.33  →  SE ≤ 0.17/1.645 = 0.10334.

Re-derivation (`python3`, exact minimum):

```
n = 2
while 1.5 - 1.645*sqrt(1/(9n) + 1.5**2/(2*(n-1))) < 1.33: n += 1   # → n = 117 (LCB = 1.3303)
```

Minimum measured n = 117. Rounded up to the daily measurement structure
(8 subgroups/day × n=5 = 40 measured pieces/day at the planned 150 pieces/day rate):
**pilot lot = 120 pieces = 3 production days**.
At n = 120: SE = 0.10188, LCB = 1.3324. The 30-day run then delivers n = 1200:
SE = 0.0321, LCB = Ĉpk − 0.0528.

## Part 2 — Capability exit (criterion 1)

From `pilot-bore-30day.csv` (n = 1200, seed 42016):

| quantity | value |
|---|---|
| mu | 12.0049 mm |
| s | 0.00452 mm |
| Cp | 1.846 |
| **Cpk** | **1.481** |
| observations outside 11.975–12.025 | 0 |
| SE at n = 1200 | 0.0317 |
| **95% LCB** | **1.429** |

**Decision**: LCB 1.429 ≥ 1.33 → criterion 1 PASSES.

## Part 3 — Stability exit (criterion 2)

Per-subgroup (240 subgroups, n=5; constants A2 = 0.577, D3 = 0, D4 = 2.114):

| quantity | value |
|---|---|
| X-double-bar | 12.0049 mm |
| R-bar | 0.0102 mm |
| UCL(X-bar) | 12.0108 mm |
| LCL(X-bar) | 11.9990 mm |
| UCL(R) | 0.0216 mm |
| rule-1 violations, X-bar chart | 0 |
| rule-1 violations, R chart | 0 |

**Decision**: process statistically stable → criterion 2 PASSES.

## Part 4 — Surface-finish exit (criterion 3)

From `pilot-ra-daily.csv` (30 daily Ra values, individuals chart, 2.66 = 3/d2 with d2=1.128):

| quantity | value |
|---|---|
| Ra mean | 0.807 µm |
| UCL(I) | 0.933 µm |
| LCL(I) | 0.681 µm |
| MR-bar | 0.0474 µm |
| UCL(MR) | 0.155 µm |
| rule-1 violations, I chart | 0 |
| rule-1 violations, MR chart | 0 |
| two-sample t (first 10 vs last 10 days) | t = 0.459, df = 18 |
| |t| vs critical 2.101 (alpha = 0.05) | 0.459 < 2.101 → no drift |

**Decision**: Ra stable at 0.807 ± ~0.04 µm → criterion 3 PASSES.

## Part 5 — Scrap exit (criterion 4)

Scrap target derivation: at Cpk = 1.33 (centered), predicted out-of-spec fraction =
2·Φ(−3·1.33) = 66.1 ppm. The 0.5% (5000 ppm) target carries ~75x margin over the
capability prediction while remaining meaningful at pilot volume (4500 pieces at
150/day × 30 days): it can be FAILED — at the true 0.5% rate, P(X ≤ 14) < 0.05.

From `pilot-scrap-daily.csv`: total scrap = **5 of 4500 = 0.111%**.

Exact binomial rule (alpha = 0.05, one-sided): exit passes iff X ≤ 14.
Clopper–Pearson 95% upper bound at X = 14 is 0.486% ≤ 0.5%; at X = 15 it is 0.513% > 0.5%.
Observed X = 5 (CP upper bound ≈ 0.235%).

**Decision**: 5 ≤ 14 → criterion 4 PASSES.

## Part 6 — Pilot receipt

| field | content |
|---|---|
| identity | modules/42-prototype-pilot/data/{pilot-bore-30day,pilot-ra-daily,pilot-scrap-daily}.csv, seed 42016, generators in data/ |
| authority | DMEDI week-21 Implement gate (RUNNING-CASE.md program calendar) |
| consequence | Cpk 1.481 (LCB 1.429); 0 rule-1 signals on X-bar/R (240 subgroups); Ra 0.807 µm stable (t = 0.459); scrap 5/4500 = 0.111% (crit. 14) |
| replay | see `court.md` (python3 exit-checked script re-derives every number above from the raw CSVs) |
| standing | 4/4 criteria PASS as of 2026-11-04; feeds Module 43 control plan and Module 44 handoff |
