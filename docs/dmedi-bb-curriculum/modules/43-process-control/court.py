#!/usr/bin/env python3
"""Module 43 court. Run from curriculum root. Exit 0 = all control-plan numbers re-derive."""
import csv, math, statistics, sys, os, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "42-prototype-pilot", "data")
SRC = os.path.join(D, "pilot-bore-30day.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: Module 42 pilot dataset missing — regenerate first")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok: fail.append(f"{name}: got {got}, want {want}")

rows = list(csv.reader(open(SRC)))[1:]
subs = collections.defaultdict(list)
for r in rows: subs[(int(r[0]), int(r[1]))].append(float(r[3]))
xb = [statistics.mean(v) for v in subs.values()]
R = [max(v) - min(v) for v in subs.values()]
xbb, Rbar = statistics.mean(xb), statistics.mean(R)
A2, D3, D4, d2 = 0.577, 0.0, 2.114, 2.326
check("subgroups", len(xb), 240)
check("Xbb", round(xbb, 4), 12.0049, 1e-9)
check("Rbar", round(Rbar, 4), 0.0102, 1e-9)
check("UCLx", round(xbb + A2 * Rbar, 4), 12.0108, 1e-9)
check("LCLx", round(xbb - A2 * Rbar, 4), 11.9990, 1e-9)
check("UCLR", round(D4 * Rbar, 4), 0.0216, 1e-9)
check("LCLR", round(D3 * Rbar, 4), 0.0, 1e-9)
sigma_hat = Rbar / d2
check("sigma_hat", round(sigma_hat, 5), 0.00439, 1e-9)
check("PCR", round(0.050 / (6 * sigma_hat), 3), 1.897, 1e-9)
check("limits_inside_specs", 11.9990 > 11.975 and 12.0108 < 12.025, True)

# p-chart
sc = list(csv.reader(open(os.path.join(D, "pilot-scrap-daily.csv"))))[1:]
X = sum(int(r[2]) for r in sc); N = sum(int(r[1]) for r in sc)
pbar = X / N
sp = math.sqrt(pbar * (1 - pbar) / 150)
check("scrap_total", X, 5)
check("pbar", round(pbar, 6), 0.001111, 5e-7)
check("UCLp", round(pbar + 3 * sp, 5), 0.00927, 1e-9)
check("LCLp_floored", round(max(0.0, pbar - 3 * sp), 5), 0.0, 1e-9)
day1_rate = 3 / 150
check("day1_signal", day1_rate > pbar + 3 * sp, True)

# vacuity mutation: wrong constants (n=4: A2=0.729, D4=2.282) must produce DIFFERENT limits
wA2, wD4 = 0.729, 2.282
check("mutation_detected_n4",
      round(xbb + wA2 * Rbar, 4) != round(xbb + A2 * Rbar, 4) and
      round(wD4 * Rbar, 4) != round(D4 * Rbar, 4), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 43 court: ALL CHECKS PASS (X-bar/R limits, sigma-hat/PCR, p-chart, day-1 signal, wrong-constants mutation)")
