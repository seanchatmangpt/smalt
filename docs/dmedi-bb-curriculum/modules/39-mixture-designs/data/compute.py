#!/usr/bin/env python3
"""Module 39 solution key — simplex lattice mixture design for the CPPC coolant
concentrate. Components x1 = neat cutting oil, x2 = emulsifier, x3 = water
(sum to 1). Response: tool life in minutes on the SR-71 housing roughing pass.
{3,2} simplex lattice (6 points) + overall centroid, 2 reps each, seed 39001.
Scheffe quadratic fit by the lattice identities + OLS cross-check; response
surface evaluated over the simplex grid.

Regenerates coolant-mixture.csv and re-derives every printed number from it.
"""
import csv, random

SEED = 39001
BASE = __file__.rsplit("/", 1)[0]

# true Scheffe quadratic (tool life, min):
# eta = 12*x1 + 6*x2 + 2*x3 + 22*x1*x2 - 4*x1*x3 + 3*x2*x3
B_TRUE = {"1": 12.0, "2": 6.0, "3": 2.0, "12": 22.0, "13": -4.0, "23": 3.0}

def eta(x1, x2, x3):
    return (B_TRUE["1"] * x1 + B_TRUE["2"] * x2 + B_TRUE["3"] * x3
            + B_TRUE["12"] * x1 * x2 + B_TRUE["13"] * x1 * x3
            + B_TRUE["23"] * x2 * x3)

POINTS = [  # (label, x1, x2, x3)
    ("V1", 1.0, 0.0, 0.0),
    ("V2", 0.0, 1.0, 0.0),
    ("V3", 0.0, 0.0, 1.0),
    ("M12", 0.5, 0.5, 0.0),
    ("M13", 0.5, 0.0, 0.5),
    ("M23", 0.0, 0.5, 0.5),
    ("C", 1/3, 1/3, 1/3),
]

def generate():
    random.seed(SEED)
    with open(f"{BASE}/coolant-mixture.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["point", "x1_oil", "x2_emulsifier", "x3_water", "rep",
                    "tool_life_min"])
        for label, a, b, c in POINTS:
            for rep in (1, 2):
                y = random.gauss(eta(a, b, c), 0.8)
                w.writerow([label, round(a, 4), round(b, 4), round(c, 4),
                            rep, round(y, 2)])

generate()

rows = list(csv.DictReader(open(f"{BASE}/coolant-mixture.csv")))
mean = {}
for label, a, b, c in POINTS:
    ys = [float(r["tool_life_min"]) for r in rows if r["point"] == label]
    mean[label] = (sum(ys) / len(ys), a, b, c, ys)

print("== Module 39 solution key: simplex-lattice mixture design ==")
print("coolant concentrate: x1 oil + x2 emulsifier + x3 water = 1.000")
print("response: tool life (min), 2 reps/point, seed 39001\n")
for label, (m, a, b, c, ys) in mean.items():
    print(f"  {label:<4} ({a:.3f},{b:.3f},{c:.3f})  ybar = {m:6.2f}  obs {ys}")

# pure error SD
allres = [s for label, (m, a, b, c, ys) in mean.items()
          for s in [(y - m) ** 2 for y in ys]]
pe = (sum(allres) / (len(allres) - len(POINTS))) ** 0.5
print(f"\npure-error SD = {pe:.3f} min (df = {len(allres) - len(POINTS)})")

# --- Scheffe quadratic via lattice identities (no matrix needed) ---
b1 = mean["V1"][0]
b2 = mean["V2"][0]
b3 = mean["V3"][0]
b12 = 4 * mean["M12"][0] - 2 * (mean["V1"][0] + mean["V2"][0])
b13 = 4 * mean["M13"][0] - 2 * (mean["V1"][0] + mean["V3"][0])
b23 = 4 * mean["M23"][0] - 2 * (mean["V2"][0] + mean["V3"][0])
print("\n-- Scheffe quadratic coefficients (lattice identities) --")
print(f"  b1 (oil)          = {b1:6.2f}")
print(f"  b2 (emulsifier)   = {b2:6.2f}")
print(f"  b3 (water)        = {b3:6.2f}")
print(f"  b12 (nonlinear)   = {b12:6.2f}")
print(f"  b13 (nonlinear)   = {b13:6.2f}")
print(f"  b23 (nonlinear)   = {b23:6.2f}")
print("  yhat = b1*x1 + b2*x2 + b3*x3 + b12*x1x2 + b13*x1x3 + b23*x2x3")

# OLS cross-check on all 14 obs (6 params, 8 df residual incl 7 pure-error)
import itertools
def solve_ols():
    X, y = [], []
    for r in rows:
        x1, x2, x3 = (float(r["x1_oil"]), float(r["x2_emulsifier"]),
                      float(r["x3_water"]))
        X.append([x1, x2, x3, x1 * x2, x1 * x3, x2 * x3])
        y.append(float(r["tool_life_min"]))
    p = 6
    XtX = [[sum(row[i] * row[j] for row in X) for j in range(p)] for i in range(p)]
    Xty = [sum(row[i] * yy for row, yy in zip(X, y)) for i in range(p)]
    A = [XtX[i] + [Xty[i]] for i in range(p)]
    for col in range(p):
        piv = max(range(col, p), key=lambda rr: abs(A[rr][col]))
        A[col], A[piv] = A[piv], A[col]
        for rr in range(p):
            if rr != col:
                f = A[rr][col] / A[col][col]
                A[rr] = [A[rr][k] - f * A[col][k] for k in range(p + 1)]
    return [A[i][p] / A[i][i] for i in range(p)]

bols = solve_ols()
print("\n-- OLS cross-check (all 14 obs) --")
for nm, v in zip(["b1", "b2", "b3", "b12", "b13", "b23"], bols):
    print(f"  {nm:<4} = {v:6.2f}")
resid = []
for r in rows:
    x1, x2, x3 = (float(r["x1_oil"]), float(r["x2_emulsifier"]),
                  float(r["x3_water"]))
    yh = sum(c * v for c, v in zip(bols, [x1, x2, x3, x1 * x2, x1 * x3, x2 * x3]))
    resid.append(float(r["tool_life_min"]) - yh)
s_res = (sum(e * e for e in resid) / (len(resid) - 6)) ** 0.5
print(f"  residual SD = {s_res:.3f} min on {len(resid) - 6} df")

# ---- response surface over the simplex: best blend search ----
def yhat(x1, x2, x3):
    return (b1 * x1 + b2 * x2 + b3 * x3 + b12 * x1 * x2 + b13 * x1 * x3
            + b23 * x2 * x3)

best = (-1, None)
grid = []
step = 0.05
i = 0
while i <= 20:
    x1 = round(i * step, 3)
    j = 0
    while j <= 20 - i:
        x2 = round(j * step, 3)
        x3 = round(1 - x1 - x2, 3)
        yv = yhat(x1, x2, x3)
        grid.append((x1, x2, x3, yv))
        if yv > best[0]:
            best = (yv, (x1, x2, x3))
        j += 1
    i += 1
print("\n-- surface search over the simplex (5% grid, 231 blends) --")
yb, (x1b, x2b, x3b) = best
print(f"  optimum blend: oil {x1b:.2f} / emulsifier {x2b:.2f} / water {x3b:.2f}"
      f"  ->  predicted tool life {yb:.2f} min")
for x1 in (0.3, 0.4, 0.5, 0.6, 0.7):
    x2 = round((1 - x1) / 2, 3)
    x3 = round((1 - x1) / 2, 3)
    print(f"  slice x1={x1:.2f}: emul/water 50-50 -> {yhat(x1, x2, x3):6.2f} min")

# contrast that proves the synergy: observed M12 vs linear blend of vertices
lin12 = (mean["V1"][0] + mean["V2"][0]) / 2
print(f"\nsynergy check oil+emulsifier: midpoint observed {mean['M12'][0]:.2f}"
      f" vs linear-blend expectation {lin12:.2f}"
      f" -> {'synergistic' if mean['M12'][0] > lin12 else 'antagonistic'} bend")
lin13 = (mean["V1"][0] + mean["V3"][0]) / 2
print(f"oil+water: midpoint {mean['M13'][0]:.2f} vs linear {lin13:.2f}"
      f" -> {'synergistic' if mean['M13'][0] > lin13 else 'antagonistic'} bend")
