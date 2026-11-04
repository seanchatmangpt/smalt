# Module 24 Exercises — Multiple Regression

All numeric answers re-derivable from `data/regression-multi.csv` via
`scripts/derive_keys.py`.

## E1
Write the model for Ra with the fitted coefficients and give the error df. Predict
Ra at speed 10000, feed 180, temp 25.

## E2
Explain the difference between the global F(3,32) = 283.47 and the partial t = -1.718
for coolant. When does sqrt(F) = |t| (Module 23 identity), and when does it fail?

## E3
Compute the standardized beta for feed and speed from the raw b's and the sample
SDs; rank the drivers. Why is the standardized ranking the right one here when
speed ranges over thousands and feed over a hundred?

## E4
VIF for speed and feed are ~25. Give the tolerance values, state the conventional
threshold, list two process-level consequences of ignoring this, and one designed-
experiment remedy.

## E5
A teammate drops feed (not coolant) from the model and reports "model still fine,
R2 dropped only a little". Diagnose using partial t for feed (16.970) and state what
R2 change they should actually expect given SSR/SST.

## E6
Perform the reduced-model F-test for coolant: give SSE_r, F, p, decision, and the
sqrt(F) = |t| check.

## E7
The residual court: state each assumption, its test statistic (Shapiro-Wilk,
Breusch-Pagan, Durbin-Watson), its p-value, and the verdict on this dataset.

## E8
Breusch-Pagan bug hunt: an analyst computes the auxiliary TSS as SUM(e^4) (uncentered
fourth powers) and gets a hugely significant LM. Diagnose, give the correct centered
formulation, and connect it to the Module 23 TSS law.

## E9 (board)
Given VIF = 25.1 for speed, approximately how many times larger is se(b_speed) than
it would be if speed were orthogonal to the other predictors? (se inflates by
sqrt(VIF).) Compute the inflation factor numerically.

## E10 (stretch)
Show algebraically that for a single dropped predictor, F_drop = t_partial^2, using
the SSE_full/SSE_reduced relationship. Where does the identity break when you drop
two predictors at once?
