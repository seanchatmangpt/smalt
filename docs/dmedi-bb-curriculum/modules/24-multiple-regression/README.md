# Module 24 — Multiple Regression

## Case
CPPC surface finish on the gimbal housing: spindle speed (RPM), feed (mm/min),
coolant temperature (C) -> Ra (um). Dataset `data/regression-multi.csv` (n=36,
seed 42401), true law `Ra = 2.10 - 0.00040*speed + 0.0180*feed + 0*temp + N(0, 0.06)`.
Planted structure: (a) speed/feed collinearity (r ~ +0.85 -> VIF ~ 25); (b) coolant
temp is pure noise, fueling the reduced-model F-test.

## Contents
- `slides/slides-outline.md` — normal-equation OLS, partial t vs global F,
  standardized betas, VIF/tolerance, residual analysis (Shapiro-Wilk, Breusch-Pagan,
  Durbin-Watson), reduced-model F-test.
- `labs/regression-multi-lab.md` — guided lab incl. hand VIF via auxiliary regressions.
- `exercises.md` — 9 exercises.
- `keys/solution-keys.md` — every coefficient/SE/t/p/VIF/F/R2 derived from the raw
  CSV by `scripts/derive_keys.py` (exit 0).
- `courts.md` — court transcript (python3 exit-checked).
- `scripts/gen_regression_multi.py` (seed 42401), `scripts/derive_keys.py`.

## TSS law (Lane 10 known bug, fixed and witnessed)
SST = SUM((y - ybar)^2), centered — never SUM(y^2). Witness on this data: centered
SST = 2.4427 vs uncentered 67.3714. The same law applies to the Breusch-Pagan
auxiliary TSS (TSS of e^2 must be centered about mean(e^2)), which is where the bug
class first bit this lane.

## Learning objectives

By the end of this module you will be able to:

1. Fit the three-predictor Ra model by OLS and interpret each partial
   coefficient in CPPC process units (um per RPM, um per mm/min, um per C)
   against the keyed values in `keys/solution-keys.md`.
2. Contrast a significant global F with a NON-significant partial t (the
   coolant-temp plant) and explain why both can be true in one model.
3. Compute a VIF by hand via the auxiliary-regression route (speed on
   feed; r ~ +0.85, VIF ~ 25) and state the multicollinearity threshold
   the lab uses.
4. Run the residual diagnostics (Shapiro-Wilk, Breusch-Pagan,
   Durbin-Watson) and classify each assumption as met or violated on
   this dataset.
5. Execute the reduced-model F-test to justify dropping coolant temp,
   verifying the centered-TSS law (SST = 2.4427, never SUM(y^2) =
   67.3714) in the auxiliary Breusch-Pagan computation.

## Session timing

- Case briefing and the normal-equation setup (15 min)
- Lab: hand VIF via auxiliary regressions (25 min)
- Partial t vs global F worked example, instructor derivation visible
  from `keys/solution-keys.md` (20 min)
- Residual diagnostics walkthrough (15 min)
- Reduced-model F-test + exercise block debrief (20 min)

## Tools

Minitab: Stat > Regression > Regression > Fit Regression Model
(coefficients, VIF, residual plots, and the sequential/reduced-model F
are all in one dialog); Stat > Basic Statistics > Correlation for the
speed-feed r. Python mirror:
`python3 scripts/gen_regression_multi.py && python3 scripts/derive_keys.py`
regenerates `data/regression-multi.csv` and every keyed value (exit 0);
statsmodels OLS with `variance_inflation_factor` mirrors the VIF.
