# Lab — Simple Regression, Full Derivation (Module 23)

Setup (from the curriculum root `docs/dmedi-bb-curriculum/`):

```bash
python3 modules/23-simple-regression/scripts/gen_regression_simple.py   # seed 42301
python3 modules/23-simple-regression/scripts/derive_keys.py             # court, exit 0
```

Dataset: `data/regression-simple.csv` — columns `run, tool_life_min, bore_dev_um`.

## Part 1 — Sums (compute by hand or spreadsheet, then check)
1. n, xbar, ybar. Expected: 30, 45.2800, 20.7700.
2. Sxx, Sxy, and SST = SUM((y - ybar)^2). Expected: 13380.928, 5641.676, 2456.2738.
3. TSS witness: compute SUM(y^2) (uncentered). Expected 15398.0608. Confirm it is
   NOT SST. If your worksheet ever reports SST = SUM(y^2), stop and fix — this is
   the documented Lane 10 bug class.

## Part 2 — Fit
4. b1 = Sxy/Sxx = 0.42162; b0 = ybar - b1*xbar = 1.67902.
5. Fitted values and residuals for rows 1 and 30. Check: mean(residuals) = 0
   (to rounding).

## Part 3 — ANOVA
6. SSE = SUM(e^2) = 77.6265; SSR = SST - SSE = 2378.6473; verify SSR + SSE = SST.
7. ANOVA table: SSR df 1, SSE df 28, SST df 29; MSR = 2378.6473, MSE = 2.7724,
   F = 857.98.

## Part 4 — Quality of the fit
8. R2 = 0.96840; r = 0.98407; adj R2 = 0.96727; s = 1.66505 um.
9. se(b1) = 0.01439; t = 29.291; compare sqrt(F) = 29.291 (must match).
10. 95% CI for b1: (0.3921, 0.4511).

## Part 5 — Intervals at x0 = 45
11. yhat(45) = 20.6519.
12. CI95 = (20.0293, 21.2746), width 1.2453.
13. PI95 = (17.1856, 24.1183), width 6.9328. Ratio width_PI/width_CI = 5.57.

## Part 6 — Interpretation (write 3 sentences)
14. In process language: what does b0 = 1.68 um mean, and why is extrapolating the
    line below ~10 min tool life unsafe?
15. The plant runs tools to 60 min. Predict bore deviation and give the PI.
    Answer: yhat(60) = 1.6790 + 0.4216*60 = 26.98 um; PI = 26.98 +/- 2.048 * 1.66505
    * sqrt(1 + 1/30 + (60-45.28)^2/13380.928) = 26.98 +/- 3.625 -> (23.35, 30.60) um.
    Note 30.60 um exceeds the +25 um spec limit: the model, not the gauge, is the alarm.
