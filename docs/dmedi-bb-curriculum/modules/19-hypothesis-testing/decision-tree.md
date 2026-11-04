# Test-Selection Decision Tree (flagship)

One tree. Every hypothesis test taught anywhere in the curriculum (modules
09-45) appears on it; no test without a path from the top. Printable,
Minitab-testable (module 08 vocabulary).

## The tree

```
Q1. Response type?
    A. CONTINUOUS (bore mm, Ra um, lead-time days) ............ go to Q2
    B. ONE PROPORTION vs a target (scrap rate vs 5%) .......... 1-proportion z
    C. ONE CATEGORICAL distribution vs an expected one
       (binned normality of bore) ............................ chi-square GOF
    D. TWO CATEGORICAL variables, association?
       (defect class x machine) .............................. chi-square
                                                               independence
Q2. (continuous response) One population or more?
    ONE population, mean vs target mu0 ........................ go to Q3
    TWO populations
      paired observations (same part, before/after feed) ...... paired t
      independent samples
        question is about MEDIANS (nonnormal, outlier-heavy) .. Mann-Whitney U
        question is about MEANS ............................... go to Q4
    THREE OR MORE groups (coolant 5% / 8% / 12%) .............. one-way ANOVA

Q3. Is sigma known (Measure-phase capability, sigma = 7.407 um)?
    sigma known ............................................... 1-sample z
    sigma estimated from the sample ........................... 1-sample t

Q4. Equal variances?  Pre-test with Levene (median-centered, robust).
    Bartlett only if normality is established (sensitive to nonnormality).
    variances equal ........... 2-sample t, pooled
    variances unequal ......... 2-sample t, Welch (Satterthwaite df)

Q5. (continuous response) Model-building question rather than a group
    comparison?
    one continuous X (tool life -> bore dev) .................. simple OLS;
      overall significance via the regression F-test ....... M23 S7
    several continuous Xs (tool life + speed + temp -> Ra) ... multiple OLS;
      reduced-model F-test drops a useless predictor ....... M24 §6
    two categorical FACTORS (machine x coating) ............... two-way ANOVA;
      check the INTERACTION row first ....................... M28
    factorial + center points: is the plane flat? ............. center-point
      curvature test = 2-sample t, corner mean vs center mean . M37
      (reuses the Q4 2-sample t path on constructed means)
```

**Pre-tests.** Normality before any variance/parametric claim: Anderson-Darling
(M09 §normality, M12 lab Step 2 — it gates the Box-Cox transformation
decision). Variance homogeneity before pooling: Levene/Bartlett (Q4).
Normality is also the chi-square GOF route (Q1-C) done with bins.

**Estimation branch (Q1-E).** Every rejecting test above has a CI twin stating
the effect size; a non-rejecting test has a CI bounding how big the effect
could still be (M20). Marginal-CI overlap decides nothing (M20 §4).
```

## Every test, with its path and its CPPC anchor

| # | path | test | taught in | running-case anchor | dataset |
|---|---|---|---|---|---|
| 1 | Q1-A→Q2→ONE→Q3 (sigma known) | 1-sample z | M19 §5a | bore vs nominal w/ Measure sigma | bore-30.csv |
| 1b | Q1-A→Q2→ONE→Q3 (sigma unknown) | 1-sample t | M19 §5 | bore-30.csv (seed 42190) | bore-30.csv |
| 2 | Q1-A→Q2→TWO→paired | paired t | M21 §3 | before/after feed change | paired-feed.csv (seed 42192) |
| 3 | Q1-A→Q2→TWO→indep→medians | Mann-Whitney U | M21 §5 | coating A vs B medians | coating-ab-bore.csv (seed 42191) |
| 4 | Q1-A→Q2→TWO→indep→means→Q4 equal | 2-sample t pooled | M21 §2 | coating A vs B means | coating-ab-bore.csv |
| 4b | Q1-A→Q2→TWO→indep→means→Q4 unequal | 2-sample t Welch | M21 §2b | coating A vs B means | coating-ab-bore.csv |
| 4c | Q4 pre-test | Levene | M21 §4 | A vs B variance check | coating-ab-bore.csv |
| 4d | Q4 pre-test (normal case) | Bartlett | M21 §4 | A vs B variance check | coating-ab-bore.csv |
| 5 | Q1-A→Q2→3+ groups | one-way ANOVA | M21 §6 | coolant 5/8/12% | coolant-anova.csv (seed 42193) |
| 6 | Q1-B | 1-proportion z | M22 §2 | scrap vs 5% target | scrap-shifts.csv (seed 42194) |
| 7 | Q1-B (two rates) | 2-proportion z | M22 §3 | CNC-3 vs CNC-4 | cnc-ab.csv (seed 42195) |
| 8 | Q1-C | chi-square GOF | M22 §5 | binned normality of bore | bore-100-gof.csv (seed 42197) |
| 9 | Q1-D | chi-square independence | M22 §4 | defect class × machine | defect-machine.csv (seed 42196) |
| 10 | Q1-A pre-test | Anderson-Darling normality | M09 §normality, M12 lab | bore baseline normality probe | data/bore-baseline-100.csv (seed 42008); flatness-lognormal.csv (M12 Box-Cox gate) |
| 11 | Q1-A→Q5 model branch | regression F-test (overall / reduced-model) | M23 S7, M24 §6 | tool life -> bore dev; multi-X Ra model | regression-simple.csv (seed 42301); regression-multi.csv |
| 12 | Q1-A→Q5, 2 categorical factors | two-way ANOVA (interaction first) | M28 | machine × coating on bore | anova-2way.csv (seed 28) |
| 12b | Q1-A→Q5 factorial + center points | center-point curvature test (2-sample t on corner vs center means) | M37 | 2^k factorial plane flatness | bore-curvature.csv (seed 37001) |
| E | Q1-E estimation twin of rows 1-9 | CI for the difference / paired CI | M20 | any rejecting test's effect size | ci-trap-overlap.csv (M20) |

## Completeness court

The table is the check: 18 rows, every hypothesis test taught anywhere in the
curriculum on the tree, one path from Q1 (or an explicit pre-test/estimation
row), one anchor dataset each. Every test taught in M19-M22 appears; every
test taught downstream (M23-M24 F-tests, M28 two-way ANOVA, M37 curvature,
M09/M12 Anderson-Darling) now appears with its path and module cross-ref. No
test appears without a path from the top. Modules 20-22 each close with a
pointer back here, and each module's worked tests are located on the tree by
row number.
