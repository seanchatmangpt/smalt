#!/usr/bin/env python3
"""Module 36 court — re-derives every number in the solution key from the seeded CSV.
Exit 0 = match; exit 1 prints the first failing derivation."""
import csv, math, random, statistics, sys

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

BASE = __file__.replace("courts/court.py", "")

# 0. dataset regenerates byte-identically
csv_path = BASE + "data/weibull-failure-times.csv"
orig = open(csv_path).read()
import subprocess
subprocess.run([sys.executable, BASE + "scripts/generate_dataset.py"],
               check=True, capture_output=True)
regen = open(csv_path).read()
check("dataset_byte_identical", int(regen == orig), 1)

TS = sorted(float(r["hours"]) for r in csv.DictReader(open(csv_path)))

# Part 1
mean = statistics.mean(TS)
check("sample_mean", round(mean, 1), 1203.4, 0.05)
pos = 0.1 * (len(TS) + 1)
lo = int(pos)
p10 = TS[lo - 1] + (pos - lo) * (TS[lo] - TS[lo - 1])
check("empirical_B10", round(p10, 1), 879.4, 0.05)
n = len(TS)
xs = [math.log(-math.log(1 - i / (n + 1))) for i in range(1, n + 1)]
ys = [math.log(t) for t in TS]
sx, sy = sum(xs), sum(ys)
sxx = sum(x * x for x in xs)
sxy = sum(a * b for a, b in zip(xs, ys))
slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
intercept = (sy - slope * sx) / n
check("regression_slope", round(slope, 4), 0.1585, 0.0001)
check("beta_hat", round(1 / slope, 2), 6.31, 0.01)
check("eta_hat", round(math.exp(intercept), 1), 1291.3, 0.1)

# Part 2 — exponential B10
exp_b10 = -math.log(0.9) * 1200
check("exp_B10", round(exp_b10, 1), 126.4, 0.05)

# spine pair joint consistency: bisection for beta
c = -math.log(0.9)
def ratio(b): return math.gamma(1 + 1 / b) / c ** (1 / b)
blo, bhi = 5.0, 10.0
for _ in range(80):
    mid = (blo + bhi) / 2
    if ratio(mid) > 4 / 3:
        blo = mid
    else:
        bhi = mid
beta = (blo + bhi) / 2
check("spine_beta", round(beta, 4), 6.2417, 0.0005)
eta = 900 / c ** (1 / beta)
check("spine_eta", round(eta, 1), 1290.7, 0.1)
check("spine_mtbf_rederived", round(eta * math.gamma(1 + 1 / beta), 1), 1200.0, 0.1)
check("spine_B10_rederived", round(eta * c ** (1 / beta), 1), 900.0, 0.1)

# Part 3 — allocation
lam = [4.5e-4, 1.5e-4, 1.0e-4, 1 / 12000, 0.5e-4]
check("lambda_sum", sum(lam), 1 / 1200, 1e-12)
check("alloc_mtbf", round(1 / sum(lam), 1), 1200.0, 0.1)

# Part 4 — availability
mttr = [6, 4, 2, 1.5, 3]
A = 1.0
comp = []
for l, m in zip(lam, mttr):
    mtbf = 1 / l
    a = mtbf / (mtbf + m)
    comp.append(a)
    A *= a
check("A_sys", round(A, 4), 0.9962, 0.0001)
check("downtime_yr_h", round((1 - A) * 8760, 0), 33.0, 0.5)
check("A_bearing", round(comp[0], 5), 0.99731, 0.00001)
# bearing degraded to 1500 h MTBF
Ab = 1500 / 1506
comp2 = [Ab] + comp[1:]
A2 = 1.0
for a in comp2:
    A2 *= a
check("A_sys_bearing1500", round(A2, 4), 0.9949, 0.0001)
check("downtime_bearing1500", round((1 - A2) * 8760, 1), 44.3, 0.1)
# parallel
Ap = 1 - (1 - A) ** 2
check("A_parallel", round(Ap, 7), 0.9999858, 0.0000001)
check("parallel_saving_usd", round(((1 - A) - (1 - Ap)) * 8760 * 150, 0), 4927.0, 1.0)

# Part 5 — PM intervals
for p, want in ((0.01, 617.7), (0.001, 426.8)):
    T = eta * (-math.log(1 - p)) ** (1 / beta)
    check(f"PM_interval_{p}", round(T, 1), want, 0.1)
check("F_900_pct", round(100 * (1 - math.exp(-(900 / eta) ** beta)), 1), 10.0, 0.1)

if FAILS:
    print("MODULE 36 COURT: FAIL")
    for f_ in FAILS:
        print("  " + f_)
    sys.exit(1)
print("MODULE 36 COURT: PASS (all %d derivations match key)" % 22)
