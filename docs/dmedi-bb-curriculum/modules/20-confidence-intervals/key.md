# Module 20 — Solution Key (python3-derived, exit-checked)

Datasets: `data/bore-30.csv` (seed 42190, shared with M19);
`data/ci-trap-overlap.csv` (seed 42290, 30 paired-column rows).

```python
import csv, math
import numpy as np
from scipy import stats
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(open("data/bore-30.csv"))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
for c in (0.90, 0.95, 0.99):
    print(c, stats.t.interval(c, n-1, loc=xb, scale=se))
```

## bore-30 CIs (df = 29, t(0.975,29) = 2.045)

| level | CI (mm) |
|---|---|
| 90% | (12.0061, 12.0083) |
| 95% | (12.0059, 12.0085) — excludes 12.000 ⇒ matches M19 rejection |
| 99% | (12.0054, 12.0090) |

## Trap dataset (seed 42290), pooled 2-sample t

```python
rows = list(csv.DictReader(open("data/ci-trap-overlap.csv")))
t1 = np.array([float(r["spindle1_mm"]) for r in rows])
t2 = np.array([float(r["spindle2_mm"]) for r in rows])
m1, m2 = t1.mean(), t2.mean()
s1, s2 = t1.std(ddof=1), t2.std(ddof=1)
c1 = stats.t.interval(0.95, 29, loc=m1, scale=s1/math.sqrt(30))
c2 = stats.t.interval(0.95, 29, loc=m2, scale=s2/math.sqrt(30))
t, p = stats.ttest_ind(t1, t2, equal_var=True)
```

- Spindle 1: x-bar = 12.0032, s = 0.0013, 95% CI (12.0027, 12.0036)
- Spindle 2: x-bar = 12.0022, s = 0.0023, 95% CI (12.0013, 12.0030)
- overlap region (12.0027, 12.0030) = 36% of the narrower CI's width
- t = **2.062**, df = 58, tcrit = 2.002, **p = 0.0437** → reject H0
- 95% CI of difference: **(0.0000, 0.0019)** — excludes 0
- Trap verified: CIs overlap AND the test rejects.

## Paired vice-versa (paired-feed.csv, seed 42192; full key in M21)

- marginal 95% CIs: before (12.0057, 12.0091), after (12.0027, 12.0062) — overlap
- paired t = -6.924, df = 24, **p = 3.68e-7** → reject
- CI of differences: (-0.0039, -0.0021) — excludes 0
- Trap verified both directions; rule: decide from the difference's CI, never
  from marginal overlap.
