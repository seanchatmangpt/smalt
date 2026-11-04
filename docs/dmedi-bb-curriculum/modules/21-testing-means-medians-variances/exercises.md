# Module 21 Exercises — Tests on Means, Medians, Variances

All exercises re-derive from the module datasets (seeds 42191 coating,
42192 paired, 42193 coolant — all registered in `datasets/MANIFEST.md`).
Every number you report must come from an executed computation (snippet in
`keys/solution-key.md` or your own scipy code).

Run from the curriculum root (levene/f_oneway warm-up, uses coating data):

```
python3 - <<'EOF'
import csv
import numpy as np
from scipy import stats
rows = list(csv.DictReader(open(
    "modules/21-testing-means-medians-variances/data/coating-ab-bore.csv")))
A = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "A"])
B = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "B"])
print(round(stats.levene(A, B, center="median").pvalue, 3),
      round(stats.ttest_ind(A, B).pvalue * 1e5, 2))
EOF
```

1. **E1 — Levene gate first.** On coating A vs B (30 parts each): compute
   Levene W and p (median-centered) and Bartlett K-squared and p. Confirm
   W = 0.053, p = 0.819 (keep H0 of equal variances) and state why the
   pooled t is lawful here and would be unlawful if Levene fired.
2. **E2 — Pooled vs Welch.** Compute meanA/meanB, sA/sB, pooled sp, the
   pooled t (expect 4.187, df = 58, p = 9.72e-5), then Welch t, df, and p
   (expect 4.187, df = 57.8, p = 9.75e-5). State the process decision:
   which coating would you pick as the Improve-phase centering lever and
   why (README §2).
3. **E3 — Paired t + the 400x contrast.** On `data/paired-feed.csv` (25
   parts before/after a feed change): compute d-bar, s_d, paired t
   (expect -6.924, df = 24, p = 3.68e-7), the difference CI (-0.0039,
   -0.0021); then run the same data as an independent 2-sample t
   (expect t = 2.508, p = 0.0156). Compute the p-ratio and explain why
   pairing removes part-to-part variance.
4. **E4 — Mann-Whitney U.** On coating A vs B: compute U and the two-sided
   p (expect U = 726, p = 4.62e-5). State the decision-tree path that
   forces this test and what it buys (robustness, not power).
5. **E5 — One-way ANOVA.** On `data/coolant-anova.csv` (3 levels x 10
   parts): compute SSB/SSW/SST, df, MS, F (expect 12.850), Fcrit(0.95,
   2, 27) = 3.354, p; group means (12.0081 / 12.0069 / 11.9993); then the
   MSW-based pairwise CIs. Which contrasts reject, and what is the process
   read (12% coolant centers the process on nominal)?
6. **E6 — Tree-placement exit check.** Place all five tests of this module
   (1-sample t, pooled/Welch, paired, Mann-Whitney, ANOVA) plus the
   Levene/Bartlett gate on `../19-hypothesis-testing/decision-tree.md`
   from scenario text alone — no notes. If a test has no path, you do not
   know when to use it.

## Timing (per exercise)

E1-E2: 15 min each; E3: 20 min; E4-E5: 15 min each; E6: 10 min. Total
~90 min, consistent with the README session timing.
