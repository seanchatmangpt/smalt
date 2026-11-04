#!/usr/bin/env python3
"""Module 37 solution key — center-point curvature test + axial-path logic.
Running case: CPPC bore diameter. Response y = bore deviation from 12.000 mm, um.
Synthetic data, seed 37001 (python3 random module). Regenerates bore-curvature.csv
then re-derives every printed number from the CSV on disk.
"""
import csv, math, random, statistics as st

SEED = 37001
CSV = __file__.replace("compute.py", "bore-curvature.csv")

# ---------------------------------------------------------------- generation
def generate():
    random.seed(SEED)
    # True surface (coded units, A=speed, B=feed, C=coolant conc):
    # y = 9.0 - 2.2A + 1.4B + 0.9C + 1.1AB - 3.0*(pure quadratic block)
    # Pure quadratic represented via center vs factorial offset:
    #   at center (0,0,0) the linear+interaction model predicts 9.0,
    #   true process mean at center is 5.6  -> curvature offset = -3.4 um.
    X = [(-1, -1, -1), (+1, -1, -1), (-1, +1, -1), (+1, +1, -1),
         (-1, -1, +1), (+1, -1, +1), (-1, +1, +1), (+1, +1, +1)]
    rows = []
    for i, (a, b, c) in enumerate(X, 1):
        # curvature: quadratic surface pulls center points DOWN relative to
        # what the planar factorial model predicts; approximate by lifting
        # corner responses (quadratic term pushes corners up when curvature is
        # negative at center). Corner lift = +3.4*(3/4) scaled by |a|+|b|+|c| ...
        mean = 9.0 - 2.2 * a + 1.4 * b + 0.9 * c + 1.1 * (a * b) + 2.55
        for rep in (1, 2):
            y = random.gauss(mean, 2.5)
            rows.append([i, a, b, c, 0, rep, round(y, 2)])
    for j, rep in enumerate((1, 2, 3, 4, 5, 6), 1):
        y = random.gauss(5.6, 2.5)
        rows.append([9, 0, 0, 0, 1, rep, round(y, 2)])
    with open(CSV, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["std", "A_speed_coded", "B_feed_coded", "C_coolant_coded",
                    "center", "rep", "y_um"])
        w.writerows(rows)

# ---------------------------------------------------------------- analysis
generate()  # seed-stated, deterministic; overwrites identical file
rows = list(csv.DictReader(open(CSV)))
fac = sorted([r for r in rows if r["center"] == "0"], key=lambda r: int(r["std"]))
y_fac = [float(r["y_um"]) for r in fac]
y_ctr = [float(r["y_um"]) for r in rows if r["center"] == "1"]
X = [(-1, -1, -1), (+1, -1, -1), (-1, +1, -1), (+1, +1, -1),
     (-1, -1, +1), (+1, -1, +1), (-1, +1, +1), (+1, +1, +1)]
y = [st.mean([float(r["y_um"]) for r in fac
              if (int(r["A_speed_coded"]), int(r["B_feed_coded"]),
                  int(r["C_coolant_coded"])) == x]) for x in X]

print("== Module 37 solution key: center-point curvature test ==")
print(f"factorial points: 8 corners x 2 reps = {len(y_fac)} obs")
print(f"center points: n={len(y_ctr)}")

nF, nC = len(y_fac), len(y_ctr)
ybarF, ybarC = st.mean(y_fac), st.mean(y_ctr)
sF = st.stdev(y_fac)
sC = st.stdev(y_ctr)
s_pool = math.sqrt(((nF - 1) * sF**2 + (nC - 1) * sC**2) / (nF + nC - 2))
se = s_pool * math.sqrt(1 / nF + 1 / nC)
t = (ybarF - ybarC) / se
print(f"\n-- center-point curvature test --")
print(f"ybar(fact) = {ybarF:.3f} um   ybar(center) = {ybarC:.3f} um")
print(f"diff = {ybarF - ybarC:+.3f} um")
print(f"s_fact = {sF:.3f}, s_center = {sC:.3f}, s_pooled = {s_pool:.3f}")
print(f"SE(diff) = {se:.3f}  ->  t = {t:.3f}, df = {nF + nC - 2}")
print(f"t_crit(0.025, {nF + nC - 2}) = 2.131  ->  "
      f"{'CURVATURE PRESENT' if abs(t) > 2.131 else 'no curvature evidence'}")

# ---------------------------------------------------- factorial main effects
def eff(k):
    hi = [yi for yi, x in zip(y, X) if x[k] == 1]
    lo = [yi for yi, x in zip(y, X) if x[k] == -1]
    return st.mean(hi) - st.mean(lo)

EA, EB, EC = eff(0), eff(1), eff(2)
EAB = st.mean([yi for yi, x in zip(y, X) if x[0] * x[1] == 1]) - \
      st.mean([yi for yi, x in zip(y, X) if x[0] * x[1] == -1])
print(f"\n-- factorial effects (from 8 corner means) --")
print(f"E(A speed)    = {EA:+.3f} um")
print(f"E(B feed)     = {EB:+.3f} um")
print(f"E(C coolant)  = {EC:+.3f} um")
print(f"E(AB)         = {EAB:+.3f} um")

# pure-error SD from corner replicates
res = []
for x in X:
    obs = [float(r["y_um"]) for r in fac
           if (int(r["A_speed_coded"]), int(r["B_feed_coded"]),
               int(r["C_coolant_coded"])) == x]
    res.append(st.stdev(obs))
s_pe = st.mean(res) if all(v == v for v in res) else 0
print(f"mean within-corner SD (pure error) ~= {st.mean(res):.3f} um (2 reps/corner)")

# --------------------------------------------------------- axial path logic
# Planar model: yhat = b0 + bA*A + bB*B + bC*C (+bAB*AB)
b0 = st.mean(y)
bA, bB, bC = EA / 2, EB / 2, EC / 2
bAB = EAB / 2
print(f"\n-- fitted planar model (coded) --")
print(f"yhat = {b0:.3f} {bA:+.3f}A {bB:+.3f}B {bC:+.3f}C {bAB:+.3f}AB")
g = (bA, bB, bC)
norm = math.sqrt(sum(v * v for v in g))
unit = tuple(v / norm for v in g)
print(f"gradient = ({bA:.3f}, {bB:.3f}, {bC:.3f});  |g| = {norm:.3f}")
print(f"unit step (descent, toward 12.000 um) = "
      f"({-unit[0]:+.4f}, {-unit[1]:+.4f}, {-unit[2]:+.4f})")
print("axial path: each step of delta (coded) moves "
      f"({-unit[0]*1:+.3f}A, {-unit[1]*1:+.3f}B, {-unit[2]*1:+.3f}C) per unit delta")
