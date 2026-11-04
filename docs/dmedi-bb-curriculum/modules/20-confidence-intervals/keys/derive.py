import csv, math
import numpy as np
from scipy import stats

BASE = "/Users/sac/smalt/docs/dmedi-bb-confused"  # placeholder, fixed below
BASE = "/Users/sac/smalt/docs/dmedi-bb-curriculum/modules"
x = np.array([float(r["bore_mm"]) for r in csv.DictReader(open(f"{BASE}/19-hypothesis-testing/data/bore-30.csv"))])
n = len(x); xb = x.mean(); s = x.std(ddof=1); se = s/math.sqrt(n)
print(f"bore-30: n={n} xbar={xb:.4f} s={s:.4f} se={se:.6f} tcrit={stats.t.ppf(0.975,29):.3f}")
for c in (0.90, 0.95, 0.99):
    lo, hi = stats.t.interval(c, 29, loc=xb, scale=se)
    print(f"CI{int(c*100)}=({lo:.4f}, {hi:.4f})  width={hi-lo:.4f} = 2*{stats.t.ppf((1+c)/2,29):.3f}*se")

# width engineering: n to halve 95% width
w95 = 2*stats.t.ppf(0.975,29)*se
print(f"95% width={w95:.4f}; halving needs ~4x n -> n~{4*30} (width law 1/sqrt(n))")

rows = list(csv.DictReader(open(f"{BASE}/20-confidence-intervals/data/ci-trap-overlap.csv")))
t1 = np.array([float(r["spindle1_mm"]) for r in rows]); t2 = np.array([float(r["spindle2_mm"]) for r in rows])
m1, s1 = t1.mean(), t1.std(ddof=1); m2, s2 = t2.mean(), t2.std(ddof=1)
c1 = stats.t.interval(0.95, 29, loc=m1, scale=s1/math.sqrt(30))
c2 = stats.t.interval(0.95, 29, loc=m2, scale=s2/math.sqrt(30))
ov = (min(c1[1], c2[1]) - max(c1[0], c2[0]), min(c1[1], c2[1]), max(c1[0], c2[0]))
print(f"spindle1: m={m1:.4f} s={s1:.4f} ci=({c1[0]:.4f},{c1[1]:.4f})")
print(f"spindle2: m={m2:.4f} s={s2:.4f} ci=({c2[0]:.4f},{c2[1]:.4f})")
ovw = min(c1[1], c2[1]) - max(c1[0], c2[0])
narrow = min(c1[1]-c1[0], c2[1]-c2[0])
print(f"overlap=({max(c1[0],c2[0]):.4f},{min(c1[1],c2[1]):.4f}) width={ovw:.4f} = {ovw/narrow*100:.0f}% of narrower CI")
tt, pt = stats.ttest_ind(t1, t2, equal_var=True)
sp = math.sqrt((29*s1**2 + 29*s2**2)/58); d = m1 - m2
h = stats.t.ppf(0.975, 58)*sp*math.sqrt(2/30)
print(f"pooled t={tt:.3f} df=58 tcrit={stats.t.ppf(0.975,58):.3f} p={pt:.4f}")
print(f"diff CI = ({d-h:.4f}, {d+h:.4f})")

# paired marginal CIs (paired-feed, seed 42192)
rows = list(csv.DictReader(open(f"{BASE}/21-testing-means-medians-variances/data/paired-feed.csv")))
bf = np.array([float(r["before_mm"]) for r in rows]); af = np.array([float(r["after_mm"]) for r in rows])
cb = stats.t.interval(0.95, 24, loc=bf.mean(), scale=bf.std(ddof=1)/5)
ca = stats.t.interval(0.95, 24, loc=af.mean(), scale=af.std(ddof=1)/5)
print(f"paired before: m={bf.mean():.4f} ci=({cb[0]:.4f},{cb[1]:.4f})")
print(f"paired after:  m={af.mean():.4f} ci=({ca[0]:.4f},{ca[1]:.4f})")
dser = af - bf; tc = stats.t.ppf(0.975, 24)
cid = (dser.mean()-tc*dser.std(ddof=1)/5, dser.mean()+tc*dser.std(ddof=1)/5)
print(f"paired t={stats.ttest_rel(af,bf).statistic:.2f} p={stats.ttest_rel(af,bf).pvalue:.1e} diffCI=({cid[0]:.4f},{cid[1]:.4f})")
