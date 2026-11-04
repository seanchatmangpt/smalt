import csv, math
import numpy as np
from scipy import stats

BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum/modules"
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(open(f"{BASE}/19-hypothesis-testing/data/bore-30.csv"))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
t = (xb - 12.000)/se; df = n-1
tcrit = stats.t.ppf(0.975, df)
p = 2*(1 - stats.t.cdf(abs(t), df))
print(f"n={n} xbar={xb:.4f} s={s:.4f} se={se:.6f}")
print(f"t={t:.3f} tcrit={tcrit:.3f} p={p:.3e}  ci95=({xb-tcrit*se:.4f},{xb+tcrit*se:.4f})")

# sigma-known z
z = (xb - 12.000)/(0.007407/math.sqrt(30))
pz = 2*(1 - stats.norm.cdf(abs(z)))
print(f"z(sigma known, 7.407um)={z:.2f} p={pz:.2e}")

# power / sample size (sigma = 7.407 um, delta = 5 um, alpha=0.05 two-sided)
za = stats.norm.ppf(0.975); zb = stats.norm.ppf(0.80)
nraw = ((za+zb)*7.407/5.0)**2
print(f"z_a={za:.4f} z_b={zb:.4f} n_raw={nraw:.2f} -> n={math.ceil(nraw)}")
def power(nn, delta=5.0, sig=7.407):
    lam = delta/(sig/math.sqrt(nn))
    return 1 - stats.norm.cdf(za - lam) + stats.norm.cdf(-za - lam)
for nn in (2,3,4,5,6,8,10,12,15,18,20,25):
    print(f"power(n={nn}) = {power(nn):.3f}")
print(f"power(17)={power(17):.3f} power(18)={power(18):.3f}")
for delta in (2.0, 3.0, 5.0):
    for nn in (18, 30, 50):
        print(f"delta={delta}um n={nn}: power={power(nn,delta):.3f} beta={1-power(nn,delta):.3f}")
# 2um n=50
print(f"power(n=50, delta=2)={power(50,2.0):.3f}")
