# Module 23 — Simple Linear Regression

## Case
CPPC SR-71 gimbal housing: does tool life (min) predict bore diameter deviation (um)?
Dataset `data/regression-simple.csv` (n=30, seed 42301), true law
`dev = 1.6 + 0.42*life + N(0, 1.8)`. Bore deviation is the course spine CTQ-1.

## Contents
- `slides/slides-outline.md` — OLS by hand: Sxx/Sxy, least-squares normal equations,
  full ANOVA decomposition (SST = SSR + SSE), R2/adj-R2, slope inference, CI vs PI.
- `labs/regression-simple-lab.md` — guided lab: compute the whole model by hand from
  the CSV, verify against `scripts/derive_keys.py`.
- `exercises.md` — 8 exercises, interpretation-weighted.
- `keys/solution-keys.md` — every number re-derived from the raw CSV by
  `scripts/derive_keys.py` (exit 0), never from a remembered answer.
- `courts.md` — court transcript (python3 exit-checked).
- `scripts/gen_regression_simple.py` (seed 42301) and `scripts/derive_keys.py`.

## TSS law (Lane 10 known bug, fixed and witnessed)
SST is the CENTERED sum of squared deviations, SST = SUM(y - ybar)^2 — never the
uncentered SUM(y^2). The key carries a live witness: centered SST = 2456.2738 vs
uncentered 15398.0608 on this dataset.

## Spine
Baseline regime: sigma = 7.407 um, Cpk = 0.72 (RUNNING-CASE.md, adjudicated
2026-11-04). Regression residual s here (1.665 um) describes tool-life-driven
variation, a secondary surface — it does not overwrite the spine sigma.

## Learning objectives

By the end of this module you will be able to:

1. Fit y = b0 + b1*x by least squares from the sums (Sxx, Sxy, Syy) on
   `data/regression-simple.csv`, then verify b0, b1, R2, and the ANOVA
   identity SST = SSR + SSE against E1-E2 of the exercises and their
   keys.
2. Test H0: beta1 = 0 with the slope t-test and construct its 95% CI
   (E5-E6), stating the tool-life conclusion in CPPC process terms.
3. Distinguish a confidence interval for the mean response from a
   prediction interval for a new observation at x0 = 45 (E7) and explain
   why the prediction interval is always wider.
4. Diagnose two classic overclaims: extrapolation beyond the sampled
   tool-life range (E8) and high R2 with an uninformative x-range
   (Sxx leverage, E9).
5. Verify the ANOVA identity SST = SSR + SSE with the CENTERED sum of
   squares (SST = 2456.2738, never the uncentered SUM(y^2) = 15398.0608
   — the E3 bug class) and compute the corrected R2 = 0.96840.

## Session timing

- Case briefing and least-squares derivation from the sums (20 min)
- Lab parts 1-3 (sums, fit, ANOVA) computed by hand then checked
  against `scripts/derive_keys.py` output (35 min)
- Intervals at x0 = 45 and the CI-vs-PI contrast (15 min)
- E1-E10 exercise block with keyed debrief (30 min)
- Overclaim diagnosis drill (E8/E9 as board exercise) (10 min)

## Tools

Minitab: Stat > Regression > Fitted Line Plot for the visual; Stat >
Regression > Regression > Fit Regression Model for coefficients, the
slope t and CI, and FITS/PI columns at x0 = 45. Python mirror:
`python3 scripts/gen_regression_simple.py && python3 scripts/derive_keys.py`
regenerates `data/regression-simple.csv` and the keyed values (exit 0);
scipy.stats.linregress / numpy polyfit reproduce b0, b1, r.
