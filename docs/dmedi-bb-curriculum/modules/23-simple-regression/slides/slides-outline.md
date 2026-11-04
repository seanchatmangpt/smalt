# Module 23 Slides Outline — Simple Linear Regression

Case thread: CPPC gimbal housing, tool life (min) -> bore deviation (um).
Data: `data/regression-simple.csv`, n=30, seed 42301.

## S1. Why regression in the Analyze phase
- Question type: "does X move Y, and by how much?" — a modeled relationship,
  not a group comparison.
- CPPC framing: tool life is cheap to control; bore deviation is the CTQ-1.
- Deliverable of the module: fitted line + ANOVA table + intervals, all by hand.

## S2. Scatter first, always
- Plot bore_deviation_um vs tool_life_min; look for linearity, outliers, spread drift.
- Vocabulary: response y, predictor x, fitted value yhat, residual e = y - yhat.

## S3. Least squares by hand
- Minimize SUM e^2 -> normal equations -> b1 = Sxy/Sxx, b0 = ybar - b1*xbar.
- Define Sxx = SUM(x - xbar)^2, Sxy = SUM((x-xbar)(y-ybar)).
- Worked numbers (dataset): Sxx = 13380.928, Sxy = 5641.676.
- Fitted line: yhat = 1.6790 + 0.4216 x. Interpretation: +1 min tool life ->
  +0.42 um bore deviation on average.

## S4. The ANOVA decomposition (the TSS law)
- SST = SUM(y - ybar)^2 (centered!). SSR = SUM(yhat - ybar)^2. SSE = SUM e^2.
- Identity: SST = SSR + SSE. On this data: 2456.2738 = 2378.6473 + 77.6265.
- TSS bug warning (real lane history): using uncentered SUM(y^2) silently inflates
  SST (here 15398.06), breaks the identity, and poisons R2, F, and s.
- df: SST n-1 = 29, SSR 1, SSE n-2 = 28.

## S5. R2, r, adjusted R2
- R2 = SSR/SST = 0.96840; r = sign(b1)*sqrt(R2) = 0.98407.
- adj R2 = 1 - (1-R2)(n-1)/(n-2) = 0.96727 — the honest metric vs adding predictors.
- Caution: R2 is not causation; confounding lives until a DOE isolates it.

## S6. s and the standard error of the slope
- MSE = SSE/(n-2) = 2.7724, s = sqrt(MSE) = 1.66505 um.
- se(b1) = s/sqrt(Sxx) = 0.01439. t = b1/se(b1) = 29.291, df = 28, p ~ 0.
- t_crit(0.025, 28) = 2.048. 95% CI for b1: 0.4216 +/- 2.048*0.01439 =
  (0.3921, 0.4511) — excludes 0 and, notably, contains the planted 0.42.

## S7. The F-test in simple regression
- F = MSR/MSE = 2378.6473/2.7724 = 857.98 on (1, 28).
- Identity: sqrt(F) = |t| = 29.291 — one test, two dresses. In multiple
  regression (Module 24) F and t part ways.

## S8. Confidence vs prediction intervals at x0 = 45 min
- yhat(45) = 20.6519 um.
- CI (mean response): 20.6519 +/- 2.048 * s * sqrt(1/n + (x0-xbar)^2/Sxx)
  = (20.0293, 21.2746), width 1.2453.
- PI (new observation): adds the +1 under the root -> (17.1856, 24.1183),
  width 6.9328 — 5.6x wider. Teaching point: never promise a PI-width tolerance
  to a customer from a CI-width calculation.

## S9. Residual sanity checks
- Residuals vs fits: no funnel; vs order: no drift; normal plot: roughly straight.
- Formal versions of these checks arrive in Module 24 (Shapiro-Wilk, BP, DW).

## S10. Workshop bridge
- Lab: re-derive every number above from the CSV.
- Bridge to Module 24: what changes when there are three x's? Collinearity,
  partial t, VIF, the reduced-model F — and SST stays centered.
