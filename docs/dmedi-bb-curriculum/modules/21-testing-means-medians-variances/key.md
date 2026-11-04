# Module 21 — Solution Key (python3-derived, exit-checked)

All numbers re-derive from the raw CSVs; generator exit-checked 2026-11-04
(scipy 1.17.1).

```python
import csv, math
import numpy as np
from scipy import stats

rows = list(csv.DictReader(open("data/coating-ab-bore.csv")))
A = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "A"])
B = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "B"])
```

## §2 pooled 2-sample t (coating A vs B)

| quantity | value |
|---|---|
| meanA / sA (n=30) | 12.0061 / 0.0041 |
| meanB / sB (n=30) | 12.0016 / 0.0043 |
| pooled sp | 0.0042 |
| t | **4.187** |
| tcrit(0.975, df=58) | 2.002 |
| p | **9.72e-5** |
| decision | reject H0 |

## §2b Welch

t = 4.187, df (Satterthwaite) = 57.8, p = 9.75e-5 → reject.

## §3 paired t (paired-feed.csv, seed 42192)

```python
rows = list(csv.DictReader(open("data/paired-feed.csv")))
before = np.array([float(r["before_mm"]) for r in rows])
after  = np.array([float(r["after_mm"]) for r in rows])
d = after - before
```

| quantity | value |
|---|---|
| d-bar | -0.0030 mm (-3.0 um) |
| s_d | 0.0022 |
| t | **-6.924** (df = 24, tcrit = 2.064) |
| p | **3.68e-7** |
| 95% CI of d | (-0.0039, -0.0021) |
| decision | reject H0 |
| (contrast) unpaired t on same data | t = 2.508, p = 0.0156 |

## §4 Levene / Bartlett (A vs B)

| test | statistic | df | p | verdict |
|---|---|---|---|---|
| Levene (median-centered) | W = 0.053 | (1, 58) | 0.819 | equal variances OK |
| Bartlett | K^2 = 0.086 | 1 | 0.770 | same verdict |

## §5 Mann-Whitney U

U = **726**, two-sided p = **4.62e-5** → reject (agrees with the t).

## §6 one-way ANOVA (coolant-anova.csv, seed 42193)

```python
g = {p: [] for p in ("5", "8", "12")}
for r in csv.DictReader(open("data/coolant-anova.csv")):
    g[r["coolant_pct"]].append(float(r["bore_mm"]))
F, p = stats.f_oneway(*(np.array(v) for v in g.values()))
```

| source | SS | df | MS | F | p |
|---|---|---|---|---|---|
| coolant | 0.00044544 | 2 | 0.00022272 | **12.850** | **0.00012** |
| error | 0.00046799 | 27 | 0.00001733 | | |
| total | 0.00091343 | 29 | | | |

- F crit(0.95; 2, 27) = 3.354 → reject H0
- means: 5% = 12.0081, 8% = 12.0069, 12% = 11.9993; grand = 12.00476
- pairwise MSW-based t CIs (df = 27, tcrit = 2.052):
  5%-8%: 0.0012 (-0.0026, 0.0050) ns; 5%-12%: 0.0087 (0.0049, 0.0125) sig;
  8%-12%: 0.0075 (0.0037, 0.0113) sig
