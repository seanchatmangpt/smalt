#!/usr/bin/env python3
"""Module 41 solution key — paper-helicopter sequential RSM lab.
Response: descent time (s) over a 3 m drop, median of 3 drops per run.
7 factors (coded units):
  A wing length, B wing width, C tail length, D tail width,
  E body height, F paperclip count, G fold height
Stage 1: screening, 16-run 2^(7-3) resolution IV fractional factorial.
Stage 2: steepest ascent along the screened gradient.
Stage 3: rotatable CCD (alpha = 2) in A, B, C around the rising ridge,
         quadratic fit + analytic optimum (solve grad = 0 via 3x3 solve).
Seed 41001. Regenerates helicopter-rsm.csv; re-derives everything from disk.
"""
import csv, math, random, statistics as st

SEED = 41001
BASE = __file__.rsplit("/", 1)[0]
NAMES = ["wing_len", "wing_wid", "tail_len", "tail_wid",
         "body_hgt", "clips", "fold_hgt"]

# natural units mapping (coded -1..+1)
NAT = [("A wing length mm", 70, 130), ("B wing width mm", 25, 55),
       ("C tail length mm", 40, 80), ("D tail width mm", 15, 35),
       ("E body height mm", 20, 40), ("F paperclips", 0, 2),
       ("G fold height mm", 10, 30)]

def true_time(x):
    """x = list of 7 coded values. True physics-ish surface (s)."""
    a, b, c = x[0], x[1], x[2]
    d, e, f, g = x[3], x[4], x[5], x[6]
    t = (4.20 + 0.90 * a + 0.50 * b - 0.30 * c + 0.08 * d - 0.05 * e
         + 0.03 * f - 0.02 * g
         - 0.45 * a * a - 0.55 * b * b - 0.20 * c * c
         + 0.15 * a * b + 0.04 * b * c)
    return t

def fly(x):
    t0 = true_time(x)
    drops = [random.gauss(t0, 0.06) for _ in range(3)]
    return st.median(drops), drops

# ---- 16-run 2^(7-3) resolution IV design: generators F=ABC, G=BCD, E=ACD ----
def frac_design():
    runs = []
    for s in range(16):
        a, b, c, d = ((s >> 3) & 1, (s >> 2) & 1, (s >> 1) & 1, s & 1)
        a, b, c, d = 2 * a - 1, 2 * b - 1, 2 * c - 1, 2 * d - 1
        e = a * c * d
        f = a * b * c
        g = b * c * d
        runs.append([a, b, c, d, e, f, g])
    return runs

def generate():
    random.seed(SEED)
    with open(f"{BASE}/helicopter-rsm.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["stage", "run", "phase"] + [f"x{i+1}_{n}" for i, n in
                                                enumerate(NAMES)] +
                   ["drop1_s", "drop2_s", "drop3_s", "median_s"])
        for i, x in enumerate(frac_design(), 1):
            m, drops = fly(x)
            w.writerow(["screen", i, "2v7-3_resIV"] +
                       [int(v) for v in x] +
                       [round(d, 2) for d in drops] + [round(m, 2)])

        # stage 2/3 rows are appended by append_stage2() after the stage-1 fit

def pad7(x):
    return list(x) + [0] * (7 - len(x))

def append_stage2(steps):
    random.seed(SEED + 1)
    rows = list(csv.reader(open(f"{BASE}/helicopter-rsm.csv")))
    n0 = len(rows)
    for j, x in enumerate(steps, 1):
        m, drops = fly(pad7(x))
        rows.append(["ascent", n0 - 1 + j, f"step{j}"] +
                    [f"{v:.3f}" for v in x] +
                    ["0.000"] * (7 - len(x)) +
                    [round(d, 2) for d in drops] + [round(m, 2)])
    random.seed(SEED + 2)
    # stage 3: CCD in A,B,C around the ascent peak (step3, rounded), alpha=2
    cx = (1.25, 0.70, -0.70)
    import itertools
    pts = []
    for a, b, c in itertools.product((-1, 1), repeat=3):
        pts.append((cx[0] + a, cx[1] + b, cx[2] + c))
    for axis in range(3):
        for sgn in (-2, 2):
            p = list(cx)
            p[axis] = cx[axis] + sgn
            pts.append(tuple(p))
    for _ in range(5):
        pts.append(cx)
    with open(f"{BASE}/helicopter-rsm.csv", "w", newline="") as f2:
        w2 = csv.writer(f2)
        w2.writerows(rows)
        n = len(rows) + 1
        for j, x in enumerate(pts, 1):
            m, drops = fly(pad7(x))
            tag = ("axial" if max(abs(x[i] - cx[i]) for i in range(3)) > 1.5
                   else "center" if x == cx else "factorial")
            w2.writerow(["ccd", n + j - 1 + 1, tag] +
                        [f"{v:.3f}" for v in x] +
                        ["0.000"] * (7 - len(x)) +
                        [round(d, 2) for d in drops] + [round(m, 2)])

# --------------------------------------------------------- stage 1 analysis
def ols(X, y):
    p = len(X[0])
    XtX = [[sum(r[i] * r[j] for r in X) for j in range(p)] for i in range(p)]
    Xty = [sum(r[i] * v for r, v in zip(X, y)) for i in range(p)]
    A = [XtX[i] + [Xty[i]] for i in range(p)]
    for col in range(p):
        piv = max(range(col, p), key=lambda r: abs(A[r][col]))
        A[col], A[piv] = A[piv], A[col]
        for r in range(p):
            if r != col:
                fac = A[r][col] / A[col][col]
                A[r] = [A[r][k] - fac * A[col][k] for k in range(p + 1)]
    return [A[i][p] / A[i][i] for i in range(p)]

generate()
rows = [r for r in csv.DictReader(open(f"{BASE}/helicopter-rsm.csv"))
        if r["stage"] == "screen"]
print("== Module 41 solution key: helicopter sequential RSM ==")
X = [[1.0] + [float(r[f"x{i+1}_{n}"]) for i, n in enumerate(NAMES)] for r in rows]
y = [float(r["median_s"]) for r in rows]
b = ols(X, y)
print("\n-- stage 1: screening effects (16-run res IV, y = median descent s) --")
print(f"  intercept {b[0]:.3f}")
for i, nm in enumerate(NAMES):
    star = "  <== ACTIVE" if abs(b[i + 1]) > 0.15 else ""
    print(f"  {nm:<10} coef {b[i + 1]:+.3f} s (effect = {2 * b[i + 1]:+.3f}){star}")
active = [i for i in range(7) if abs(b[i + 1]) > 0.15]
print(f"active set: {[NAMES[i] for i in active]}")

# --------------------------------------------------- stage 2: steepest ascent
g = tuple(b[i + 1] for i in (0, 1, 2))   # A, B, C gradient
norm = math.sqrt(sum(v * v for v in g))
step = tuple(0.5 * v / norm for v in g)  # half-unit steps along gradient
cx0 = (0.0, 0.0, -0.3)                   # start near screen-indicated center
steps = []
for j in range(1, 5):
    steps.append(tuple(cx0[k] + j * step[k] for k in range(3)))
append_stage2(steps)

rows2 = [r for r in csv.DictReader(open(f"{BASE}/helicopter-rsm.csv"))
         if r["stage"] == "ascent"]
print("\n-- stage 2: steepest ascent (half-unit steps on A,B,C; D-G held 0) --")
for r in rows2:
    print(f"  {r['phase']}  A={float(r['x1_wing_len']):+.2f} "
          f"B={float(r['x2_wing_wid']):+.2f} C={float(r['x3_tail_len']):+.2f}"
          f"   median = {r['median_s']} s")
asc = [(float(r["median_s"]), r["phase"]) for r in rows2]
peak = max(asc)
stop = next(i for i in range(1, len(asc)) if asc[i][0] < asc[i - 1][0])
print(f"  -> improvement stops after {asc[stop - 1][1]} "
      f"({asc[stop - 1][0]:.2f} s peak); CCD centered there")

# --------------------------------------------------- stage 3: CCD + quadratic
rows3 = [r for r in csv.DictReader(open(f"{BASE}/helicopter-rsm.csv"))
         if r["stage"] == "ccd"]
print(f"\n-- stage 3: rotatable CCD (alpha=2) in A,B,C: "
      f"{sum(1 for r in rows3 if r['phase']=='factorial')} factorial + "
      f"{sum(1 for r in rows3 if r['phase']=='axial')} axial + "
      f"{sum(1 for r in rows3 if r['phase']=='center')} center runs --")
X3 = [[1.0] + [float(r[f"x{i+1}_{n}"]) for i, n in enumerate(NAMES[:3])] +
      [float(r["x1_wing_len"]) * float(r["x2_wing_wid"]),
       float(r["x1_wing_len"]) * float(r["x3_tail_len"]),
       float(r["x2_wing_wid"]) * float(r["x3_tail_len"])] +
      [float(r["x1_wing_len"]) ** 2, float(r["x2_wing_wid"]) ** 2,
       float(r["x3_tail_len"]) ** 2] for r in rows3]
y3 = [float(r["median_s"]) for r in rows3]
b3 = ols(X3, y3)
b0, bA, bB, bC = b3[0], b3[1], b3[2], b3[3]
bAB, bAC, bBC = b3[4], b3[5], b3[6]
bAA, bBB, bCC = b3[7], b3[8], b3[9]
print("quadratic fit (coded):")
print(f"  T = {b0:.3f} {bA:+.3f}A {bB:+.3f}B {bC:+.3f}C "
      f"{bAB:+.3f}AB {bAC:+.3f}AC {bBC:+.3f}BC "
      f"{bAA:+.3f}A^2 {bBB:+.3f}B^2 {bCC:+.3f}C^2")
res = [v - sum(c * xx for c, xx in zip(b3, X3[i])) for i, v in enumerate(y3)]
s_res = math.sqrt(sum(e * e for e in res) / (len(res) - 10))
print(f"  residual SD = {s_res:.3f} s on {len(res) - 10} df")

# analytic optimum: solve dT/dA = dT/dB = dT/dC = 0
M = [[2 * bAA, bAB, bAC],
     [bAB, 2 * bBB, bBC],
     [bAC, bBC, 2 * bCC]]
v = [-bA, -bB, -bC]
# solve M x = v (3x3) by Gaussian elimination with partial pivoting
A = [list(M[i]) + [v[i]] for i in range(3)]
for col in range(3):
    piv = max(range(col, 3), key=lambda r: abs(A[r][col]))
    A[col], A[piv] = A[piv], A[col]
    for r in range(3):
        if r != col:
            fac = A[r][col] / A[col][col]
            A[r] = [A[r][k] - fac * A[col][k] for k in range(4)]
xopt = [A[i][3] / A[i][i] for i in range(3)]
Topt = (b0 + bA * xopt[0] + bB * xopt[1] + bC * xopt[2]
        + bAB * xopt[0] * xopt[1] + bAC * xopt[0] * xopt[2]
        + bBC * xopt[1] * xopt[2]
        + bAA * xopt[0] ** 2 + bBB * xopt[1] ** 2 + bCC * xopt[2] ** 2)
print("\n-- optimum search (canonical: grad = 0) --")
print(f"  stationary point (coded): A {xopt[0]:+.3f}, B {xopt[1]:+.3f}, "
      f"C {xopt[2]:+.3f}")
print(f"  predicted descent time at optimum: {Topt:.3f} s")
for i, nm in enumerate(NAT[:3]):
    nm_, lo, hi = nm
    center = (lo + hi) / 2
    nat = center + xopt[i] * (hi - lo) / 2
    print(f"  {nm_:<20} natural = {nat:.1f} (range {lo}-{hi})")

# confirmation run at the optimum (3 drops, median)
random.seed(SEED + 3)
m, drops = fly(pad7(xopt))
print(f"\nconfirmation at optimum: drops {[round(d, 2) for d in drops]}"
      f" -> median {m:.2f} s (true surface {true_time(pad7(xopt)):.3f} s)")
base_c = (0.0, 0.0, -0.3, 0, 0, 0, 0)
scr = [r for r in csv.DictReader(open(f"{BASE}/helicopter-rsm.csv"))
       if r["stage"] == "screen"]
gmean = st.mean([float(r["median_s"]) for r in scr])
print(f"screening grand mean (16 corner runs): {gmean:.2f} s"
      f" -> confirmation median {m:.2f} s  = {m - gmean:+.2f} s improvement")
print(f"total runs consumed: screen 16 + ascent 4 + CCD 19 + confirmation = 40")
