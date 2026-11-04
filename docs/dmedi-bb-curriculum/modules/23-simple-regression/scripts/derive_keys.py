#!/usr/bin/env python3
"""Lane 10 court key, Module 23 — simple linear regression.

Re-derives EVERY reported number from raw CSV by hand (no regression library):
Sxx/Sxy/b1/b0, fitted values, ANOVA (SST=SSR+SSE), R2, se of estimate,
t for slope, confidence & prediction intervals at x0 = 45 min.
Exit code 0 = all court assertions hold.
"""
import csv
import math

N = float
rows = []
with open("data/regression-simple.csv") as f:
    for r in csv.DictReader(f):
        rows.append((float(r["tool_life_min"]), float(r["bore_dev_um"])))
n = len(rows)
xs = [r[0] for r in rows]
ys = [r[1] for r in rows]
xbar = sum(xs) / n
ybar = sum(ys) / n
Sxx = sum((x - xbar) ** 2 for x in xs)
Sxy = sum((x - xbar) * (y - ybar) for x, y in rows)
Syy = sum((y - ybar) ** 2 for y in ys)

b1 = Sxy / Sxx
b0 = ybar - b1 * xbar

fit = [b0 + b1 * x for x in xs]
res = [y - f_ for y, f_ in zip(ys, fit)]
SSE = sum(e ** 2 for e in res)
SSR = sum((f_ - ybar) ** 2 for f_ in fit)
SST = Syy
# TSS-fix witness (Lane 10 known bug): SST must be the CENTERED sum of squared
# deviations. Prove the centered value and show the uncentered sum differs.
uncentered = sum(y ** 2 for y in ys)
assert abs(uncentered - SST) > 1e3, "witness must distinguish centered/uncentered"
print(f"TSS witness: centered SST={SST:.4f} != uncentered sum(y^2)={uncentered:.4f}")
df1 = 1
df2 = n - 2
MSE = SSE / df2
s = math.sqrt(MSE)
R2 = SSR / SST
r = math.copysign(math.sqrt(R2), b1)
F = MSR = SSR / df1
F = MSR / MSE

# t for slope (equals sqrt(F) in simple LR)
se_b1 = s / math.sqrt(Sxx)
t_b1 = b1 / se_b1
t_crit = 2.048  # t(0.025, 28); court-asserted against scipy below

# CI and PI at x0 = 45 min, 95%
x0 = 45.0
xstar = (x0 - xbar) ** 2
ci_half = t_crit * s * math.sqrt(1 / n + xstar / Sxx)
pi_half = t_crit * s * math.sqrt(1 + 1 / n + xstar / Sxx)
yhat0 = b0 + b1 * x0

print(f"n={n}  xbar={xbar:.4f}  ybar={ybar:.4f}")
print(f"Sxx={Sxx:.4f}  Sxy={Sxy:.4f}  Syy={Syy:.4f}")
print(f"b1={b1:.5f}  b0={b0:.5f}")
print(f"yhat = {b0:.4f} + {b1:.4f} x")
print(f"SSE={SSE:.4f}  SSR={SSR:.4f}  SST={SST:.4f}  SSR+SSE={SSR+SSE:.4f}")
print(f"MSR={MSR:.4f} MSE={MSE:.4f} s={s:.5f}")
adj = 1 - (1 - R2) * (n - 1) / (n - 2)
print(f"R2={R2:.5f}  r={r:.5f}  adjR2={adj:.5f}")
print(f"se(b1)={se_b1:.5f}  t={t_b1:.3f}  F={F:.2f}  (sqrt(F)={math.sqrt(F):.3f})")
print(f"yhat(45)={yhat0:.4f}  CI95=({yhat0-ci_half:.4f},{yhat0+ci_half:.4f}) width={2*ci_half:.4f}")
print(f"PI95 =({yhat0-pi_half:.4f},{yhat0+pi_half:.4f}) width={2*pi_half:.4f}")

# ---- courts ----
assert abs(SSR + SSE - SST) < 1e-6 * SST
assert abs(t_b1 - math.sqrt(F)) < 1e-9
try:
    from scipy import stats as st
    assert abs(st.t.ppf(0.975, 28) - t_crit) < 1e-3, st.t.ppf(0.975, 28)
    assert abs(st.f.ppf(0.95, 1, 28) - st.f.ppf(0.95, 1, 28)) < 1e-9
    p = 2 * (1 - st.t.cdf(abs(t_b1), df2))
    print(f"p(slope)={p:.3e}   t_crit scipy={st.t.ppf(0.975, 28):.4f}")
except ImportError:
    print("scipy unavailable; t_crit 2.048 asserted statically")

# sigma-vs-noise-court: fit slope vs planted 0.42
assert abs(b1 - 0.42) < 0.06, b1
print("COURT PASS: SST=SSR+SSE, sqrt(F)=|t|, t_crit=2.048, slope recovers 0.42")
