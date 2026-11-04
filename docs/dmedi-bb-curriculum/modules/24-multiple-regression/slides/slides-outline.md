# Module 24 Slides Outline — Multiple Regression

Case thread: CPPC surface finish Ra (um) from speed, feed, coolant temp.
Data: `data/regression-multi.csv`, n=36, seed 42401.

## S1. From one x to many
- Why: bore/finish quality has several candidate drivers simultaneously; simple
  regression attributes shared effects to whichever x you happened to plot.
- The fitted model: yhat = b0 + b1x1 + b2x2 + b3x3; each bj is a PARTIAL effect
  (holding the others fixed).

## S2. Normal equations without tears
- X'X b = X'y; solve via (X'X)^-1. Matrix view only; the solver in
  `scripts/derive_keys.py` is hand-rolled (Gauss on X'X), no regression library.
- df accounting: n - k - 1 = 36 - 3 - 1 = 32 error df.

## S3. The fitted model and its table
- Coefficients with SE, t, p (from the key):
  Intercept 2.230559 (se 0.156231, t 14.277)
  speed -0.000405 (se 0.000033, t -12.192, p 1.4e-13)
  feed 0.018042 (se 0.001063, t 16.970, p 1.5e-17)
  coolant_temp -0.002774 (se 0.001615, t -1.718, p 0.0955)
- Reading: +1 mm/min feed costs +0.018 um Ra at fixed speed and temp;
  +1000 RPM buys -0.405 um Ra at fixed feed and temp.

## S4. ANOVA and the two F-tests
- SST = 2.4427 (centered), SSR = 2.3542, SSE = 0.0886; R2 = 0.96374,
  adj R2 = 0.96034; s = 0.0526 um.
- Global F(3, 32) = 283.47, p = 4.1e-23: at least one slope nonzero.
- Partial t's answer the sharper per-variable question; they and the global F are
  different tests (contrast Module 23 where sqrt(F) = |t| always).

## S5. Standardized betas — ranking effects on different scales
- beta*_j = b_j * sd(x_j)/sd(y): speed -2.0567, feed +2.8841, coolant -0.0605.
- Feed is the strongest standardized driver despite speed's larger raw range.

## S6. Collinearity and VIF
- Planted: feed rises with speed (r ~ +0.85) -> inflated joint variance.
- VIF_j = 1/(1 - R2_aux,j) from regressing x_j on the other x's:
  speed 25.109, feed 25.487, coolant 1.094.
- Consequences: huge SEs relative to b, unstable signs across samples, VIF > 10
  conventionally "severe". Remedies preview: more data, centering, ridge, or a
  designed DOE (Module 30+) which orthogonality fixes by construction.

## S7. Residual analysis — the four assumptions, tested not asserted
- Normality: Shapiro-Wilk W = 0.9562, p = 0.1642 -> OK.
- Homoscedasticity: Breusch-Pagan LM = 0.613 (chi2, df 3), p = 0.8934 -> OK.
  Hand formula: regress e^2 on the x's, LM = n * R2 of that fit; the auxiliary
  TSS is SUM((e^2 - mean(e^2))^2) — CENTERED. (Uncentered here = the same bug class
  as Module 23; witnessed in the key output.)
- Independence: Durbin-Watson = 2.2406 -> no autocorrelation signal.
- Linearity: residual-vs-fit plot flat; curvature would send you to Module 37.

## S8. The reduced-model F-test (drop a useless predictor)
- Question: does coolant temp earn its df? Compare SSE_full = 0.0886 vs
  SSE_reduced (drop coolant) = 0.0968.
- F = ((SSE_r - SSE_f)/1)/(SSE_f/df_e) = 2.950 on (1, 32), p = 0.0955.
- Identity: sqrt(F) = |t_partial| = 1.718 — dropping ONE variable, the F-test is
  exactly the square of its partial t. Keep the model parsimonious: drop coolant.

## S9. Decision framing
- Final model: Ra = f(speed, feed). Control plan implications: feed is the
  dominant lever, speed secondary; coolant temp is monitored, not modeled.

## S10. Bridge
- Module 25: when the drivers are CATEGORIES (pc, spindle, time block), regression
  hands off to multi-vari / variance components.
