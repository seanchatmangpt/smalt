import csv, math
import numpy as np
from scipy import stats

BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum/modules/22-proportion-chi-square/data"

# --- 1-prop z (scrap-shifts, seed 42194)
rows = list(csv.DictReader(open(f"{BASE}/scrap-shifts.csv")))
x = sum(int(r["scrapped"]) for r in rows); n = sum(int(r["inspected"]) for r in rows)
ph = x/n
z = (ph - 0.05)/math.sqrt(0.05*0.95/n)
print(f"scrap: x={x} n={n} phat={ph:.4f} np0={0.05*n:.0f} n(1-p0)={0.95*n:.0f}")
print(f"z={z:.3f} zcrit_one=1.645 p_one={1-stats.norm.cdf(z):.2e} p_two={2*(1-stats.norm.cdf(z)):.2e}")
wald = (ph - 1.96*math.sqrt(ph*(1-ph)/n), ph + 1.96*math.sqrt(ph*(1-ph)/n))
cp = (stats.beta.ppf(0.025, x, n-x+1), stats.beta.ppf(0.975, x+1, n-x))
print(f"wald=({wald[0]:.4f},{wald[1]:.4f}) clopper=({cp[0]:.4f},{cp[1]:.4f})")

# --- 2-prop z (cnc-ab, seed 42195)
r2 = list(csv.DictReader(open(f"{BASE}/cnc-ab.csv")))
x3, n3 = int(r2[0]["defective"]), int(r2[0]["inspected"])
x4, n4 = int(r2[1]["defective"]), int(r2[1]["inspected"])
pp = (x3+x4)/(n3+n4)
z2 = (x3/n3 - x4/n4)/math.sqrt(pp*(1-pp)*(1/n3+1/n4))
print(f"cnc: p3={x3}/{n3}={x3/n3:.4f} p4={x4}/{n4}={x4/n4:.4f} pbar={pp:.4f}")
print(f"z2={z2:.3f} p={2*(1-stats.norm.cdf(abs(z2))):.3f}")
seu = math.sqrt(x3/n3*(1-x3/n3)/n3 + x4/n4*(1-x4/n4)/n4)
d = x3/n3 - x4/n4
print(f"diff={d:.4f} ci=({d-1.96*seu:.4f},{d+1.96*seu:.4f})")

# --- chi2 independence (defect-machine, seed 42196)
tab = np.array([[int(c) for c in row[1:]] for row in list(csv.reader(open(f"{BASE}/defect-machine.csv")))[1:]])
chi2, pchi, dof, exp = stats.chi2_contingency(tab)
contrib = (tab - exp)**2 / exp
print(f"indep: chi2={chi2:.3f} df={dof} p={pchi:.5f} crit={stats.chi2.ppf(0.95,6):.3f} min_exp={exp.min():.1f}")
for nm, r_, c_ in (("scratch/CNC-1",0,0),("oversize/CNC-1",1,0),("porosity/CNC-2",2,1),("burrs/CNC-1",3,0),("burrs/CNC-3",3,2)):
    print(f"contrib {nm} = {contrib[r_][c_]:.2f} (O={tab[r_][c_]}, E={exp[r_][c_]:.1f})")
print("row totals:", tab.sum(1), "col totals:", tab.sum(0), "N=", tab.sum())

# --- GOF (bore-100-gof, seed 42197)
x8 = np.array([float(r["bore_mm"]) for r in csv.DictReader(open(f"{BASE}/bore-100-gof.csv"))])
m, s = x8.mean(), x8.std(ddof=1)
edges = [stats.norm.ppf(i/8, loc=m, scale=s) for i in range(1, 8)]
obs, _ = np.histogram(x8, bins=[-np.inf]+edges+[np.inf])
chi2g = float(((obs-12.5)**2/12.5).sum()); pg = 1 - stats.chi2.cdf(chi2g, 5)
print(f"gof: n={len(x8)} xbar={m:.4f} s={s:.4f}")
print("cuts:", " ".join(f"{e:.4f}" for e in edges))
print("obs:", obs, "chi2=", f"{chi2g:.3f}", "df=5 crit=", f"{stats.chi2.ppf(0.95,5):.3f}", "p=", f"{pg:.3f}")
