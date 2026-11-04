#!/usr/bin/env python3
"""Module 22 court. Run from curriculum root. Exit 0 = every key number re-derives."""
import csv, math, sys, os
import numpy as np
from scipy import stats

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # modules/
D = os.path.join(ROOT, "22-proportion-chi-square", "data")
for f in ("scrap-shifts.csv", "cnc-ab.csv", "defect-machine.csv", "bore-100-gof.csv"):
    if not os.path.exists(os.path.join(D, f)):
        sys.exit(f"VACUOUS COURT: module 22 dataset missing: {f}")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---- §2 one-proportion z (scrap-shifts.csv, seed 42194) ----
rows = list(csv.DictReader(open(os.path.join(D, "scrap-shifts.csv"))))
x = sum(int(r["scrapped"]) for r in rows); n = sum(int(r["inspected"]) for r in rows)
ph = x / n
z = (ph - 0.05) / math.sqrt(0.05 * 0.95 / n)
p_one = 1 - stats.norm.cdf(z)
p_two = 2 * (1 - stats.norm.cdf(abs(z)))
wald = (ph - 1.96 * math.sqrt(ph * (1 - ph) / n), ph + 1.96 * math.sqrt(ph * (1 - ph) / n))
cp = (stats.beta.ppf(0.025, x, n - x + 1), stats.beta.ppf(0.975, x + 1, n - x))
check("x_n", (x, n), (193, 2500))
check("p_hat", round(ph, 4), 0.0772)
check("z", round(z, 3), 6.240)
check("p_one_sided", float(f"{p_one:.2e}"), 2.19e-10)
check("p_two_sided", float(f"{p_two:.2e}"), 4.37e-10)
check("wald_ci", (round(wald[0], 4), round(wald[1], 4)), (0.0667, 0.0877))
check("clopper_pearson", (round(cp[0], 4), round(cp[1], 4)), (0.0670, 0.0884))

# ---- §3 two-proportion z (cnc-ab.csv, seed 42195) ----
r2 = list(csv.DictReader(open(os.path.join(D, "cnc-ab.csv"))))
x3, n3 = int(r2[0]["defective"]), int(r2[0]["inspected"])
x4, n4 = int(r2[1]["defective"]), int(r2[1]["inspected"])
pp = (x3 + x4) / (n3 + n4)
z2 = (x3 / n3 - x4 / n4) / math.sqrt(pp * (1 - pp) * (1 / n3 + 1 / n4))
p2s = 2 * (1 - stats.norm.cdf(abs(z2)))
se_un = math.sqrt(x3 / n3 * (1 - x3 / n3) / n3 + x4 / n4 * (1 - x4 / n4) / n4)
d = x3 / n3 - x4 / n4
check("cnc3_cnc4", (round(x3 / n3, 4), round(x4 / n4, 4)), (0.0781, 0.0968))
check("p_bar", round(pp, 4), 0.0873)
check("z2", round(z2, 3), -0.829)
check("p_two_prop", round(p2s, 3), 0.407)
check("diff_ci_unpooled", (round(d - 1.96 * se_un, 4), round(d + 1.96 * se_un, 4)), (-0.0628, 0.0255))

# ---- §4 chi-square independence (defect-machine.csv, seed 42196) ----
tab = np.array([[int(c) for c in row[1:]] for row in
                list(csv.reader(open(os.path.join(D, "defect-machine.csv"))))[1:]])
if tab.shape != (4, 3):
    sys.exit(f"COURT FAIL: contingency table shape {tab.shape}, want (4, 3)")
chi2, pchi, dof, exp = stats.chi2_contingency(tab)
contrib = (tab - exp) ** 2 / exp
check("chi2_indep", round(chi2, 3), 23.389)
check("df", int(dof), 6)
check("p_indep", round(pchi, 5), 0.00068)
check("contrib_burrs_cnc1", round(contrib[3, 0], 2), 4.13)
check("contrib_oversize_cnc1", round(contrib[1, 0], 2), 3.33)
check("contrib_porosity_cnc2", round(contrib[2, 1], 2), 3.24)
check("contrib_burrs_cnc3", round(contrib[3, 2], 2), 3.48)
check("min_expected", round(exp.min(), 1), 29.1)
check("chi2_crit_6", round(stats.chi2.ppf(0.95, 6), 3), 12.592)

# ---- §5 chi-square GOF normality (bore-100-gof.csv, seed 42197) ----
x8 = np.array([float(r["bore_mm"]) for r in csv.DictReader(open(os.path.join(D, "bore-100-gof.csv")))])
m, s = x8.mean(), x8.std(ddof=1)
edges = [stats.norm.ppf(i / 8, loc=m, scale=s) for i in range(1, 8)]
obs, _ = np.histogram(x8, bins=[-np.inf] + edges + [np.inf])
chi2g = float(((obs - 12.5) ** 2 / 12.5).sum())
pg = 1 - stats.chi2.cdf(chi2g, 5)
check("gof_n_xbar_s", (len(x8), round(m, 4), round(s, 4)), (100, 12.0092, 0.0042))
check("chi2_gof", round(chi2g, 3), 1.920)
check("p_gof", round(pg, 3), 0.860)
check("chi2_crit_5", round(stats.chi2.ppf(0.95, 5), 3), 11.070)

# ---- vacuity mutation: wrong pooled proportion must move z and flip nothing ----
ph_w = (x + 1) / n
z_w = (ph - 0.05) / math.sqrt(0.05 * 0.95 / (n + 2500))
check("mutation_detected",
      round((ph_w - 0.05) / math.sqrt(0.05 * 0.95 / n), 3) != round(z, 3)
      and round(z_w, 3) != round(z, 3), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)
print("Module 22 court: ALL CHECKS PASS (1-prop z, 2-prop z, chi-square independence + GOF, wrong-n mutation)")
