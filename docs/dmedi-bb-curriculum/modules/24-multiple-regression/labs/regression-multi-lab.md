# Lab — Multiple Regression, VIF and Residual Court (Module 24)

Setup (curriculum root):

```bash
python3 modules/24-multiple-regression/scripts/gen_regression_multi.py   # seed 42401
python3 modules/24-multiple-regression/scripts/derive_keys.py            # court, exit 0
```

Dataset: `data/regression-multi.csv` — `run, spindle_speed_rpm, feed_mm_min,
coolant_temp_c, ra_um`.

## Part 1 — Fit the full model
1. Build X (4 columns: intercept, speed, feed, temp) and y (ra_um). Solve the
   normal equations. Check: b = (2.230559, -0.000405, 0.018042, -0.002774).
2. SEs from diag((X'X)^-1 * s2): (0.156231, 0.000033, 0.001063, 0.001615).
3. t and p per coefficient; df = 32.

## Part 2 — ANOVA with the centered-TSS law
4. SST = SUM((y - ybar)^2) = 2.4427. TSS witness: SUM(y^2) = 67.3714 — not SST.
5. SSE = 0.0886, SSR = 2.3542, R2 = 0.96374, adj R2 = 0.96034, s = 0.0526 um.
6. Global F(3,32) = 283.47.

## Part 3 — Standardized betas
7. beta* per predictor: speed -2.0567, feed +2.8841, coolant -0.0605. Which is the
   strongest driver?

## Part 4 — VIF by auxiliary regression (do it by hand)
8. Regress speed on (intercept, feed, temp): R2_aux = 0.9602 -> tolerance 0.0398
   -> VIF = 25.109.
9. Same for feed: R2_aux = 0.9608, VIF = 25.487; for temp: R2_aux = 0.0856,
   VIF = 1.094.
10. Question: which pair is collinear and why is that physically sensible in a
    milling plant? (Feed rises with speed to keep chip load balanced.)

## Part 5 — Residual court
11. Shapiro-Wilk on residuals: W = 0.9562, p = 0.1642.
12. Breusch-Pagan BY HAND: fit e^2 on X, R2_bp = SSE_aux/TSS_aux where BOTH are
    centered; LM = n*R2_bp = 0.613, chi2 df 3, p = 0.8934. Deliberately compute the
    uncentered TSS once and see LM shift — that is the bug witness.
13. Durbin-Watson = SUM((e_t - e_{t-1})^2)/SUM(e^2) = 2.2406.

## Part 6 — Reduced-model F-test
14. Refit without coolant: SSE_r = 0.0968.
15. F = ((0.0968 - 0.0886)/1)/(0.0886/32) = 2.950, p = 0.0955 -> keep the 2-predictor
    model.
16. Verify sqrt(F) = 1.718 = |t_coolant| and explain why that identity holds iff
    exactly one variable is dropped.

## Part 7 — Decision memo (3 sentences)
17. Recommend the operating model and the one control-plan change it implies.
