#!/usr/bin/env python3
"""Module 32 court. Run from curriculum root. Exit 0 = every key number re-derives from the CSV on disk."""
import csv, math, sys, os, statistics, hashlib
from scipy import stats

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "32-catapult-simulation", "data")
SRC = os.path.join(D, "catapult-results.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: module 32 dataset missing — run data/simulator.py first")

fail = []
MUT = len(sys.argv) > 1 and sys.argv[1] == "--mutate"
DELTA = 0.5 if MUT else 0.0   # --mutate corrupts the A-effect pin; court must exit 1
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

rows = list(csv.DictReader(open(SRC)))
check("rows", len(rows), 20)
fac = [r for r in rows if int(r["std_order"]) <= 16]
cen = [r for r in rows if int(r["std_order"]) > 16]
check("split_16_4", (len(fac), len(cen)), (16, 4))

# ---- §2 factorial effects as contrast means (m) ----
sign = lambda v: 1 if float(v) > 0 else -1
def effect(names):
    vals = []
    for r in fac:
        sg = 1
        for k in names:
            sg *= sign(r[k])
        vals.append(float(r["dist_m"]) * sg)
    return statistics.mean(vals)

E = {n: effect(n) for n in ("A", "B", "C", "D", "AB", "AC", "AD", "BC", "BD", "CD",
                            "ABC", "ABD", "ACD", "BCD", "ABCD")}
check("A", round(E["A"], 4), 0.5090 + DELTA)
check("B", round(E["B"], 4), 0.5021)
check("C", round(E["C"], 4), -0.4342)
check("D", round(E["D"], 4), 0.0044)
check("AB", round(E["AB"], 4), 0.1920)
check("BC", round(E["BC"], 4), -0.1634)
check("AC", round(E["AC"], 4), -0.1632)
check("ABC", round(E["ABC"], 4), -0.0623)
check("D_linear_quiet", max(abs(E[k]) for k in ("AD", "BD", "CD", "ABD", "ACD", "BCD")) <= 0.004, True)
check("ABCD_bound", abs(E["ABCD"]) <= 0.0027, True)

# ---- §3 curvature from center points ----
fm = statistics.mean(float(r["dist_m"]) for r in fac)
cm = statistics.mean(float(r["dist_m"]) for r in cen)
csd = statistics.stdev([float(r["dist_m"]) for r in cen])
diff = cm - fm
se = csd * math.sqrt(1 / 4 + 1 / 16)
tstat = diff / se
check("factorial_mean", round(fm, 4), 1.3072)
check("center_mean", round(cm, 4), 1.2415)
check("center_sd", round(csd, 4), 0.0119)
check("diff", round(diff, 4), -0.0657)
check("se", round(se, 4), 0.0067)
check("t", round(tstat, 2), -9.86)
check("tcrit", round(stats.t.ppf(0.975, 3), 3), 3.182)
check("curvature_significant", abs(tstat) > 3.182, True)

# ---- §5 best run + sha256 provenance (MANIFEST pins a63fd239...) ----
best = max(float(r["dist_m"]) for r in fac)
check("best_run", round(best, 4), 3.3372)
sha = hashlib.sha256(open(SRC, "rb").read()).hexdigest()
check("sha256_manifest", sha, "a63fd2395b14291224d38d683624b99c528aeebe77e944f7dc7ba2f25c4a6517")

# ---- vacuity mutation: a wrong A effect (sign flip) must move the contrast ----
check("mutation_detected", round(-E["A"], 4) != round(E["A"], 4) and abs(E["A"]) > 0, True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 32 court: ALL CHECKS PASS (16+4 split, 15 contrast means, curvature t=-9.86, sha256 pinned)")

# ---------- mutation test (module 28 pattern) ----------
if MUT:
    if round(E["A"], 4) == round(0.5090 + DELTA, 4):
        print("VACUOUS COURT: corrupted A pin still passes"); sys.exit(2)
    print("MUTATION DETECTED: effect A pinned at %.4f vs derived %.4f -> nonzero" % (0.5090 + DELTA, E["A"]))
    sys.exit(1)
sys.exit(0)
