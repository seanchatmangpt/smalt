#!/usr/bin/env python3
"""Module 08 court — re-derives every number in the module 08 README/solution-key
from data/bore-baseline-100.csv (adjudicated spine sigma 0.007407), plus byte-exact
seed regeneration of the lane-04 datasets. Exit 0 = all derivations match;
exit 1 = mismatches printed."""
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

# --- dataset integrity: byte-exact seed regeneration (data provenance law) ---
random.seed(42008)
vals = [random.gauss(12.009, 0.007407) for _ in range(100)]
gen = "observation,bore_diameter_mm\n" + "".join(f"{i+1},{v:.4f}\n" for i, v in enumerate(vals))
if gen != open(os.path.join(ROOT, 'data/bore-baseline-100.csv')).read():
    FAILS.append("bore-baseline-100.csv does not regenerate byte-exact from seed 42008 @ sigma 0.007407")

random.seed(42011)
rows2 = ["subgroup,sample1,sample2,sample3,sample4,sample5"]
for sg in range(25):
    shift = 0.015 if 18 <= sg+1 <= 20 else 0.0
    rows2.append(f"{sg+1}," + ",".join(f"{random.gauss(12.009,0.007407)+shift:.4f}" for _ in range(5)))
if "\n".join(rows2) + "\n" != open(os.path.join(ROOT, 'data/xbar-r-subgroups.csv')).read():
    FAILS.append("xbar-r-subgroups.csv does not regenerate byte-exact from seed 42011 @ sigma 0.007407, +0.015 shift subgroups 18-20")

random.seed(42012)
out3 = []
for d in range(25):
    n = random.choice([80, 100, 120])
    p = 0.30 if 17 <= d+1 <= 19 else 0.14
    out3.append((n, sum(1 for _ in range(n) if random.random() < p)))
gen3 = "day,orders_inspected,late_orders\n" + "".join(f"{d+1},{n},{k}\n" for d, (n, k) in enumerate(out3))
if gen3 != open(os.path.join(ROOT, 'data/lead-defectives.csv')).read():
    FAILS.append("lead-defectives.csv does not regenerate byte-exact from seed 42012")

# --- module 08 README/solution-key numbers ---
x = [float(r['bore_diameter_mm']) for r in csv.DictReader(open(os.path.join(ROOT, 'data/bore-baseline-100.csv')))]
n = len(x); mean = sum(x)/n; s = statistics.stdev(x); srt = sorted(x)
def pct(d, p):
    k = (len(d)+1)*p; fl = int(k); fr = k-fl
    return d[fl-1] + fr*(d[fl]-d[fl-1])
q1, q3 = pct(srt, 0.25), pct(srt, 0.75)
LSL, USL = 11.975, 12.025
check('n', n, 100)
check('mean_4dp', round(mean, 4), 12.0098)
check('stdev_4dp', round(s, 4), 0.0074)
check('stdev_full', round(s, 6), 0.007417)
check('mean_full', round(mean, 6), 12.009815)
check('min', min(x), 11.9849)
check('max', max(x), 12.0293)
check('range', round(max(x)-min(x), 4), 0.0444)
check('Q1', round(q1, 4), 12.0059)
check('median', statistics.median(x), 12.00995)
check('Q3', round(q3, 4), 12.0146)
check('IQR_4dp', round(q3-q1, 4), 0.0087)
check('z_USL', round((USL-mean)/s, 2), 2.05)
check('z_LSL', round((mean-LSL)/s, 2), 4.69)
check('z_max_vs_USL', round((USL-max(x))/s, 2), -0.58)
check('oos_bores', sorted(v for v in x if v < LSL or v > USL), [12.0293])
check('cpk_sample', round((USL-mean)/(3*s), 4), 0.6824)
check('z_centered', round(0.025/s, 2), 3.37)
check('tail_centered_2side', round(2*(1-Phi(0.025/s)), 4), round(7.504657809551674e-04, 4), 1e-9)
check('median_row50', srt[49], 12.0097)
check('median_row51', srt[50], 12.0102)
check('q1_x25', srt[24], 12.0058)
check('q1_x26', srt[25], 12.0062)
check('binding_tail_offcenter', round(1-Phi((USL-mean)/0.0074), 4), round(0.02008351793902119, 4), 1e-9)

if FAILS:
    print("MODULE 08 COURT FAIL")
    for f in FAILS: print(" -", f)
    sys.exit(1)
print("MODULE 08 COURT PASS (3 dataset-regen + 24 numeric derivations, exit 0)")
