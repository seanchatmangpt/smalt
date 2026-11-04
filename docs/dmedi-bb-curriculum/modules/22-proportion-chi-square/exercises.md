# Module 22 Exercises — Proportions and Chi-Square

All exercises re-derive from the module datasets (seeds 42194-42197, all
registered in `datasets/MANIFEST.md`). Every number you report must come
from an executed computation (snippet in `keys/solution-key.md` or your own
scipy code).

Run from the curriculum root (np0 >= 5 warm-up for the scrap z):

```
python3 - <<'EOF'
import csv, math
from scipy import stats
import numpy as np
rows = list(csv.DictReader(open(
    "modules/22-proportion-chi-square/data/scrap-shifts.csv")))
x = sum(int(r["scrapped"]) for r in rows)
n = sum(int(r["inspected"]) for r in rows)
ph = x/n
z = (ph - 0.05)/math.sqrt(0.05*0.95/n)
print(x, n, round(ph,4), 0.05*n, 0.95*n, round(z,3),
      f"{1-stats.norm.cdf(z):.2e}")
EOF
```

1. **E1 — np0 >= 5 law first.** On `data/scrap-shifts.csv` (10 shifts x 250
   inspected): compute x, n, p-hat and verify np0 = 125 >= 5 and
   n(1-p0) = 2375 >= 5 (normal approximation lawful). Then the 1-prop z:
   expect z = 6.240, zcrit(0.95, one-sided) = 1.645, p(one-sided) = 2.19e-10
   → reject H0: p = 0.05. State why zcrit = 1.645 here but 1.960 in
   M19/M20 (sidedness must match the declaration).
2. **E2 — Two CI forms.** Same data: Wald (0.0667, 0.0877) and exact
   Clopper-Pearson (0.0670, 0.0884). Which is wider and why does the exact
   interval exist at all (Wald degrades at extreme p or small n)?
3. **E3 — Deliberate non-rejection.** On `data/cnc-ab.csv`: CNC-3 25/320,
   CNC-4 30/310. Compute p-bar, the two-prop z (expect -0.829, p = 0.407 →
   FAIL to reject), and the unpooled difference CI (-0.0628, 0.0255). State
   what failure to reject does NOT mean (not "the machines are equal" — the
   CI admits differences up to 6.3 points) and the remedy (n, per the M19
   power law).
4. **E4 — Expected counts by hand.** On `data/defect-machine.csv` (N = 480):
   compute E(scratch, CNC-1) = 137*170/480 = 48.5 by hand, verify
   min expected count 29.1 >= 5 (chi-square lawful, no pooling), then run
   the independence test: expect chi2 = 23.389, df = 6, crit = 12.592,
   p = 0.00068 → reject. Which cells drive it (contributions: burrs/CNC-1
   4.13, oversize/CNC-1 3.33, porosity/CNC-2 3.24, burrs/CNC-3 3.48) and
   the machine-specific maintenance read?
5. **E5 — GOF + the df penalty.** On `data/bore-100-gof.csv` (n = 100,
   x-bar = 12.0092, s = 0.0042): bin into 8 equal-probability bins cut at
   the normal quantiles of (x-bar, s), expected 12.5/bin; expect chi2 =
   1.920, df = k-1-2 = 5 (TWO parameters estimated — claiming df = 7 is
   the classic lost-points error), crit = 11.070, p = 0.860 → fail to
   reject: no evidence against normality.
6. **E6 — Tree-placement exit check.** Place all four attribute tests
   (1-prop z, 2-prop z, chi-square independence, chi-square GOF) on
   `../19-hypothesis-testing/decision-tree.md` from scenario text alone.

## Timing (per exercise)

E1-E2: 12 min each; E3-E5: 15 min each; E6: 6 min. Total ~75 min,
consistent with the README session timing.
