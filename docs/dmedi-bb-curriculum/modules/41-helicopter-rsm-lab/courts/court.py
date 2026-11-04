#!/usr/bin/env python3
"""Module 41 court — independent re-derivation of the screening effects, CCD
quadratic coefficients, stationary point, and confirmation. Exit 0/1.
"""
import csv, math, sys, statistics as st

BASE = __file__.replace("courts/court.py", "")
fails = []

def check(nm, got, exp, tol=0.01):
    ok = abs(got - exp) <= tol
    if not ok:
        fails.append(nm)
    print(f"  {'PASS' if ok else 'FAIL'}  {nm}: got {got:.4f} expected {exp}")

def solve(A):
    p = len(A)
    for col in range(p):
        piv = max(range(col, p), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        for r in range(p):
            if r != col:
                fac = A[r][col] / A[col][col]
                A[r] = [A[r][k] - fac * A[col][k] for k in range(1 + p)]
    return [A[i][p] / A[i][i] for i in range(p)]

rows = list(csv.DictReader(open(f"{BASE}data/helicopter-rsm.csv")))
check("39 rows total (confirmation flown separately, printed not stored)",
      len(rows), 39, 0)

scr = [r for r in rows if r["stage"] == "screen"]
check("16 screening runs", len(scr), 16, 0)
y = [float(r["median_s"]) for r in scr]
check("screen grand mean", st.mean(y), 3.001, 0.01)

NAMES = ["wing_len", "wing_wid", "tail_len", "tail_wid", "body_hgt",
         "clips", "fold_hgt"]

# screening effects via contrast route (regenerate alias structure from the
# generators E=ACD, F=ABC, G=BCD rather than trusting CSV columns)
effects = []
for k in range(7):
    col = []
    for r in scr:
        s = [int(r[f"x{i+1}_{n}"]) for i, n in enumerate(NAMES)]
        e = s[0] * s[2] * s[3]
        f = s[0] * s[1] * s[2]
        g = s[1] * s[2] * s[3]
        x = [s[0], s[1], s[2], s[3], e, f, g]
        col.append(x[k])
    eff = (sum(y[i] for i in range(16) if col[i] == 1) -
           sum(y[i] for i in range(16) if col[i] == -1)) / 8
    effects.append(eff)
exp_eff = (0.906, 0.496, -0.301, 0.074, -0.049, 0.027, -0.029)
for nm, got, exp in zip(NAMES, effects, exp_eff):
    # published numbers are OLS coefficients; the true contrast effect is 2x
    check(f"screen coef {nm} (contrast/2)", got / 2, exp, 0.01)
check("active set is A,B,C", 1.0 if [i for i in range(7) if
      abs(effects[i]) > 0.15] == [0, 1, 2] else 0.0, 1.0, 0.0)

# stage 3: independent CCD quadratic refit
ccd = [r for r in rows if r["stage"] == "ccd"]
check("19 CCD runs", len(ccd), 19, 0)
check("6 axial runs", sum(1 for r in ccd if r["phase"] == "axial"), 6, 0)
check("5 center runs", sum(1 for r in ccd if r["phase"] == "center"), 5, 0)
X, yv = [], []
for r in ccd:
    a = float(r["x1_wing_len"])
    b = float(r["x2_wing_wid"])
    c3 = float(r["x3_tail_len"])
    X.append([1.0, a, b, c3, a * b, a * c3, b * c3, a * a, b * b, c3 * c3])
    yv.append(float(r["median_s"]))
bcoef = solve([[sum(a[i] * a[j] for a in X) for j in range(10)] +
               [sum(a[i] * v for a, v in zip(X, yv))] for i in range(10)])
exp_coef = (4.184, 0.913, 0.506, -0.273, 0.134, -0.009, 0.046,
            -0.453, -0.538, -0.195)
names = ("b0", "bA", "bB", "bC", "bAB", "bAC", "bBC", "bAA", "bBB", "bCC")
for nm, got, exp in zip(names, bcoef, exp_coef):
    check(f"CCD coefficient {nm}", got, exp, 0.005)

# stationary point from the court's own coefficients
M = [[2 * bcoef[7], bcoef[4], bcoef[5]],
     [bcoef[4], 2 * bcoef[8], bcoef[6]],
     [bcoef[5], bcoef[6], 2 * bcoef[9]]]
v = [-bcoef[1], -bcoef[2], -bcoef[3]]
xopt = solve([list(M[i]) + [v[i]] for i in range(3)])
for nm, got, exp in zip(("A", "B", "C"), xopt, (1.100, 0.579, -0.655)):
    check(f"stationary point {nm}", got, exp, 0.005)
Topt = (bcoef[0] + bcoef[1] * xopt[0] + bcoef[2] * xopt[1] +
        bcoef[3] * xopt[2] + bcoef[4] * xopt[0] * xopt[1] +
        bcoef[5] * xopt[0] * xopt[2] + bcoef[6] * xopt[1] * xopt[2] +
        bcoef[7] * xopt[0] ** 2 + bcoef[8] * xopt[1] ** 2 +
        bcoef[9] * xopt[2] ** 2)
check("predicted T at optimum", Topt, 4.922, 0.005)

md = open(f"{BASE}slides-outline.md").read()
for token in ("0.906", "0.496", "-0.301", "4.184", "0.453", "0.538", "1.100",
              "4.922", "4.95 s", "133.0", "48.7", "46.9",
              "16 + ascent 4 + CCD 19", "+1.95 s"):
    check(f"outline cites {token}", 1.0 if token in md else 0.0, 1.0, 0.0)

print(f"\nMODULE 41 COURT: {'PASS' if not fails else 'FAIL'} "
      f"({len(fails)} failures)")
sys.exit(1 if fails else 0)
