# Module 23 Exercises — Simple Linear Regression

Answer in process language where asked. Every numeric answer is re-derivable from
`data/regression-simple.csv` via `scripts/derive_keys.py`.

## E1
Compute Sxx and Sxy from the definition (no calculator regression button). Then b1
and b0.

## E2
Show numerically that SST = SSR + SSE on this dataset, and state the df triplet.

## E3
A teammate computes "SST = SUM(y^2) = 15398.06" and gets R2 = 0.154. Diagnose the
error precisely and give the corrected R2.

## E4
Interpret b1 = 0.4216 um/min and b0 = 1.679 um in machine-shop terms. What physical
mechanism could make bore deviation grow with tool life?

## E5
Test H0: beta1 = 0 vs H1: beta1 != 0 at alpha = 0.05. Give t, df, critical value,
decision, and the equivalent F test.

## E6
Construct the 95% CI for beta1. Does it contain the designed target slope 0.42? What
does that tell the process engineer?

## E7
At x0 = 45 min, give yhat, the 95% CI, and the 95% PI. Explain in one sentence each
why the CI is narrow and the PI is ~5.6x wider.

## E8
R2 = 0.968. The team proposes declaring "tool life explains 96.8% of bore quality"
and closing the investigation. Give two distinct reasons this overclaims (hint: one
is about what R2 measures on THIS dataset's x-range; one is about the spine
sigma = 7.407 um regime of the running case).

## E9 (board exercise)
If n were 30 but the x's were spread over 10..80 with Sxx = 40000 instead, by what
factor would se(b1) shrink? Compute se(b1)_new = s/sqrt(Sxx).

## E10 (stretch)
Derive, from SSE/(n-2), why the df loss is exactly 2 in simple regression, and what
the df loss becomes in Module 24's k-predictor model.
