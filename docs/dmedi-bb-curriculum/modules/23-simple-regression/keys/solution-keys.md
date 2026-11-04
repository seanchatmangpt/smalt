# Module 23 Solution Keys

All numbers derived from `data/regression-simple.csv` (seed 42301) by
`scripts/derive_keys.py` — exit 0 court. No remembered answers.

## E1 — sums and fit
- n = 30, xbar = 45.2800, ybar = 20.7700
- Sxx = 13380.9280, Sxy = 5641.6760, SST = Syy = 2456.2738 (centered)
- TSS witness: uncentered SUM(y^2) = 15398.0608 — NOT SST
- b1 = 5641.6760/13380.9280 = 0.42162; b0 = 20.7700 - 0.42162*45.2800 = 1.67902
- Fitted line: yhat = 1.6790 + 0.4216 x

## E2 — ANOVA identity
- SSE = 77.6265 (df 28), SSR = 2378.6473 (df 1), SST = 2456.2738 (df 29)
- SSR + SSE = 2456.2738 = SST exactly (court asserts < 1e-6 relative)

## E3 — TSS bug diagnosis
The teammate used the UNCENTERED sum of squares SUM(y^2) = 15398.06 instead of the
centered SUM((y-ybar)^2) = 2456.27. Since SSR is centered by construction, the
identity SST = SSR + SSE breaks; their R2 = SSR/wrong-SST = 0.154. Correct
R2 = 2378.6473/2456.2738 = 0.96840.

## E4 — interpretation
b1 = 0.4216 um/min: each additional minute of tool life is associated with +0.42 um
bore deviation on average — consistent tool wear growing the bore. b0 = 1.679 um is
the model's deviation at 0 min, physically meaningless as a prediction (no part cut
with a zero-minute tool); it anchors the line inside the observed 10..80 min range.
Mechanism: progressive flank wear of the end mill increases effective diameter
removal, drifting bore large.

## E5 — slope t-test
- se(b1) = s/sqrt(Sxx) = 1.66505/sqrt(13380.928) = 0.01439
- t = 0.42162/0.01439 = 29.291, df = 28, t_crit = 2.048 -> reject H0, p ~ 0
- Equivalent F = MSR/MSE = 2378.6473/2.7724 = 857.98 on (1, 28); sqrt(F) = 29.291 = |t|

## E6 — CI for the slope
0.42162 +/- 2.048*0.01439 = (0.3921, 0.4511) um/min. It contains 0.42: the data is
consistent with the designed wear rate; the process engineer keeps the wear-compensation
schedule unchanged in magnitude.

## E7 — intervals at x0 = 45
- yhat(45) = 20.6519 um
- CI95 (mean response) = (20.0293, 21.2746), width 1.2453 — uncertainty only in the
  line's POSITION
- PI95 (single new part) = (17.1856, 24.1183), width 6.9328 — adds the part-to-part
  scatter s = 1.665 under the root; 6.9328/1.2453 = 5.57x wider

## E8 — overclaim diagnosis
1. R2 measures association over the sampled x-range (10..80 min) under the
   regression's noise floor; it says nothing about causation (coolant, material lot,
   temperature are unmodeled confounds) nor outside the range.
2. The spine regime is sigma = 7.407 um total process sigma (RUNNING-CASE.md);
   this dataset's residual s = 1.665 um is the tool-life conditional scatter, one
   component family. "Explains 96.8% of bore quality" silently substitutes the
   conditional s for the total process sigma.

## E9 — Sxx leverage
se(b1)_new = 1.66505/sqrt(40000) = 1.66505/200 = 0.008325 um/min.
Factor shrink = 0.01439/0.008325 = 1.73x. Wider x-spread buys slope precision free
of extra runs.

## E10 — df accounting
Each estimated parameter consumes one df from the n residuals: intercept + slope = 2
parameters -> df = n-2. With k predictors (Module 24): df = n-k-1; the reduced-model
F-test in Module 24 spends one more df when a predictor is dropped.
