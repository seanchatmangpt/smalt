# Module 24 Solution Keys

All numbers derived from `data/regression-multi.csv` (seed 42401) by
`scripts/derive_keys.py` — exit 0 court.

## E1 — model and prediction
Ra = 2.230559 - 0.000405*speed + 0.018042*feed - 0.002774*temp; df_error = 32.
At (10000, 180, 25): 2.230559 - 4.05 + 3.24756 - 0.06935 = 1.359 um.

## E2 — global F vs partial t
Global F asks "is SOME slope nonzero?" (H0: all three = 0) — F(3,32) = 283.47,
p = 4.1e-23, reject. Coolant's partial t = -1.718, p = 0.0955 asks "does THIS
variable add anything GIVEN the others?" The sqrt(F) = |t| identity holds only for
k = 1 predictor (Module 23) or for a reduced-model F dropping exactly one variable;
with 3 predictors the global F pools all three and has no single t partner.

## E3 — standardized betas
beta*_speed = -0.000405 * sd(speed)/sd(Ra) = -2.0567
beta*_feed = 0.018042 * sd(feed)/sd(Ra) = +2.8841
beta*_coolant = -0.0605.
Ranking: feed > |speed| >> coolant. Raw coefficients are scale-bound (RPM in
thousands vs feed in tens); standardized betas put both in sd-of-y units.

## E4 — collinearity
Tolerances: speed 0.0398, feed 0.0392 (VIF 25.109 / 25.487); coolant 0.9144
(VIF 1.094). VIF > 10 = severe by convention. Consequences: (1) se(b) inflated by
sqrt(VIF) ~ 5x, so CIs too wide to be useful and coefficients flip sign across
samples; (2) the plant cannot attribute an effect to speed vs feed, so a univariate
control "fix" on one lever may not move Ra. Remedy: a designed DOE (Modules 30-31)
sets speed and feed orthogonally by construction, collapsing VIF to ~1.

## E5 — dropping the wrong variable
Feed's partial t = 16.970 (p = 1.5e-17): it is the strongest predictor; dropping it
is not a small perturbation. With feed removed, SSE jumps from 0.0886 toward the
SST scale — R2 falls from 0.96374 to roughly the R2 of speed-alone on Ra, losing
the dominant share of explained variance, not "a little".

## E6 — reduced-model F for coolant
SSE_full = 0.0886, SSE_reduced = 0.0968.
F = ((0.0968 - 0.0886)/1)/(0.0886/32) = 2.950 on (1, 32), p = 0.0955.
Decision: fail to reject — coolant earns no df; adopt Ra = f(speed, feed).
Check: sqrt(2.950) = 1.718 = |t_coolant|. Identity holds because exactly one
parameter is constrained.

## E7 — residual court
- Normality: Shapiro-Wilk W = 0.9562, p = 0.1642 -> OK.
- Homoscedasticity: Breusch-Pagan LM = 0.613 (chi2 df 3), p = 0.8934 -> OK.
- Independence: Durbin-Watson = 2.2406 -> no autocorrelation (near 2).
- Linearity: residual-vs-fit pattern-free (plot check).
All four assumptions pass; the OLS inference table is trustworthy.

## E8 — BP bug hunt
SUM(e^4) is the UNCENTERED TSS of e^2. Correct: TSS_bp = SUM((e^2 - mean(e^2))^2),
then LM = n * (1 - SSE_aux/TSS_bp). Uncentered TSS adds mean(e^2)^2 * n of phantom
variation, deflating R2_bp... or, if instead the analyst centers wrongly, LM can
inflate arbitrarily and "detect" heteroscedasticity that is not there. This is the
same bug class as Module 23's uncentered SST; on this dataset the centered
computation gives LM = 0.613, p = 0.8934 (no heteroscedasticity).

## E9 — SE inflation
se(b_speed) inflates by sqrt(VIF) = sqrt(25.109) = 5.01x vs an orthogonal design.
The price of observational collinearity: 5x wider slope uncertainty, or equivalently
~25x the data needed for the same precision.

## E10 — F_drop = t^2
For one dropped variable, SSE_r - SSE_f = b_j^2 / c_jj where c_jj is the j-th
diagonal of (X'X)^-1, and se(b_j)^2 = s^2 * c_jj. Hence
F = (SSE_r - SSE_f)/s^2 = b_j^2/(s^2 c_jj) = (b_j/se_j)^2 = t_j^2. Dropping two
variables at once breaks the identity: the numerator has 2 df and mixes both
coefficients' contributions into one chi-square — the F no longer corresponds to
any single t.
