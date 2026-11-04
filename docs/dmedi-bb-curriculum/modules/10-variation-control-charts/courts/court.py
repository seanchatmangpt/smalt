#!/usr/bin/env python3
"""Module 10 court — re-derives every number in the module 10 README/solution-key
from the three lane-04 datasets (byte-exact seed regeneration first), including
limit arithmetic, out-of-control points, and run-rule hits.
Exit 0 = all derivations match; exit 1 = mismatches printed."""
import csv, sys, random
from math import sqrt

import os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

# --- dataset integrity: byte-exact regeneration from stated seeds ---
random.seed(42008)
vals = [random.gauss(12.009, 0.007407) for _ in range(100)]
if "observation,bore_diameter_mm\n" + "".join(f"{i+1},{v:.4f}\n" for i, v in enumerate(vals)) \
        != open(os.path.join(ROOT, 'data/bore-baseline-100.csv')).read():
    FAILS.append("bore-baseline-100.csv regen mismatch (seed 42008 @ sigma 0.007407)")

random.seed(42011)
rows2 = ["subgroup,sample1,sample2,sample3,sample4,sample5"]
for sg in range(25):
    shift = 0.015 if 18 <= sg+1 <= 20 else 0.0
    rows2.append(f"{sg+1}," + ",".join(f"{random.gauss(12.009,0.007407)+shift:.4f}" for _ in range(5)))
if "\n".join(rows2) + "\n" != open(os.path.join(ROOT, 'data/xbar-r-subgroups.csv')).read():
    FAILS.append("xbar-r-subgroups.csv regen mismatch (seed 42011 @ sigma 0.007407, +0.015 shift 18-20)")

random.seed(42012)
out3 = []
for d in range(25):
    n = random.choice([80, 100, 120])
    p = 0.30 if 17 <= d+1 <= 19 else 0.14
    out3.append((n, sum(1 for _ in range(n) if random.random() < p)))
gen3 = "day,orders_inspected,late_orders\n" + "".join(f"{d+1},{n},{k}\n" for d, (n, k) in enumerate(out3))
if gen3 != open(os.path.join(ROOT, 'data/lead-defectives.csv')).read():
    FAILS.append("lead-defectives.csv regen mismatch (seed 42012)")

# --- X-bar/R ---
rows = list(csv.DictReader(open(os.path.join(ROOT, 'data/xbar-r-subgroups.csv'))))
means, ranges = [], []
for r in rows:
    v = [float(r[f'sample{i}']) for i in range(1, 6)]
    means.append(sum(v)/5); ranges.append(max(v)-min(v))
xbb = sum(means)/25; rb = sum(ranges)/25
A2, D3, D4, d2 = 0.577, 0.0, 2.114, 2.326
check('Xbb', round(xbb, 4), 12.0116)
check('Rbar', round(rb, 4), 0.0191)
check('UCLx', round(xbb+A2*rb, 4), 12.0226)
check('LCLx', round(xbb-A2*rb, 4), 12.0006)
check('RUCL', round(D4*rb, 4), 0.0404)
check('sigma_hat_um', round(rb/d2*1000, 2), 8.21)
check('sigma_xbar_um', round(rb/d2/sqrt(5)*1000, 3), 3.672)
ooc = [(i+1, round(m, 4)) for i, m in enumerate(means) if m > xbb+A2*rb or m < xbb-A2*rb]
check('ooc_all_limits', ooc, [(19, 12.0278), (20, 12.0267)])
keep = [i for i in range(25) if not (18 <= i+1 <= 20)]
x2 = sum(means[i] for i in keep)/22; r2 = sum(ranges[i] for i in keep)/22
check('p1_Xbb', round(x2, 4), 12.0097)
check('p1_Rbar', round(r2, 4), 0.0192)
check('p1_UCL', round(x2+A2*r2, 4), 12.0208)
check('p1_LCL', round(x2-A2*r2, 4), 11.9986)
check('p1_RUCL', round(D4*r2, 4), 0.0406)
check('p1_sigma_hat_um', round(r2/d2*1000, 2), 8.25)
ooc2 = [(i+1, round(means[i], 4)) for i in range(25) if means[i] > x2+A2*r2 or means[i] < x2-A2*r2]
check('ooc_p1_limits', ooc2, [(18, 12.022), (19, 12.0278), (20, 12.0267)])
check('sg18_inside_all_data_by', round(xbb+A2*rb - means[17], 4), 0.0006, 0.0002)

sig_xb = rb/d2/sqrt(5)
def runrules(pts, cl, sig):
    z = [(p-cl)/sig for p in pts]; out = set()
    for i in range(len(pts)):
        if abs(z[i]) > 3: out.add((i+1, 'T1'))
    for i in range(len(pts)-8):
        seg = z[i:i+9]
        if all(v > 0 for v in seg) or all(v < 0 for v in seg): out.add((i+9, 'T2'))
    for i in range(len(pts)-5):
        seg = z[i:i+6]
        if all(seg[j+1] > seg[j] for j in range(5)) or all(seg[j+1] < seg[j] for j in range(5)):
            out.add((i+6, 'T3'))
    for i in range(len(pts)-1):
        w = z[i:i+3]
        for s in (1, -1):
            if sum(1 for v in w if s*v > 2) >= 2: out.add((i+3, 'T5'))
    for i in range(len(pts)-3):
        w = z[i:i+5]
        for s in (1, -1):
            if sum(1 for v in w if s*v > 1) >= 4: out.add((i+5, 'T6'))
    return out
check('xbar_rules', runrules(means, xbb, sig_xb),
      {(19, 'T1'), (20, 'T1'), (19, 'T5'), (20, 'T5'), (21, 'T5')})
check('xbar_R_no_signals', [g for g in ranges if g > D4*rb], [])

# --- I-MR ---
x = [float(r['bore_diameter_mm']) for r in csv.DictReader(open(os.path.join(ROOT, 'data/bore-baseline-100.csv')))]
mr = [abs(x[i]-x[i-1]) for i in range(1, len(x))]
mrb = sum(mr)/len(mr); m = sum(x)/len(x)
check('I_mean', round(m, 4), 12.0098)
check('MRbar_5dp', round(mrb, 5), 0.00770)
check('I_UCL', round(m+2.66*mrb, 4), 12.0303)
check('I_LCL', round(m-2.66*mrb, 4), 11.9893)
check('MR_UCL', round(3.267*mrb, 5), 0.02517)
check('sigma_I', round(mrb/1.128, 6), 0.006829)
check('I_ooc', [(i+1, x[i]) for i in range(len(x)) if x[i] > m+2.66*mrb or x[i] < m-2.66*mrb],
      [(41, 11.9849)])
check('MR_ooc', [(i+2, round(v, 4)) for i, v in enumerate(mr) if v > 3.267*mrb],
      [(10, 0.0268), (11, 0.0281), (23, 0.0386), (41, 0.0304)])
check('I_rules', runrules(x, m, mrb/1.128), {(41, 'T1'), (12, 'T6')})
check('I_halfwidth_vs_xbar', round(2.66*mrb, 4) > round(A2*r2, 4), True)

# --- p-chart ---
d = list(csv.DictReader(open(os.path.join(ROOT, 'data/lead-defectives.csv'))))
ns = [int(r['orders_inspected']) for r in d]
late = [int(r['late_orders']) for r in d]
pbar = sum(late)/sum(ns)
check('pbar', round(pbar, 4), 0.1516)
check('pbar_exact', sum(late), 388)
check('pbar_n', sum(ns), 2560)
ucl_n120 = pbar + 3*sqrt(pbar*(1-pbar)/120)
ucl_n100 = pbar + 3*sqrt(pbar*(1-pbar)/100)
ucl_n80 = pbar + 3*sqrt(pbar*(1-pbar)/80)
check('UCL_n120', round(ucl_n120, 3), 0.250)
check('UCL_n100', round(ucl_n100, 3), 0.259)
check('UCL_n80', round(ucl_n80, 3), 0.272)
viol = []
for i, (n, p) in enumerate(zip(ns, late)):
    f = p/n
    u = pbar + 3*sqrt(pbar*(1-pbar)/n); l = pbar - 3*sqrt(pbar*(1-pbar)/n)
    if f > u or f < max(l, 0): viol.append((i+1, n, p))
check('p_ooc_days', viol, [(17, 120, 31), (18, 120, 38)])
check('day17_frac', round(late[16]/ns[16], 3), 0.258)
check('day18_frac', round(late[17]/ns[17], 3), 0.317)
check('day19_frac', round(late[18]/ns[18], 3), 0.240)
check('day19_inside', late[18]/ns[18] < ucl_n100, True)

if FAILS:
    print("MODULE 10 COURT FAIL")
    for f in FAILS: print(" -", f)
    sys.exit(1)
print("MODULE 10 COURT PASS (3 dataset-regen + 37 numeric derivations, exit 0)")
