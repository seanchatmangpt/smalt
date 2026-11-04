#!/usr/bin/env python3
"""Module 39 court — independent re-derivation of the Scheffe quadratic,
synergy contrasts, and simplex optimum. Exit 0/1.
"""
import csv, sys, statistics as st

BASE = __file__.replace("courts/court.py", "")
fails = []

def check(nm, got, exp, tol=0.01):
    ok = abs(got - exp) <= tol
    if not ok:
        fails.append(nm)
    print(f"  {'PASS' if ok else 'FAIL'}  {nm}: got {got:.4f} expected {exp}")

rows = list(csv.DictReader(open(f"{BASE}data/coolant-mixture.csv")))
pts = {}
for r in rows:
    pts.setdefault(r["point"], []).append(float(r["tool_life_min"]))
means = {k: st.mean(v) for k, v in pts.items()}

# constraint law: x1+x2+x3 == 1 on every row (CSV stores 4 dp, so the
# centroid's 3 x 0.3333 = 0.9999 -- tolerance set at rounding scale)
bad = [r for r in rows
       if abs(float(r["x1_oil"]) + float(r["x2_emulsifier"]) +
              float(r["x3_water"]) - 1.0) > 5e-4]
check("sum-to-1 on all 14 rows (4 dp rounding)", 1.0 if not bad else 0.0,
      1.0, 0.0)

# lattice identities (own implementation)
b1 = means["V1"]
b2 = means["V2"]
b3 = means["V3"]
b12 = 4 * means["M12"] - 2 * (means["V1"] + means["V2"])
b13 = 4 * means["M13"] - 2 * (means["V1"] + means["V3"])
b23 = 4 * means["M23"] - 2 * (means["V2"] + means["V3"])
for nm, got, exp in (("b1", b1, 12.85), ("b2", b2, 7.01), ("b3", b3, 2.71),
                     ("b12", b12, 15.99), ("b13", b13, -9.53),
                     ("b23", b23, -0.34)):
    check(nm, got, exp)

# independent OLS refit (all 14 obs, Scheffe quadratic)
def gauss_solve(A):
    p = len(A)
    for col in range(p):
        piv = max(range(col, p), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        for r in range(p):
            if r != col:
                fac = A[r][col] / A[col][col]
                A[r] = [A[r][k] - fac * A[col][k] for k in range(p + 1)]
    return [A[i][p] / A[i][i] for i in range(p)]

X, y = [], []
for r in rows:
    x1, x2, x3 = (float(r["x1_oil"]), float(r["x2_emulsifier"]),
                  float(r["x3_water"]))
    X.append([x1, x2, x3, x1 * x2, x1 * x3, x2 * x3])
    y.append(float(r["tool_life_min"]))
c = gauss_solve([[sum(a[i] * a[j] for a in X) for j in range(6)] +
                 [sum(a[i] * v for a, v in zip(X, y))] for i in range(6)])
for nm, got, exp in zip(("OLS b1", "OLS b2", "OLS b3", "OLS b12", "OLS b13",
                         "OLS b23"), c, (12.85, 7.00, 2.71, 16.01, -9.51,
                                         -0.32)):
    check(nm, got, exp, 0.01)

# centroid adequacy: observed 8.21 vs quadratic prediction
yh_c = ((b1 + b2 + b3) / 3 + (b12 + b13 + b23) / 9)
check("centroid predicted", yh_c, 8.20, 0.02)
check("centroid observed", means["C"], 8.21, 0.01)

# synergy signs
check("oil+emulsifier synergistic", 1.0 if means["M12"] >
      (means["V1"] + means["V2"]) / 2 else 0.0, 1.0, 0.0)
check("oil+water antagonistic", 1.0 if means["M13"] <
      (means["V1"] + means["V3"]) / 2 else 0.0, 1.0, 0.0)

# optimum search (5% grid, independent implementation)
def yhat(x1, x2, x3):
    return (b1 * x1 + b2 * x2 + b3 * x3 + b12 * x1 * x2 + b13 * x1 * x3
            + b23 * x2 * x3)
best = max(((yhat(i * 0.05, j * 0.05, round(1 - i * 0.05 - j * 0.05, 3)),
             i * 0.05, j * 0.05) for i in range(21) for j in range(21 - i)))
check("optimum tool life", best[0], 14.45, 0.01)
check("optimum oil share", best[1], 0.70, 1e-9)
check("optimum emulsifier share", best[2], 0.30, 1e-9)

md = open(f"{BASE}slides-outline.md").read()
for token in ("13.93", "14.45", "0.70", "+16.0", "8.21"):
    check(f"outline cites {token}", 1.0 if token in md else 0.0, 1.0, 0.0)

print(f"\nMODULE 39 COURT: {'PASS' if not fails else 'FAIL'} "
      f"({len(fails)} failures)")
sys.exit(1 if fails else 0)
