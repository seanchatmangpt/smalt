# Module 21 — Tests on Means, Medians, Variances

Spine-consistent datasets, all bore diameter (mm):

- `data/coating-ab-bore.csv` — tool coating A vs B, 30 parts each (seed 42191)
- `data/paired-feed.csv` — 25 parts, bore before/after a feed-rate change
  (seed 42192)
- `data/coolant-anova.csv` — coolant 5% / 8% / 12%, 10 parts each (seed 42193)

Every section ends with its placement on the flagship tree
([decision tree](../19-hypothesis-testing/decision-tree.md)); §7 closes the
module on it.

## 1. 1-sample t — line 2 after setup change

(from Module 19, summarized here for the tree's ONE-population path;
full derivation in M19 §5 and `key.md`: t = 11.197, df = 29,
p = 4.78e-12, reject H0: mu = 12.000.)

## 2. 2-sample t (coating A vs B)

Design: 60 parts randomized to coated (A) vs uncoated (B); H0:
muA = muB; alpha = 0.05. Pre-test variances first (§4): Levene
W = 0.053, p = 0.819 — no variance difference, so **pooled** is lawful.

- meanA = 12.0061 (s = 0.0041), meanB = 12.0016 (s = 0.0043)
- pooled sp = 0.0042; t = (meanA - meanB)/(sp*sqrt(2/30)) = **4.187**,
  df = 58, tcrit = 2.002
- p = **9.72e-5** → **reject H0**: coating A runs ~4.5 um higher than B.
  Process decision: if 12.000 nominal is the target, coating choice is a
  centering lever for the Improve phase — exactly the DOE factor the
  running case pins (tool coating A/B).

### 2b. Welch (Satterthwaite) variant

Same data through the unequal-variance gate: Welch t = 4.187, df = 57.8,
p = 9.75e-5. Identical decision — the equal-variance assumption was safe
here (Levene said so). When Levene fires (p < 0.05), only the Welch row is
lawful; the pooled t then inflates Type I error.

## 3. Paired t (feed-rate change)

Same 25 parts measured before and after the feed change; H0: mu_d = 0.

- mean difference d-bar = **-0.0030 mm** (-3.0 um), s_d = 0.0022
- t = -6.924, df = 24, tcrit = 2.064, p = **3.68e-7** → **reject H0**
- 95% CI of the difference: (-0.0039, -0.0021) mm — the feed change
  genuinely lowered bore ~3 um with the CI's entire range operationally
  meaningful (spec half-width is 25 um).
- Contrast (why pairing matters): running the SAME numbers as an independent
  2-sample t gives t = 2.508, p = 0.016 — it still rejects, but with 400x
  the p-value; with weaker signal it would miss entirely. Pairing removes
  part-to-part variance from the comparison. (Also the M20 trap: marginal
  CIs overlap, paired t rejects hard.)

## 4. Levene and Bartlett (variance homogeneity)

- Levene (median-centered, robust): W = 0.053, df = (1, 58), p = 0.819 —
  keep H0 of equal variances.
- Bartlett (assumes normality): K-squared = 0.086, df = 1, p = 0.770 —
  same verdict; use only when normality holds (it is sensitive to
  nonnormality and can fire on kurtosis, not variance).

## 5. Mann-Whitney U (medians, distribution-free)

Path on the tree: two independent samples, medians question (nonnormal or
outlier-heavy response). Bore A vs B: U = **726**, p = **4.62e-5** → reject
H0 of equal distributions/medians — agrees with the t, as it should when
shapes are similar. It buys robustness, not power: with clean normal-ish
data the t is slightly more powerful; Mann-Whitney earns its place when a
handedness of outliers (a single crashed-tool part) would drag the mean.

## 6. One-way ANOVA teaser (coolant concentration)

H0: mu(5%) = mu(8%) = mu(12%); 10 parts per level.

| source | SS | df | MS | F |
|---|---|---|---|---|
| coolant | 0.00044544 | 2 | 0.00022272 | **12.850** |
| error | 0.00046799 | 27 | 0.00001733 | |
| total | 0.00091343 | 29 | | |

F(2, 27) crit(0.95) = 3.354; p = **0.00012** → **reject H0**: coolant
concentration shifts the bore center. Group means: 5% = 12.0081,
8% = 12.0069, 12% = 11.9993. Follow-up pairwise t CIs (MSW-based; these are
per-contrast CIs, not a family-corrected Tukey HSD — see the tree's
pre-test/estimation notes):

| contrast | diff (mm) | 95% CI | rejects? |
|---|---| ANOVA teaser |
| 5% - 8% | 0.0012 | (-0.0026, 0.0050) | no |
| 5% - 12% | 0.0087 | (0.0049, 0.0125) | yes |
| 8% - 12% | 0.0075 | (0.0037, 0.0113) | yes |

(12% coolant centers the process on nominal; 5% does not. One-way ANOVA is
a teaser; module 28 carries the full factorial treatment.)

## 7. Module close — the decision tree

Place every test of this module on the flagship tree
([decision-tree.md](../19-hypothesis-testing/decision-tree.md)):
1-sample t (path ONE→Q3 sigma unknown), pooled/Welch 2-sample t and
Levene/Bartlett (path TWO→indep→means→Q4), Mann-Whitney (TWO→indep→medians),
paired t (TWO→paired), ANOVA (3+ groups). If you cannot walk a test back to
the top of the tree, you do not know when to use it — that walk is the
module's exit check.

## Learning objectives

By the end of this module you will be able to:

1. Choose and run the correct 2-sample test (pooled vs Welch) only after a
   Levene gate, and justify the gate with the W = 0.053 / p = 0.819
   result on coating A vs B.
2. Compute a paired t (and its difference CI) by hand on
   `data/paired-feed.csv` and explain in one paragraph why pairing
   removes part-to-part variance (400x p-value contrast, §3).
3. Run a one-way ANOVA on the three-coolant data and decompose its
   result into between/within variation (see `key.md` derivation).
4. Select medians-class tests (Mann-Whitney) when normality fails and
   state the decision-tree path that forces the switch.
5. Place all five tests of this module on the flagship decision tree
   from scenario text alone (the module exit check).

## Session timing

- Tree orientation: where means/medians/variances tests sit (10 min)
- Pooled vs Welch with the Levene gate, worked from `key.md` (20 min)
- Paired t worked example with the 400x contrast demo (15 min)
- One-way ANOVA on coolant data, instructor derivation visible (20 min)
- Learner drill: medians-class switch scenario + tree placement of all
  five tests (15 min)

## Tools

Minitab: Stat > Basic Statistics > 2-Sample t (equal-variance checkbox
controls pooled vs Welch); Stat > Basic Statistics > Paired t;
Stat > ANOVA > One-Way; Stat > ANOVA > Test for Equal Variances (Levene);
Stat > Nonparametrics > Mann-Whitney. Python mirror: scipy.stats
ttest_ind (equal_var=False for Welch), ttest_rel, f_oneway, levene —
the exact calls are in `key.md`, all values exit-checked against the
seed 42191-42193 datasets.
