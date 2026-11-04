#!/usr/bin/env python3
"""Module 42 court. Run from curriculum root. Exit 0 = all numbers re-derive."""
import csv, math, statistics, sys, os
from math import comb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "42-prototype-pilot", "data")
fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok: fail.append(f"{name}: got {got}, want {want}")

for f in ("pilot-bore-30day.csv", "pilot-ra-daily.csv", "pilot-scrap-daily.csv"):
    if not os.path.exists(os.path.join(D, f)):
        sys.exit(f"VACUOUS COURT: missing dataset {f} — regenerate first")

# regenerate determinism check: re-running generator must reproduce byte-identical CSVs
import subprocess, hashlib
for gen, out in (("gen_pilot.py", "pilot-bore-30day.csv"),
                 ("gen_scrap.py", "pilot-scrap-daily.csv")):
    p = os.path.join(D, out)
    h0 = hashlib.sha256(open(p, "rb").read()).hexdigest()
    subprocess.run([sys.executable, os.path.join(D, gen)], cwd=D, check=True)
    h1 = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if h0 != h1: fail.append(f"generator {gen} not deterministic ({out} changed)")

rows = list(csv.reader(open(os.path.join(D, "pilot-bore-30day.csv"))))[1:]
bore = [float(r[3]) for r in rows]
n = len(bore)
mu, s = statistics.mean(bore), statistics.stdev(bore)
USL, LSL = 12.025, 11.975
cpk = min(USL - mu, mu - LSL) / (3 * s)
cp = (USL - LSL) / (6 * s)
se = math.sqrt(1 / (9 * n) + cpk * cpk / (2 * (n - 1)))
lcb = cpk - 1.645 * se
check("n", n, 1200)
check("mu", round(mu, 4), 12.0049, 1e-9)
check("s", round(s, 5), 0.00452, 1e-9)
check("Cp", round(cp, 3), 1.846, 1e-9)
check("Cpk", round(cpk, 3), 1.481, 1e-9)
check("OOS", sum(1 for b in bore if b < LSL or b > USL), 0)
check("SE", round(se, 4), 0.0317, 1e-9)
check("LCB>=1.33", lcb >= 1.33, True)

# lot-size derivation: min n for LCB>=1.33 at predicted Cpk 1.50
k = 2
while 1.5 - 1.645 * math.sqrt(1 / (9 * k) + 2.25 / (2 * (k - 1))) < 1.33:
    k += 1
check("min_n", k, 117)

# stability
import collections
subs = collections.defaultdict(list)
for r in rows: subs[(int(r[0]), int(r[1]))].append(float(r[3]))
xb = [statistics.mean(v) for v in subs.values()]
R = [max(v) - min(v) for v in subs.values()]
xbb, Rbar = statistics.mean(xb), statistics.mean(R)
A2, D4 = 0.577, 2.114
check("subgroups", len(xb), 240)
check("Xbb", round(xbb, 4), 12.0049, 1e-9)
check("Rbar", round(Rbar, 4), 0.0102, 1e-9)
check("UCLx", round(xbb + A2 * Rbar, 4), 12.0108, 1e-9)
check("LCLx", round(xbb - A2 * Rbar, 4), 11.9990, 1e-9)
check("UCLR", round(D4 * Rbar, 4), 0.0216, 1e-9)
check("OOC_xbar", sum(1 for x in xb if x > xbb + A2 * Rbar or x < xbb - A2 * Rbar), 0)
check("OOC_R", sum(1 for r in R if r > D4 * Rbar), 0)

# Ra
ra = [float(r[1]) for r in list(csv.reader(open(os.path.join(D, "pilot-ra-daily.csv"))))[1:]]
mr = [abs(ra[i + 1] - ra[i]) for i in range(len(ra) - 1)]
MRbar = statistics.mean(mr); rm = statistics.mean(ra)
check("Ra_mean", round(rm, 3), 0.807, 1e-9)
check("Ra_UCLI", round(rm + 2.66 * MRbar, 3), 0.933, 1e-9)
check("Ra_LCLI", round(rm - 2.66 * MRbar, 3), 0.681, 1e-9)
check("Ra_UCLMR", round(3.267 * MRbar, 3), 0.155, 1e-9)
check("Ra_OOC", sum(1 for v in ra if v > rm + 2.66 * MRbar or v < rm - 2.66 * MRbar), 0)
a, b = ra[:10], ra[20:]
sp = math.sqrt((9 * statistics.stdev(a) ** 2 + 9 * statistics.stdev(b) ** 2) / 18)
t = (statistics.mean(b) - statistics.mean(a)) / (sp * math.sqrt(2 / 10))
check("Ra_t", round(t, 3), 0.459, 1e-9)
check("Ra_no_drift", abs(t) < 2.101, True)

# scrap binomial exit
sc = list(csv.reader(open(os.path.join(D, "pilot-scrap-daily.csv"))))[1:]
X = sum(int(r[2]) for r in sc); N = sum(int(r[1]) for r in sc)
check("produced", N, 4500)
check("scrap", X, 5)
check("rate_pct", round(100 * X / N, 4), 0.1111, 1e-9)

def cdf(x, n_, p): return sum(comb(n_, kk) * p ** kk * (1 - p) ** (n_ - kk) for kk in range(x + 1))
def cp_upper(x, n_, p0=0.005):
    p = 0.0001
    while cdf(x, n_, p) > 0.05: p += 0.00001
    return p
check("crit14_cp_upper", round(cp_upper(14, N), 3), 0.005, 0.001)   # <= 0.005
check("crit15_cp_upper_exceeds", cp_upper(15, N) > 0.005, True)
check("scrap_pass", X <= 14, True)

# ppm at Cpk 1.33 (scrap-target derivation)
from statistics import NormalDist
check("ppm_1.33", round(2 * NormalDist().cdf(-3 * 1.33) * 1e6, 1), 66.1, 0.05)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 42 court: ALL CHECKS PASS (lot-size derivation, capability, stability, Ra, scrap binomial, generator determinism)")
