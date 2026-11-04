#!/usr/bin/env python3
"""Module 09 court — re-derives every number in the module 09 README/solution-key
from data/bore-baseline-100.csv (adjudicated spine sigma 0.007407) and the seeded
CLT simulations. Exit 0 = all derivations match; exit 1 = mismatches printed."""
import csv, sys, random, statistics
from math import erf, sqrt

import os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

def Phi(z): return 0.5*(1+erf(z/sqrt(2)))
def cdf(xx, m, sd): return 0.5*(1+erf((xx-m)/(sd*sqrt(2))))

# dataset regenerates byte-exact from its stated seed
random.seed(42008)
vals = [random.gauss(12.009, 0.007407) for _ in range(100)]
gen = "observation,bore_diameter_mm\n" + "".join(f"{i+1},{v:.4f}\n" for i, v in enumerate(vals))
if gen != open(os.path.join(ROOT, 'data/bore-baseline-100.csv')).read():
    FAILS.append("bore-baseline-100.csv does not regenerate byte-exact from seed 42008 @ sigma 0.007407")

x = [float(r['bore_diameter_mm']) for r in csv.DictReader(open(os.path.join(ROOT, 'data/bore-baseline-100.csv')))]
mean = sum(x)/len(x); s = statistics.stdev(x); srt = sorted(x)
def pct(d, p):
    k = (len(d)+1)*p; fl = int(k); fr = k-fl
    return d[fl-1] + fr*(d[fl]-d[fl-1])
q1, q3 = pct(srt, 0.25), pct(srt, 0.75)
iqr = q3 - q1
lo, hi = q1 - 1.5*iqr, q3 + 1.5*iqr
outl = sorted(v for v in x if v < lo or v > hi)

check('mean_full', round(mean, 6), 12.009815)
check('median', statistics.median(x), 12.00995)
check('s_full', round(s, 6), 0.007417)
check('Q1', round(q1, 4), 12.0059)
check('Q3', round(q3, 4), 12.0146)
check('IQR', round(iqr, 6), 0.008725)
check('fences', (round(lo, 4), round(hi, 4)), (11.9928, 12.0277))
check('outliers', outl, [11.9849, 11.9907, 11.9909, 12.0293])
check('oos', sorted(v for v in x if v < 11.975 or v > 12.025), [12.0293])
check('P_below_LSL_centered', round(cdf(11.975, 12.000, 0.0074), 12), round(0.0003645733881142421, 12), 1e-12)
check('P_below_LSL_measured', round(cdf(11.975, mean, 0.0074), 12), round(1.2710124089876373e-06, 12), 1e-12)
check('P_above_USL_measured', round(1-cdf(12.025, mean, 0.0074), 12), round(0.02008351793902119, 12), 1e-12)

random.seed(42009)
means = [sum(random.gauss(12.009, 0.007407) for _ in range(5))/5 for _ in range(1000)]
check('clt_mean_of_means', round(statistics.mean(means), 4), 12.0089)
check('clt_sd_mm', round(statistics.stdev(means), 6), 0.003406)
check('clt_theory_um', round(0.007407/sqrt(5)*1000, 3), 3.313)

random.seed(42010)
bm = [statistics.mean(random.choices(x, k=5)) for _ in range(1000)]
check('resample_mean', round(statistics.mean(bm), 4), 12.0097)
check('resample_sd_um', round(statistics.stdev(bm)*1000, 3), 3.386)

if FAILS:
    print("MODULE 09 COURT FAIL")
    for f in FAILS: print(" -", f)
    sys.exit(1)
print("MODULE 09 COURT PASS (1 dataset-regen + 16 numeric derivations, exit 0)")
