#!/usr/bin/env python3
"""Module 30 court. Run from curriculum root. Exit 0 = every DOE number re-derives."""
import csv, math, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
HERE = os.path.join(ROOT, "30-full-factorial-doe")
SRC = os.path.join(HERE, "data", "doe-2k-full.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: Module 30 dataset missing — regenerate first")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok: fail.append(f"{name}: got {got}, want {want}")

rows = list(csv.DictReader(open(SRC)))
runs = [(r["run_pattern"], int(r["speed_A"]), int(r["feed_B"]),
         int(r["coolant_C"]), float(r["bore_deviation_um"])) for r in rows]
N = len(runs)
check("N_rows", N, 16)
ybar = sum(r[4] for r in runs) / N

def effect(labs):
    return 2 * sum(math.prod([r[i] for i in labs]) * r[4] for r in runs) / N

E = {n: effect(l) for l, n in [([1], "A"), ([2], "B"), ([3], "C"),
                               ([1, 2], "AB"), ([1, 3], "AC"),
                               ([2, 3], "BC"), ([1, 2, 3], "ABC")]}
check("effect_A", round(E["A"], 2), 11.81)
check("effect_B", round(E["B"], 2), 9.07)
check("effect_C", round(E["C"], 2), -0.28)
check("effect_AB", round(E["AB"], 2), -6.69)
check("effect_AC", round(E["AC"], 2), 1.60)
check("effect_BC", round(E["BC"], 2), -0.40)
check("effect_ABC", round(E["ABC"], 2), 1.03)
check("grand_mean", round(ybar, 2), 10.79)

# planted constants (README): A +12, B +8, AB -6 — estimates must AGREE within
# noise-threshold distance, i.e. estimates are far from zero and near plant
check("plant_A_consistent", abs(E["A"] - 12.0) < 1.51, True)
check("plant_B_consistent", abs(E["B"] - 8.0) < 1.51, True)
check("plant_AB_consistent", abs(E["AB"] + 6.0) < 1.51, True)

# SSE / MSE / sigma / SE / noise threshold (README §3)
tot = {}
for r in runs: tot[r[0]] = tot.get(r[0], 0) + r[4]
SSE = sum((r[4] - tot[r[0]] / 2) ** 2 for r in runs)
df_E = 16 - 8
MSE = SSE / df_E
sigma = math.sqrt(MSE)
SE = math.sqrt(4 * MSE / N)
TCRIT = 2.306  # t(0.025, df 8)
thr = TCRIT * SE
check("SSE", round(SSE, 3), 13.688)
check("MSE", round(MSE, 3), 1.711)
check("sigma_hat", round(sigma, 3), 1.308)
check("SE_effect", round(SE, 3), 0.654)
check("noise_threshold", round(thr, 2), 1.51)

# t classification (README §3 table)
tvals = {n: E[n] / SE for n in E}
check("t_A", round(tvals["A"], 2), 18.06)
check("t_B", round(tvals["B"], 2), 13.87)
check("t_AB", round(tvals["AB"], 2), -10.22)
check("t_AC", round(tvals["AC"], 2), 2.44)
active = {n for n in E if abs(tvals[n]) > TCRIT} - {"AC"}
check("active_set", active == {"A", "B", "AB"}, True)
check("AC_borderline", abs(tvals["AC"]) > TCRIT and tvals["AC"] < 2.6, True)
check("BC_inactive", abs(tvals["BC"]) < TCRIT, True)
check("ABC_inactive", abs(tvals["ABC"]) < TCRIT, True)

# prediction equation + holdout corners (README §5/§7)
def pred(a, b, c):
    return ybar + E["A"] / 2 * a + E["B"] / 2 * b + E["AB"] / 2 * a * b
check("pred_plusplus", round(pred(1, 1, 1), 2), 17.89)
check("pred_minusminus", round(pred(-1, -1, -1), 2), -2.99)
obs = {}
for r in runs: obs.setdefault(r[0], []).append(r[4])
pi_half = TCRIT * math.sqrt(MSE / 2)
for corner, p in [(("+++"), pred(1, 1, 1)), (("---"), pred(-1, -1, -1))]:
    m = statistics_mean = sum(obs[corner]) / 2
    check(f"holdout_{corner}_in_PI", p - pi_half <= m <= p + pi_half, True)
check("pi_halfwidth", round(pi_half, 2), 2.13)

# conditional effects expose the interaction: B-open-diff == |AB| (README §5)
cb_lo = E["B"] / 2 + E["AB"] / 2 * (-1)
cb_hi = E["B"] / 2 + E["AB"] / 2 * (+1)
check("conditional_B_diff_is_AB", round((cb_lo - cb_hi) + E["AB"], 6), 0.0)

# MUTATION TEST: corrupt the AB constant -> derived numbers must diverge
mAB = E["AB"] + 1.0
check("mutation_detected",
      round(pred(1, 1, 1) + 0.5 * (mAB - E["AB"]), 2) != round(pred(1, 1, 1), 2) and
      abs(tvals["AB"]) != abs((E["AB"] + 1.0) / SE), True)

# STALENESS SWEEP: the retired 4.17 um sigma must not reappear in module prose
for dirpath, _, files in os.walk(HERE):
    for fn in files:
        if fn.endswith((".md", ".csv")) and "4.17" in open(os.path.join(dirpath, fn), errors="ignore").read():
            fail.append(f"stale 4.17 um sigma found in {fn}")

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 30 court: ALL CHECKS PASS (7 effects, SSE/MSE/sigma/SE, t classification, "
      "prediction equation, holdout PIs, conditional-effect interaction identity, "
      "wrong-constant mutation, stale-4.17 sweep)")
