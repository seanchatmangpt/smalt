# Module 19 — Solution Key (python3-derived, exit-checked)

Re-derive everything from `data/bore-30.csv` (seed 42190). Generator script
exit-checked 2026-11-04; scipy 1.17.1, numpy 2.4.4.

```python
import csv, math
import numpy as np
from scipy import stats

rows = list(csv.DictReader(open("data/bore-30.csv")))
x = np.array([float(r["bore_mm"]) for r in rows])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
t = (xb - 12.000)/se; df = n-1
tcrit = stats.t.ppf(0.975, df)
p = 2*(1 - stats.t.cdf(abs(t), df))
```

## 1-sample t (H0: mu = 12.000, alpha = 0.05, two-sided)

| quantity | value |
|---|---|
| n | 30 |
| x-bar | 12.0072 mm |
| s | 0.0035 mm |
| SE | 0.0006 mm |
| t | **11.197** |
| critical t(0.975, df=29) | 2.045 |
| p-value | **4.78e-12** |
| decision | **reject H0** (t > tcrit) |
| 95% CI for mu | (12.0059, 12.0085) mm |

## Power derivation (running-case constants, sigma = 7.407 um, post-adjudication 2026-11-04)

```python
from scipy import stats; import math
za = stats.norm.ppf(0.975)      # 1.9600
zb = stats.norm.ppf(0.80)       # 0.8416
n_raw = ((za + zb) * 7.407 / 5.0)**2   # 17.22
n = math.ceil(n_raw)                  # 18
def power(n, delta=5.0, sigma=7.407):
    ncp = delta/(sigma/math.sqrt(n))
    return 1 - stats.norm.cdf(za - ncp) + stats.norm.cdf(-za - ncp)
```

- z_{1-alpha/2} = 1.9600, z_{0.80} = 0.8416, n_raw = 17.22 → **n = 18**
- power(18) = 0.817 (>= 0.80); power(17) = 0.795 (< 0.80)
- curve: n=2:0.159 3:0.215 4:0.271 5:0.326 6:0.380 7:0.431 8:0.480
  10:0.569 12:0.647 15:0.744 18:0.817 20:0.855 25:0.921
- tradeoff table (delta, n) -> power/beta: (2um,18)0.209/0.791
  (2um,30)0.316/0.684 (2um,50)0.480/0.520 (3um,18)0.405/0.595
  (3um,30)0.602/0.398 (3um,50)0.817/0.183 (5um,18)0.817/0.183
  (5um,30)0.959/0.041 (5um,50)0.998/0.002

## Cross-check vs the running-case baseline

The sample (12.0072 ± 0.0035) sits between the Measure-phase mu = 12.009 and
nominal — consistent with a partial re-centering. It does NOT match the
pinned baseline exactly and must not be forced to: it is a distinct seeded
sample from a post-setup-change line. Coherence court note: the baseline
pair is adjudicated as (Cpk = 0.72, sigma = 7.407 um) — ADJUDICATED
2026-11-04, see RUNNING-CASE.md and the MANIFEST cross-module note.
