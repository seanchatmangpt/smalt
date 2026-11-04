#!/usr/bin/env python3
"""Module 21 court. Run from curriculum root. Exit 0 = every test statistic re-derives."""
import csv, math, sys, os
import numpy as np
from scipy import stats

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "21-testing-means-medians-variances", "data")
for f in ("coating-ab-bore.csv", "paired-feed.csv", "coolant-anova.csv"):
    if not os.path.exists(os.path.join(D, f)):
        sys.exit(f"VACUOUS COURT: Module 21 dataset missing: {f}")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok: fail.append(f"{name}: got {got}, want {want}")

# --- §2 pooled 2-sample t (coating A vs B, seed 42191)
rows = list(csv.DictReader(open(os.path.join(D, "coating-ab-bore.csv"))))
A = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "A"])
B = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "B"])
nA = nB = 30
check("nA", len(A), nA); check("nB", len(B), nB)
mA, mB = A.mean(), B.mean()
sA, sB = A.std(ddof=1), B.std(ddof=1)
sp = math.sqrt(((nA - 1) * sA**2 + (nB - 1) * sB**2) / (nA + nB - 2))
t = (mA - mB) / (sp * math.sqrt(1 / nA + 1 / nB))
df = nA + nB - 2
p = 2 * stats.t.sf(abs(t), df)
check("meanA", round(mA, 4), 12.0061)
check("sA", round(sA, 4), 0.0041)
check("meanB", round(mB, 4), 12.0016)
check("sB", round(sB, 4), 0.0043)
check("pooled_sp", round(sp, 4), 0.0042)
check("t_pooled", round(t, 3), 4.187)
check("tcrit_58", round(stats.t.ppf(0.975, df), 3), 2.002)
check("p_pooled", p < 1e-4 and round(p * 1e5, 0) == round(9.72, 0), True)
check("decision_reject", p < 0.05, True)

# --- §2b Welch
tw, pw = stats.ttest_ind(A, B, equal_var=False)
check("t_welch", round(tw, 3), 4.187)
check("df_welch", round(stats.ttest_ind(A, B, equal_var=False).df, 1), 57.8)
check("p_welch", round(pw * 1e5, 1), 9.8, 0.1)

# --- §3 paired t (paired-feed, seed 42192)
rows = list(csv.DictReader(open(os.path.join(D, "paired-feed.csv"))))
bef = np.array([float(r["before_mm"]) for r in rows])
aft = np.array([float(r["after_mm"]) for r in rows])
d = aft - bef; n = len(d)
check("n_pairs", n, 25)
db, sd = d.mean(), d.std(ddof=1)
tp = db / (sd / math.sqrt(n))
pp = 2 * stats.t.sf(abs(tp), n - 1)
tc = stats.t.ppf(0.975, n - 1)
ci = (db - tc * sd / math.sqrt(n), db + tc * sd / math.sqrt(n))
check("dbar", round(db, 4), -0.0030)
check("s_d", round(sd, 4), 0.0022)
check("t_paired", round(tp, 3), -6.924)
check("df_paired", n - 1, 24)
check("tcrit_24", round(tc, 3), 2.064)
check("p_paired", round(pp * 1e7, 1), 3.68, 0.1)
check("ci_lo", round(ci[0], 4), -0.0039)
check("ci_hi", round(ci[1], 4), -0.0021)
# 400x contrast: unpaired t on the same data
ti, pi = stats.ttest_ind(bef, aft, equal_var=True)
check("unpaired_t", round(ti, 3), 2.508)
check("unpaired_p", round(pi, 4), 0.0156)
check("p_ratio_order", pp / pi < 0.01, True)

# --- §4 Levene / Bartlett (A vs B)
W, pl = stats.levene(A, B, center="median")
check("levene_W", round(W, 3), 0.053)
check("levene_p", round(pl, 3), 0.819)
K2, pb = stats.bartlett(A, B)
check("bartlett_K2", round(K2, 3), 0.086)
check("bartlett_p", round(pb, 3), 0.770)

# --- §5 Mann-Whitney U
U, pu = stats.mannwhitneyu(A, B, alternative="two-sided")
check("MWU_U", U, 726)
check("MWU_p", round(pu * 1e5, 1), 4.62, 0.1)

# --- §6 one-way ANOVA (coolant, seed 42193)
rows = list(csv.DictReader(open(os.path.join(D, "coolant-anova.csv"))))
g = {}
for r in rows: g.setdefault(r["coolant_pct"], []).append(float(r["bore_mm"]))
gs = [np.array(v) for v in g.values()]
N = sum(len(x) for x in gs); k = len(gs)
grand = np.concatenate(gs).mean()
SSB = sum(len(x) * (x.mean() - grand) ** 2 for x in gs)
SSW = sum(((x - x.mean()) ** 2).sum() for x in gs)
SST = SSB + SSW
F = (SSB / (k - 1)) / (SSW / (N - k))
pf = 1 - stats.f.cdf(F, k - 1, N - k)
check("SSB", round(SSB, 8), 0.00044544)
check("SSW", round(SSW, 8), 0.00046799)
check("SST", round(SST, 8), 0.00091343)
check("df_between", k - 1, 2); check("df_within", N - k, 27)
check("F", round(F, 3), 12.850)
check("p_anova", round(pf * 1e5, 1), 12.0, 0.5)
check("Fcrit", round(stats.f.ppf(0.95, k - 1, N - k), 3), 3.354)
check("mean_5pct", round(g["5"] and float(np.mean(g["5"])), 4), 12.0081)
check("mean_8pct", round(float(np.mean(g["8"])), 4), 12.0069)
check("mean_12pct", round(float(np.mean(g["12"])), 4), 11.9993)
# pairwise MSW-based CIs (README §6 table)
MSW = SSW / (N - k); tc27 = stats.t.ppf(0.975, N - k)
names = list(g)
expect = {(0, 1): (0.0012, False), (0, 2): (0.0087, True), (1, 2): (0.0075, True)}
for (i, j), (want_diff, want_sig) in expect.items():
    diff = gs[i].mean() - gs[j].mean()
    se = math.sqrt(MSW * (1 / len(gs[i]) + 1 / len(gs[j])))
    check(f"diff_{names[i]}_{names[j]}", round(diff, 4), want_diff)
    check(f"sig_{names[i]}_{names[j]}", abs(diff) > tc27 * se, want_sig)

# MUTATION TEST: corrupt the ANOVA group assignment -> F must diverge
rows_mut = [dict(r) for r in rows]
rows_mut[0]["coolant_pct"] = "8"          # flip one part across groups
gm = {}
for r in rows_mut: gm.setdefault(r["coolant_pct"], []).append(float(r["bore_mm"]))
gsm = [np.array(v) for v in gm.values()]
SSBm = sum(len(x) * (x.mean() - grand) ** 2 for x in gsm)
SSWm = sum(((x - x.mean()) ** 2).sum() for x in gsm)
Fm = (SSBm / 2) / (SSWm / 27)
check("mutation_detected", round(Fm, 3) != round(F, 3), True)

# STALENESS SWEEP: retired 4.17 um sigma must not reappear in module prose
HERE = os.path.join(ROOT, "21-testing-means-medians-variances")
for dirpath, _, files in os.walk(HERE):
    for fn in files:
        if fn.endswith((".md", ".csv")) and "4.17" in open(os.path.join(dirpath, fn), errors="ignore").read():
            fail.append(f"stale 4.17 um sigma found in {fn}")

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 21 court: ALL CHECKS PASS (pooled+Welch t, paired t + 400x contrast, "
      "Levene/Bartlett, Mann-Whitney, one-way ANOVA + pairwise CIs, "
      "group-corruption mutation, stale-4.17 sweep)")
