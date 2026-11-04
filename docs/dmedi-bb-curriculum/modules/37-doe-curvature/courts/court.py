#!/usr/bin/env python3
"""Module 37 court — independent re-derivation of the curvature test.
Re-derives from bore-curvature.csv (own implementation, not compute.py) and
asserts the published numbers. Exit 0 = PASS, 1 = FAIL.
"""
import csv, math, statistics as st, sys

CSV = __file__.replace("courts/court.py", "data/bore-curvature.csv")
fails = []

def check(nm, got, exp, tol=0.01):
    ok = abs(got - exp) <= tol
    if not ok:
        fails.append(nm)
    print(f"  {'PASS' if ok else 'FAIL'}  {nm}: got {got:.4f} expected {exp}")

rows = list(csv.DictReader(open(CSV)))
fac = [r for r in rows if r["center"] == "0"]
ctr = [r for r in rows if r["center"] == "1"]
y_fac = [float(r["y_um"]) for r in fac]
y_ctr = [float(r["y_um"]) for r in ctr]

yF, yC = st.mean(y_fac), st.mean(y_ctr)
diff = yF - yC
sF, sC = st.stdev(y_fac), st.stdev(y_ctr)
nF, nC = len(y_fac), len(y_ctr)
sp = math.sqrt(((nF - 1) * sF**2 + (nC - 1) * sC**2) / (nF + nC - 2))
t = diff / (sp * math.sqrt(1 / nF + 1 / nC))

print("MODULE 37 COURT")
check("n factorial obs", nF, 16, 0)
check("n center obs", nC, 6, 0)
check("ybar corner", yF, 11.590)
check("ybar center", yC, 5.390)
check("diff", diff, 6.200)
check("pooled SD", sp, 3.067)
check("t statistic", t, 4.223)
check("verdict fires (|t|>2.131)", 1.0 if abs(t) > 2.131 else 0.0, 1.0, 0.0)

# factorial effects via contrast sums (different route than compute.py)
X = [(-1, -1, -1), (+1, -1, -1), (-1, +1, -1), (+1, +1, -1),
     (-1, -1, +1), (+1, -1, +1), (-1, +1, +1), (+1, +1, +1)]
yc = {}
for r in fac:
    key = (int(r["A_speed_coded"]), int(r["B_feed_coded"]),
           int(r["C_coolant_coded"]))
    yc[key] = st.mean([float(x["y_um"]) for x in fac
                       if (int(x["A_speed_coded"]), int(x["B_feed_coded"]),
                           int(x["C_coolant_coded"])) == key])
for k, (nm, coef) in enumerate({
        "E(A)": ([-1, 1, -1, 1, -1, 1, -1, 1]),
        "E(B)": ([-1, -1, 1, 1, -1, -1, 1, 1]),
        "E(C)": ([-1, -1, -1, -1, 1, 1, 1, 1]),
        "E(AB)": ([1, -1, -1, 1, 1, -1, -1, 1]),
}.items()):
    eff = sum(c * v for c, v in zip(coef, yc.values())) / 4
    check(f"{nm} (contrast route)", eff, {"E(A)": -4.450, "E(B)": 2.255,
                                          "E(C)": 0.665, "E(AB)": 1.600}[nm])

# non-vacuity: truncating center points must move the t statistic
y_ctr_trunc = y_ctr[:2]
sp2 = math.sqrt(((nF - 1) * sF**2 + (len(y_ctr_trunc) - 1) *
                 st.stdev(y_ctr_trunc)**2) / (nF + len(y_ctr_trunc) - 2))
t2 = diff / (nF and sp2 * math.sqrt(1 / nF + 1 / len(y_ctr_trunc)))
check("non-vacuity: t moves with nC=2", 1.0 if abs(t2 - t) > 0.5 else 0.0, 1.0, 0.0)

# outline coherence: published numbers appear in the slides outline
md = open(__file__.replace("courts/court.py", "slides-outline.md")).read()
for token in ("11.590", "5.390", "4.223", "+6.200", "-4.450", "+2.255"):
    check(f"outline cites {token}", 1.0 if token in md else 0.0, 1.0, 0.0)

print(f"\nMODULE 37 COURT: {'PASS' if not fails else 'FAIL'} "
      f"({len(fails)} failures)")
sys.exit(1 if fails else 0)
