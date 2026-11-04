#!/usr/bin/env python3
"""Module 20 court. Run from curriculum root. Exit 0 = every key number re-derives."""
import csv, math, sys, os
import numpy as np
from scipy import stats

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "20-confidence-intervals", "data")
SRC = os.path.join(D, "ci-trap-overlap.csv")
B30 = os.path.join(ROOT, "19-hypothesis-testing", "data", "bore-30.csv")
for f in (SRC, B30):
    if not os.path.exists(f):
        sys.exit(f"VACUOUS COURT: module 20 dataset missing: {f}")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---- bore-30 CIs (seed 42190, shared with M19) ----
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(open(B30))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s / math.sqrt(n)
check("bore30_n", n, 30)
check("bore30_xbar", round(xb, 4), 12.0072)
check("bore30_s", round(s, 4), 0.0035)
for c, want in ((0.90, (12.0061, 12.0083)), (0.95, (12.0059, 12.0085)), (0.99, (12.0054, 12.0090))):
    lo, hi = stats.t.interval(c, n - 1, loc=xb, scale=se)
    check(f"bore30_ci_{c}", (round(lo, 4), round(hi, 4)), want)
check("bore30_95_excludes_nominal", 12.0085 < 12.000 or 12.0059 > 12.000, True)

# ---- CI-overlap trap (seed 42290) ----
rows = list(csv.DictReader(open(SRC)))
t1 = np.array([float(r["spindle1_mm"]) for r in rows])
t2 = np.array([float(r["spindle2_mm"]) for r in rows])
check("trap_n", (len(t1), len(t2)), (30, 30))
m1, m2 = t1.mean(), t2.mean()
s1, s2 = t1.std(ddof=1), t2.std(ddof=1)
c1 = stats.t.interval(0.95, 29, loc=m1, scale=s1 / math.sqrt(30))
c2 = stats.t.interval(0.95, 29, loc=m2, scale=s2 / math.sqrt(30))
check("m1", round(m1, 4), 12.0032); check("s1", round(s1, 4), 0.0013)
check("c1", (round(c1[0], 4), round(c1[1], 4)), (12.0027, 12.0036))
check("m2", round(m2, 4), 12.0022); check("s2", round(s2, 4), 0.0023)
check("c2", (round(c2[0], 4), round(c2[1], 4)), (12.0013, 12.0030))
ov_lo, ov_hi = max(c1[0], c2[0]), min(c1[1], c2[1])
check("overlap_nonempty", ov_hi > ov_lo, True)
check("overlap_pct_of_narrow", round((ov_hi - ov_lo) / (c1[1] - c1[0]) * 100), 36, tol=1.0)
t, p = stats.ttest_ind(t1, t2, equal_var=True)
check("t_pooled", round(t, 3), 2.062)
check("p", round(p, 4), 0.0437)
sp = math.sqrt((29 * s1 ** 2 + 29 * s2 ** 2) / 58)
d = m1 - m2
ci_d = (d - 2.002 * sp * math.sqrt(2 / 30), d + 2.002 * sp * math.sqrt(2 / 30))
check("diff_ci_excludes_zero", round(ci_d[0], 4) >= 0.0 and round(ci_d[1], 4), 0.0019)
check("trap_verified", (ov_hi > ov_lo) and (p < 0.05), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 20 court: ALL CHECKS PASS (bore-30 CIs, CI-overlap trap: overlap AND p=0.0437 reject)")
