# Module 21 Solution Key — exercises E1-E6

All numbers are the verbatim output of an executed run of the derivation
script shipped at `keys/derive.py`, run from the curriculum root. Data:
`data/coating-ab-bore.csv` (seed 42191), `data/paired-feed.csv` (seed 42192),
`data/coolant-anova.csv` (seed 42193), all registered. The README tables
must match this output (they do).

## Executed receipt (verbatim, full run)

```
coating: nA=30 nB=30 meanA=12.0061 sA=0.0041 meanB=12.0016 sB=0.0043
sp=0.0042 t_pooled=4.187 tcrit=2.002 p=9.720e-05
welch t=4.187 df=57.8 p=9.751e-05
levene W=0.053 p=0.819 | bartlett K2=0.086 p=0.770
MW U=726.0 p=4.624e-05
paired: n=25 dbar=-0.0030 sd=0.0022 t=-6.924 p=3.680e-07 ci=(-0.0039,-0.0021)
unpaired contrast: t=2.508 p=0.0156 p-ratio=2.36e-05
anova: grand=12.0048 SSB=0.00044544 SSW=0.00046799 SST=0.00091343
F=12.850 Fcrit=3.354 p=0.00012 MSW=0.00001733
mean 5% = 12.0081
mean 8% = 12.0069
mean 12% = 11.9993
0-1 diff=0.0012 ci=(-0.0026,0.0050) sig=False
0-2 diff=0.0087 ci=(0.0049,0.0125) sig=True
1-2 diff=0.0075 ci=(0.0037,0.0113) sig=True
```

## Answers

- **E1**: Levene W = 0.053, p = 0.819; Bartlett K-squared = 0.086,
  p = 0.770 — keep H0 of equal variances, so the pooled t is lawful. If
  Levene fired (p < 0.05), only the Welch row is lawful; pooled then
  inflates Type I error.
- **E2**: meanA = 12.0061 (s 0.0041), meanB = 12.0016 (s 0.0043), sp =
  0.0042, pooled t = 4.187 (df 58, tcrit 2.002, p = 9.72e-5); Welch t =
  4.187, df = 57.8, p = 9.75e-5. Identical decision. Process decision:
  coating A runs ~4.5 um higher — the centering lever for the Improve
  phase if 12.000 nominal is the target.
- **E3**: d-bar = -0.0030 mm (-3.0 um), s_d = 0.0022, paired t = -6.924
  (df 24, tcrit 2.064, p = 3.68e-7), difference CI (-0.0039, -0.0021).
  Unpaired contrast on the same numbers: t = 2.508, p = 0.0156 — the
  executed p-ratio (paired/unpaired) is 2.36e-05, i.e. the unpaired p is
  over 40,000x the paired p. Pairing removes part-to-part variance from
  the comparison.
- **E4**: U = 726, p = 4.62e-5 → reject H0 of equal distributions/medians;
  agrees with the t as it should on clean, similar-shaped data. Buys
  robustness, not power. Tree path: TWO independent samples → medians.
- **E5**: SSB = 0.00044544, SSW = 0.00046799, SST = 0.00091343 (2 and 27
  df), MSW = 0.00001733, F = 12.850 > Fcrit = 3.354, p = 0.00012 → reject
  H0. Group means: 5% = 12.0081, 8% = 12.0069, 12% = 11.9993. Pairwise
  MSW CIs: 5%-8% diff 0.0012, CI (-0.0026, 0.0050), not significant;
  5%-12% diff 0.0087, CI (0.0049, 0.0125), significant; 8%-12% diff 0.0075,
  CI (0.0037, 0.0113), significant. Process read: 12% coolant centers the
  process on nominal; 5% does not.
- **E6**: 1-sample t → ONE → Q3 sigma unknown; pooled/Welch 2-sample t and
  Levene/Bartlett → TWO → indep → means → Q4; Mann-Whitney → TWO → indep
  → medians; paired t → TWO → paired; ANOVA → 3+ groups. Exit rule: a
  test you cannot walk back up the tree is a test you cannot place.

## Cross-check vs court.py pins

Every value matches the module 21 court pins exactly (sp 0.0042, t 4.187,
p 9.72e-5; Welch 57.8/9.75e-5; paired -6.924/3.68e-7, CI -0.0039/-0.0021;
Levene 0.053/0.819, Bartlett 0.086/0.770; MW U 726 / p 4.62e-5; ANOVA
SSB/SSW/F 12.850 and group means; pairwise diff/significance table).
Drift finding (1, disclosed): the README §3 / objectives / timing "400x"
p-value contrast claim understates the executed ratio 0.0156/3.68e-7 ≈
4.2e4 (over 40,000x); the court pins only p_ratio < 0.01, so the README
prose was corrected to the executed magnitude.
