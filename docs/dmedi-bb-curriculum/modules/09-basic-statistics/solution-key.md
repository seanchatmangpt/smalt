# Module 09 — Solution Key

Dataset: `data/bore-baseline-100.csv` (seed 42008, adjudicated spine sigma 0.007407).
All statistics re-derive from the CSV as stored; seeds make the simulations replay
digit-for-digit.

## Re-derivation script

```python
import csv, statistics, math, random
from math import erf, sqrt

rows = list(csv.DictReader(open('data/bore-baseline-100.csv')))
x = [float(r['bore_diameter_mm']) for r in rows]
mean = sum(x)/len(x); s = statistics.stdev(x)
srt = sorted(x)
def pct(d, p):
    k = (len(d)+1)*p; fl = int(k); fr = k-fl
    return d[fl-1] + fr*(d[fl]-d[fl-1])
q1, q3 = pct(srt,0.25), pct(srt,0.75)
iqr = q3-q1
lo, hi = q1-1.5*iqr, q3+1.5*iqr
outl = sorted(v for v in x if v < lo or v > hi)
def cdf(xx, m, sd): return 0.5*(1+erf((xx-m)/(sd*sqrt(2))))
print('mean', round(mean,6), 'median', statistics.median(x), 's', round(s,6))
print('Q1', round(q1,4), 'Q3', round(q3,4), 'IQR', round(iqr,6))
print('fences', round(lo,4), round(hi,4), 'outliers:', outl)
print('bores outside spec:', sorted(v for v in x if v < 11.975 or v > 12.025))
print('P(below LSL | centered) =', cdf(11.975, 12.000, 0.0074))
print('P(below LSL | measured) =', cdf(11.975, mean, 0.0074))
print('P(above USL | measured) =', 1-cdf(12.025, mean, 0.0074))

# CLT lab: 1000 samples of n=5 from the baseline PROCESS (seed 42009)
random.seed(42009)
mu, sigma = 12.009, 0.007407
means = [sum(random.gauss(mu, sigma) for _ in range(5))/5 for _ in range(1000)]
print('CLT sim: mean of means', round(statistics.mean(means),4),
      'sd of means (mm)', round(statistics.stdev(means),6),
      '= um', round(statistics.stdev(means)*1000,3))
print('theory sigma/sqrt5 um =', round(sigma/math.sqrt(5)*1000,3))

# Variant: resample n=5 WITH replacement from the stored CSV (seed 42010)
random.seed(42010)
bm = [statistics.mean(random.choices(x, k=5)) for _ in range(1000)]
print('CSV resample: mean', round(statistics.mean(bm),4),
      'sd um', round(statistics.stdev(bm)*1000,3))
```

**Verified output** (python3):

```
mean 12.009815 median 12.00995 s 0.007417
Q1 12.0059 Q3 12.0146 IQR 0.008725
fences 11.9928 12.0277 outliers: [11.9849, 11.9907, 11.9909, 12.0293]
bores outside spec: [12.0293]
P(below LSL | centered) = 0.0003645733881142421
P(below LSL | measured) = 1.2710124089876373e-06
P(above USL | measured) = 0.02008351793902119
CLT sim: mean of means 12.0089 sd of means (mm) 0.003406 = um 3.406
theory sigma/sqrt5 um = 3.313
CSV resample: mean 12.0097 sd um 3.386
```

## Reading the output

1. **Center statistic**: median 12.00995 vs mean 12.009815 — near-identical, the
   sample is symmetric; Minitab's Anderson-Darling p > 0.05 confirms the normal model
   is defensible.
2. **Tukey fences** 11.9928 / 12.0277 flag 4 of 100 bores (11.9849, 11.9907, 11.9909,
   12.0293). Three are legal low tails; **12.0293 is also out of spec** (USL 12.025) —
   the one scrap part that makes the Cpk-0.72 baseline visible. Keep and disposition,
   never delete without a measurement-system reason (Module 11).
3. **Normal gallery probes**: centered process → LSL tail 3.65e-4. The measured
   off-center mean → LSL tail ~1.3e-6 but **USL tail ~2.0e-2** (about 2 bores in 100
   over USL from the binding side — matching the observed scrap rate). At Cpk 0.72
   centering alone is NOT free capability: it rebalances the tails, but the centered
   process still has ~7.5e-4 outside spec from spread alone — variation reduction is
   required alongside centering (Module 12 carries that arithmetic).
4. **CLT**: simulated sd of means 3.406 um vs theory 3.313 um (+2.8%); the CSV
   resample variant gives 3.386 um (+2.2%). Both within the ±3% honesty bar; the
   residual gap is Monte Carlo sampling error on 1000 draws, not an error.
   sigma_xbar = sigma/sqrt(n) is numerically recovered: 7.407 um → 3.31 um at n=5.

## Why X-bar limits are tighter than I-chart limits (gate answer)

Because an average of 5 washes out individual variation by sqrt(5): the thing the
X-bar chart watches moves with sd ≈ 3.31 um while individuals move with 7.41 um.
Same 3-sigma multiple, different sigma — so identical limit widths on the two charts
would be comparing different processes. Module 10 makes this exact arithmetic visible
via the A2·Rbar constants.

## Exercise answers (exercises.md)

1. Mean: capability ratios and z-scores are defined against sigma under the normal
   model; the mean estimates its center with minimum variance under symmetry
   (median ≈ mean here confirms symmetry). Replace with the median under skew or
   outliers — or transform the data (Module 12).
2. Fences 11.9928 / 12.0277 (IQR 0.008725); four bores flagged (11.9849, 11.9907,
   11.9909, 12.0293); one of them (12.0293) is ALSO outside spec — fence flag and
   spec violation are different verdicts.
3. Direction only: deleting tail values shrinks s (the tails contribute most to the
   sum of squares), so capability would be *overstated* — the classic clean-up bias.
   Worse here: deleting 12.0293 would erase the only visible scrap evidence. Fence
   flags are investigation triggers, not deletion triggers.
4. P(below LSL) = Φ((11.975 − 12.000)/0.0074) = **3.65e-4**.
5. P(below LSL) ≈ 1.27e-6; P(above USL) = **2.01e-2**. The USL binds: the mean moved
   toward it. Centering rebalances the tails (LSL side ~1.3e-6), but at this spread
   the centered two-sided fraction is still ~7.5e-4 — variation reduction is required
   alongside centering.
6. Prediction 7.407/√5 = 3.313 um. Simulated: 3.406 um (seed 42009, +2.8%);
   3.386 um (seed 42010 CSV resample, +2.2%).
7. Because the chart watches subgroup averages, whose sd is sigma/√n, not sigma:
   3.31 um vs 7.41 um at n = 5, so the same 3-sigma multiple yields tighter limits.
8. Because 1000 draws give ~2–3% Monte Carlo error (the two stated seeds produce
   +2.8% and +2.2% deviations); an exact match to theory means the simulation is not
   actually simulating — a seeded bug, peeked answer, or analytic value pasted as a
   Monte Carlo result.
