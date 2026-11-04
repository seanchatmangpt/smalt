# Module 22 — Solution Key (python3-derived, exit-checked)

```python
import csv, math
import numpy as np
from scipy import stats
```

## §2 1-proportion z (scrap-shifts.csv, seed 42194)

```python
rows = list(csv.DictReader(open("data/scrap-shifts.csv")))
x = sum(int(r["scrapped"]) for r in rows); n = sum(int(r["inspected"]) for r in rows)
ph = x/n; z = (ph - 0.05)/math.sqrt(0.05*0.95/n)
p_one = 1 - stats.norm.cdf(z)
```

| quantity | value |
|---|---|
| x / n | 193 / 2500 |
| p-hat | 0.0772 |
| z | **6.240** |
| zcrit one-sided (0.95) / two-sided (0.975) | 1.645 / 1.960 |
| p one-sided / two-sided | 2.19e-10 / 4.37e-10 |
| decision | **reject H0** (scrap ≈ 7.7% > 5%) |
| 95% CI Wald | (0.0667, 0.0877) |
| 95% CI Clopper-Pearson exact | (0.0670, 0.0884) |

## §3 2-proportion z (cnc-ab.csv, seed 42195)

```python
rows = list(csv.DictReader(open("data/cnc-ab.csv")))
x3, n3 = int(rows[0]["defective"]), int(rows[0]["inspected"])
x4, n4 = int(rows[1]["defective"]), int(rows[1]["inspected"])
pp = (x3 + x4)/(n3 + n4)
z = (x3/n3 - x4/n4)/math.sqrt(pp*(1 - pp)*(1/n3 + 1/n4))
p = 2*(1 - stats.norm.cdf(abs(z)))
```

| quantity | value |
|---|---|
| CNC-3 | 25/320 = 0.0781 |
| CNC-4 | 30/310 = 0.0968 |
| pooled p-bar | 55/630 = 0.0873 |
| z | **-0.829** |
| zcrit(0.975) | 1.960 |
| p (two-sided) | **0.407** |
| decision | **fail to reject** |
| 95% CI diff (unpooled) | (-0.0628, 0.0255) |

## §4 chi-square independence (defect-machine.csv, seed 42196)

```python
tab = np.array([[53,35,49],[43,28,21],[36,44,22],[38,51,60]])
chi2, p, dof, exp = stats.chi2_contingency(tab)
```

| quantity | value |
|---|---|
| chi2 | **23.389** |
| df | (4-1)(3-1) = 6, crit(0.95) = 12.592 |
| p | **0.00068** |
| decision | reject H0 — defect mix depends on machine |
| largest contributions | burrs/CNC-1 = 4.13, oversize/CNC-1 = 3.33, porosity/CNC-2 = 3.24, burrs/CNC-3 = 3.48 |
| expected counts min | 29.1 (>= 5, approximation lawful) |

## §5 chi-square GOF (bore-100-gof.csv, seed 42197)

```python
x8 = np.array([float(r["bore_mm"]) for r in csv.DictReader(open("data/bore-100-gof.csv"))])
m, s = x8.mean(), x8.std(ddof=1)
edges = [stats.norm.ppf(i/8, loc=m, scale=s) for i in range(1, 8)]
obs, _ = np.histogram(x8, bins=[-np.inf] + edges + [np.inf])
chi2 = float(((obs - 12.5)**2 / 12.5).sum())
p = 1 - stats.chi2.cdf(chi2, 5)
```

| quantity | value |
|---|---|
| n, x-bar, s | 100, 12.0092, 0.0042 |
| chi2 | **1.920** |
| df | 8 - 1 - 2 = 5, crit(0.95, 5) = 11.070 |
| p | **0.860** |
| decision | fail to reject normality |
