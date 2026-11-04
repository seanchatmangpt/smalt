# Module 09 Lab — Descriptives, Tukey Fences, Normal Probes, and the CLT

Run from the curriculum root. Dataset: `data/bore-baseline-100.csv` (seed 42008).
Every step's python3 mirror is inside `courts/court.py` — running the court is the lab
check. The Minitab path is given alongside so the mapping is explicit.

## Part 1 — Descriptives and the center decision (15 min)

Minitab: Stat > Basic Statistics > Display Descriptive Statistics (N, Mean, StDev,
Min, Max, Q1, Q3, Range, IQR) on `bore_diameter_mm`. Compare mean vs median:

| mean | median | verdict |
|---|---|---|
| 12.009815 | 12.00995 | near-identical → symmetric, mean lawful |

## Part 2 — Tukey fences and disposition (15 min)

Compute Q1, Q3, IQR, then fences Q1 − 1.5·IQR and Q3 + 1.5·IQR. Expected:
**11.9928 / 12.0277** (IQR 0.008725). List the bores outside the fences — expect four:
11.9849, 11.9907, 11.9909, 12.0293. Disposition: three are legal low tails; 12.0293 is
ALSO outside spec (USL 12.025) — the one scrap part that makes the Cpk-0.72 baseline
visible. Keep and disposition; never delete without a measurement-system reason (Module 11).

## Part 3 — Normal distribution probes (20 min)

Minitab: Calc > Probability Distributions > Normal > Cumulative probability.

| mean setting | query | expected |
|---|---|---|
| 12.000 (centered), SD 0.0074 | P(X < 11.975) | 3.65e-4 |
| 12.0098 (measured), SD 0.0074 | P(X < 11.975) | 1.27e-6 |
| 12.0098 (measured), SD 0.0074 | P(X > 12.025) | 2.01e-2 |

Read the asymmetry: the binding (USL) tail carries ~2% scrap; centering rebalances,
but only spread reduction brings the total loss to the PPM class.

## Part 4 — CLT simulation (seed 42009) (25 min)

1000 sample means of n = 5 from N(12.009, 0.007407). Prediction first: sigma/sqrt(5) =
3.313 um. Then simulate (script in solution-key.md, sigma = 7.407 um adjudicated
2026-11-04). Expected: mean of means 12.0089, sd of means **3.406 um** (+2.8%).
Variant: resample n = 5 with replacement from the stored CSV (seed 42010) →
**3.386 um** (+2.2% — same adjudicated-scale data, both legs agree).

Then the skew-parent variant: replace the parent with an exponential (same mean) and
re-run — the histogram of means stays near-normal while the parent is visibly skewed.
That is the CLT, witnessed rather than recited.

## Gate (5 min)

- [ ] Part 1 table reproduced
- [ ] Part 2: fences + exactly 4 flagged bores, each dispositioned (kept, in-spec)
- [ ] Part 3: all three probes within display precision
- [ ] Part 4: sd of means within ±3% of 3.313 um; skew-parent histogram near-normal
- [ ] `python3 modules/09-basic-statistics/courts/court.py` exits 0
