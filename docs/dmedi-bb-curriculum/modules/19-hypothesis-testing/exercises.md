# Module 19 Exercises — Hypothesis Testing

All exercises re-derive from `data/bore-30.csv` (seed 42190, registered in
`datasets/MANIFEST.md`). Every number you report must come from an executed
computation (python3 snippet in `keys/solution-key.md`, or your own scipy
code) — never from the README tables. Incantation:

```
python3 - <<'EOF'
import csv, math
import numpy as np
from scipy import stats
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(
    open("modules/19-hypothesis-testing/data/bore-30.csv"))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
t = (xb - 12.000)/se
print(n, round(xb,4), round(s,4), round(t,3),
      round(stats.t.ppf(0.975,29),3), f"{2*(1-stats.t.cdf(abs(t),29)):.3e}")
EOF
```

1. **E1 — H0/H1 formulation drill.** Line 2 got a setup change; anything off
   12.000 mm either way forces re-mastering. Write H0/H1 in parameters,
   choose sidedness and alpha = 0.05 BEFORE computing anything, and justify
   sidedness from the action (README §2 laws 1-4). Then compute n, x-bar, s,
   t, tcrit(0.975, 29), and p by executing the snippet above.
2. **E2 — Decision + consequence.** Using E1's executed output, state the
   reject/keep decision vs tcrit and p < 0.05, then the CPPC consequence in
   the README §3 table's terms (re-master ~2 h + $900 vs shipping an
   off-target bore). Explain why "12.0072 is within the ±25 um tolerance"
   is NOT a defense.
3. **E3 — sigma-known cross-check.** Re-run the same H0 as a 1-sample z with
   the Measure-phase sigma = 7.407 um treated as known (README §5a): compute
   z and its two-sided p. Confirm z = 5.32 and that the decision matches the
   t. Explain when the z variant is lawful (capability sigma from a large
   study) and why s = 0.0035 < 0.007407 makes t the honest choice.
4. **E4 — Power / sample size.** From the normal-approximation law
   n = [(z_{1-alpha/2} + z_{1-beta}) * sigma / delta]^2 with sigma = 7.407 um,
   delta = 5 um, alpha = 0.05, 80% power: verify n_raw = 17.22 → n = 18 by
   hand, then execute the power-curve snippet in `keys/solution-key.md` to
   reproduce the n = 2..25 curve and confirm power(17) = 0.795 misses the
   80% bar while power(18) = 0.817 clears it.
5. **E5 — alpha/beta tradeoff.** From the delta-in {2, 3, 5} um x n-in
   {18, 30, 50} table (re-derive one cell by hand, check the rest): why is
   the same n = 18 plan nearly blind (beta = 0.79) to a 2 um drift, and what
   does that imply for sizing a control-plan sample (size n to the smallest
   shift with real consequence)?
6. **E6 — Decision-tree placement.** Place the 1-sample t (E1) and the
   sigma-known z (E3) on `decision-tree.md` paths, and state the exit rule:
   no test without a tree path.

## Timing (per exercise)

E1-E2: 15 min each; E3-E5: 10-15 min each; E6: 5 min. Total ~70 min,
consistent with the README session timing (80 min incl. briefing).
