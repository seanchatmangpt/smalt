# Module 25 Solution Keys

All numbers derived from `data/multivari-bore.csv` (seed 42501) by
`scripts/derive_keys.py` — exit 0 court.

## E1 — design
Families: POSITIONAL pc (PC1..PC5, 5 levels), CYCLICAL spindle (S1..S3, 3 levels),
TEMPORAL time_block (T1..T3, 3 levels). 45 obs = 5 x 3 x 3; 9 obs per pc level,
15 per spindle / time level. Balance matters because sigma2_family = (MSB - MSW)/m
uses a single m per family; unbalance forces a different (weighted) estimator.

## E2 — totals and TSS diagnosis
Grand mean = 8.6198 um; SST = SUM((y - ybar)^2) = 2518.5487; total s = 7.5657 um
(variance 57.2397). The teammate computed the UNCENTERED sum SUM(y^2) = 5862.074 —
the documented Lane 10 bug class (Module 23 E3 is the same defect in regression
clothing).

## E3 — eta^2 positional
eta^2 = SSB/SST = 2243.543/2518.5487 = 0.8908. Plain language: 89% of everything
that varies in bore deviation is explained by WHERE the part sits (pc position /
fixture location), before looking at machines or time.

## E4 — spindle family and the floor
MSB = 4.664, MSW = 59.743, F = 4.664/59.743 = 0.08; sigma2_family =
max((4.664 - 59.743)/15, 0) = 0 (clamped); sigma2_within = 59.743. The un-floored
value (-3.67) would claim a NEGATIVE between-spindle variance, i.e. spindle means
more alike than random sampling allows — a sampling artifact, not a population
fact; the floor encodes "no measurable effect".

## E5 — eta^2 vs component share
eta^2 = 0.8908 = 89.1% of SST; component share = 61.5567/(61.5567 + 6.8751) = 90.0%.
They agree closely because the design is balanced; they differ because eta^2 splits
the raw SST (including within-cell noise) while the component share re-estimates
the population decomposition and strips estimation bias from MSW.

## E6 — chart signature vs noise
If pc means were draws from one population, the 5 means would scatter within about
+/-2 s_each/sqrt(9)... at the observation level the expected RANGE of 5 such means
is on the order of 3-4 within-cell SDs (~8-10 um worst case), but more to the point
each ADJACENT gap would be indistinguishable from 0 within ~2s/sqrt(9) ~ 1.7 um.
Observed: a monotone staircase of ~5 um steps, endpoint spread 19.79 um = 7.5x the
within-cell s — the positional signature is unmissable.

## E7 — refusal memo (model answer)
"The spindle family is statistically indistinguishable from noise: F(2,42) = 0.08
against a critical value near 3.2, and its variance component clamps at 0 (0.0%
share). Time blocks are the same story (F = 0.12). The positional family carries
90% of the variance with F = 81.58; spending the same engineering hours on a
zero-signal family while the fixture owns 90% of the problem is not a resource
decision we can defend."

## E8 — expected MSB under a planted spindle effect
E[MSB] = sigma2_within + m * sigma2_family = 6.9 + 15 * (3^2) = 6.9 + 135 = 141.9.
Against MSW ~ 6.9, F ~ 141.9/6.9 ~ 20.6 — a real 3 um spindle effect would be
glaringly obvious in this design; the observed F = 0.08 certifies its absence.

## Derived summary (court output)
- Grand mean 8.6198 um, total s 7.5657 um (spine regime 7.407 um — court band passed)
- Positional: F = 81.58, eta^2 = 0.8908, sigma2_family 61.5567, share 90.0%
- Cyclical: F = 0.08, share 0.0% | Temporal: F = 0.12, share 0.0%
- TSS witness: centered 2518.549 vs uncentered 5862.074
