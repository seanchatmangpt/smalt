import csv, math
import numpy as np
from scipy import stats

BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum/modules/21-testing-means-medians-variances/data"

# --- coating A/B (seed 42191)
rows = list(csv.DictReader(open(f"{BASE}/coating-ab-bore.csv")))
A = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "A"])
B = np.array([float(r["bore_mm"]) for r in rows if r["coating"] == "B"])
mA, sA = A.mean(), A.std(ddof=1); mB, sB = B.mean(), B.std(ddof=1)
sp = math.sqrt((29*sA**2 + 29*sB**2)/58)
t = (mA - mB)/(sp*math.sqrt(2/30))
p = 2*stats.t.sf(abs(t), 58)
tw, pw = stats.ttest_ind(A, B, equal_var=False)
dfw = (sA**2/30 + sB**2/30)**2 / ((sA**2/30)**2/29 + (sB**2/30)**2/29)
print(f"coating: nA={len(A)} nB={len(B)} meanA={mA:.4f} sA={sA:.4f} meanB={mB:.4f} sB={sB:.4f}")
print(f"sp={sp:.4f} t_pooled={t:.3f} tcrit={stats.t.ppf(0.975,58):.3f} p={p:.3e}")
print(f"welch t={tw:.3f} df={dfw:.1f} p={pw:.3e}")
W, pl = stats.levene(A, B, center="median")
K2, pb = stats.bartlett(A, B)
print(f"levene W={W:.3f} p={pl:.3f} | bartlett K2={K2:.3f} p={pb:.3f}")
U, pu = stats.mannwhitneyu(A, B, alternative="two-sided")
print(f"MW U={U} p={pu:.3e}")

# --- paired (seed 42192)
rows = list(csv.DictReader(open(f"{BASE}/paired-feed.csv")))
bf = np.array([float(r["before_mm"]) for r in rows]); af = np.array([float(r["after_mm"]) for r in rows])
d = af - bf; db, sd = d.mean(), d.std(ddof=1)
tp = db/(sd/5); pp = 2*stats.t.sf(abs(tp), 24); tc = stats.t.ppf(0.975, 24)
print(f"paired: n={len(d)} dbar={db:.4f} sd={sd:.4f} t={tp:.3f} p={pp:.3e} ci=({db-tc*sd/5:.4f},{db+tc*sd/5:.4f})")
ti, pi = stats.ttest_ind(bf, af, equal_var=True)
print(f"unpaired contrast: t={ti:.3f} p={pi:.4f} p-ratio={pp/pi:.2e}")

# --- anova (seed 42193)
rows = list(csv.DictReader(open(f"{BASE}/coolant-anova.csv")))
g = {}
for r in rows: g.setdefault(r["coolant_pct"], []).append(float(r["bore_mm"]))
gs = [np.array(g[k]) for k in ("5", "8", "12")]
N = 30; k = 3
grand = np.concatenate(gs).mean()
SSB = sum(len(x)*(x.mean()-grand)**2 for x in gs)
SSW = sum(((x-x.mean())**2).sum() for x in gs)
F = (SSB/2)/(SSW/27)
pf = 1 - stats.f.cdf(F, 2, 27)
MSW = SSW/27; tc27 = stats.t.ppf(0.975, 27)
print(f"anova: grand={grand:.4f} SSB={SSB:.8f} SSW={SSW:.8f} SST={SSB+SSW:.8f}")
print(f"F={F:.3f} Fcrit={stats.f.ppf(0.95,2,27):.3f} p={pf:.5f} MSW={MSW:.8f}")
for nm, arr in zip(("5","8","12"), gs):
    print(f"mean {nm}% = {arr.mean():.4f}")
for i, j in ((0,1), (0,2), (1,2)):
    diff = gs[i].mean() - gs[j].mean()
    se = math.sqrt(MSW*(1/10+1/10))
    lo, hi = diff - tc27*se, diff + tc27*se
    print(f"{i}-{j} diff={diff:.4f} ci=({lo:.4f},{hi:.4f}) sig={abs(diff) > tc27*se}")
