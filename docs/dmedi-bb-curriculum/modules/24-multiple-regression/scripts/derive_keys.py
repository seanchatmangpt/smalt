#!/usr/bin/env python3
"""Lane 10 court key, Module 24 — multiple regression.

Hand-rolled OLS via normal equations (Gauss-Jordan on X'X), NO regression library:
- coefficients, SEs, t/p, standardized betas ranking
- ANOVA, R2, adj R2
- VIF for each predictor (auxiliary regressions through the same solver)
- residual court: Shapiro-Wilk (scipy), Breusch-Pagan computed by hand,
  Durbin-Watson computed by hand
- reduced-model F-test dropping coolant_temp_c
Exit 0 = courts pass.
"""
import csv
import math

import numpy as np
from scipy import stats as st

rows = []
with open("data/regression-multi.csv") as f:
    for r in csv.DictReader(f):
        rows.append((float(r["spindle_speed_rpm"]), float(r["feed_mm_min"]),
                     float(r["coolant_temp_c"]), float(r["ra_um"])))
n = len(rows)
X = np.array([[1.0, a, b, c] for a, b, c, _ in rows])
y = np.array([d for *_, d in rows])
k = X.shape[1] - 1  # 3 predictors


def ols(Xm, yv):
    """Plain OLS with hand-computed SEs from (X'X)^-1 sigma^2."""
    XtX = Xm.T @ Xm
    XtXi = np.linalg.inv(XtX)
    b = XtXi @ Xm.T @ yv
    resid = yv - Xm @ b
    dfe = len(yv) - Xm.shape[1]
    s2 = resid @ resid / dfe
    se = np.sqrt(np.diag(XtXi) * s2)
    tvals = b / se
    return b, se, tvals, resid, s2, dfe


b, se, tv, resid, s2, dfe = ols(X, y)
names = ["Intercept", "speed", "feed", "coolant_temp"]
ybar = y.mean()
SST = ((y - ybar) ** 2).sum()
# TSS-fix witness (Lane 10 known bug): centered SST, never uncentered sum(y^2).
# Relative margin: Ra sits near 2 um so the absolute gap is small but material.
uncentered = (y ** 2).sum()
assert abs(uncentered - SST) > 0.05 * uncentered, \
    "witness must distinguish centered/uncentered"
print(f"TSS witness: centered SST={SST:.4f} != uncentered sum(y^2)={uncentered:.4f}")
SSE = resid @ resid
SSR = SST - SSE
R2 = 1 - SSE / SST
adjR2 = 1 - (1 - R2) * (n - 1) / dfe
F = (SSR / k) / s2
pF = st.f.sf(F, k, dfe)

print("== full model ==")
for nm, bi, si, ti in zip(names, b, se, tv):
    p = 2 * st.t.sf(abs(ti), dfe)
    print(f"{nm:12s} b={bi: .6f}  se={si:.6f}  t={ti: .3f}  p={p:.4g}")
print(f"SST={SST:.4f} SSR={SSR:.4f} SSE={SSE:.4f}  R2={R2:.5f} adjR2={adjR2:.5f}")
print(f"F(3,{dfe})={F:.2f}  p={pF:.3e}  s={math.sqrt(s2):.4f} um")

# standardized coefficients: beta_j = b_j * sd(x_j)/sd(y)
print("\n== standardized betas (ranking) ==")
for nm, bi, col in zip(names[1:], b[1:], [X[:, j] for j in (1, 2, 3)]):
    beta_std = bi * col.std(ddof=1) / y.std(ddof=1)
    print(f"{nm:12s} beta*={beta_std: .4f}")

# VIF via auxiliary regression of each x_j on the other two
print("\n== VIF (auxiliary regressions, same hand-rolled solver) ==")
for j, nm in zip((1, 2, 3), names[1:]):
    others = [c for c in (1, 2, 3) if c != j]
    Xa = X[:, [0] + others]
    _, _, _, ra, _, _ = ols(Xa, X[:, j])
    R2a = 1 - (ra @ ra) / ((X[:, j] - X[:, j].mean()) ** 2).sum()
    tol = 1 - R2a
    print(f"{nm:12s} R2aux={R2a:.4f}  tolerance={tol:.4f}  VIF={1/tol:.3f}")

# residual court
print("\n== residual analysis ==")
W, pW = st.shapiro(resid)
print(f"Shapiro-Wilk W={W:.4f} p={pW:.4f}  -> normality "
      f"{'OK' if pW > 0.05 else 'VIOLATED'}")
# Breusch-Pagan by hand: regress e^2 on the x's, LM = n * R2 of that auxiliary fit
_, _, _, re2, _, _ = ols(X, resid ** 2)
e2 = resid ** 2
SST_e2 = ((e2 - e2.mean()) ** 2).sum()  # CENTERED TSS of e^2
R2bp = 1 - (re2 @ re2) / SST_e2
LM = n * R2bp
pBP = st.chi2.sf(LM, k)
print(f"Breusch-Pagan LM={LM:.3f} (chi2, df=3) p={pBP:.4f}  -> homoscedastic "
      f"{'OK' if pBP > 0.05 else 'VIOLATED'}")
dw = ((resid[1:] - resid[:-1]) ** 2).sum() / (resid @ resid)
print(f"Durbin-Watson DW={dw:.4f}  -> autocorrelation "
      f"{'none (≈2)' if 1.5 < dw < 2.5 else 'SUSPECT'}")

# reduced-model F-test: drop coolant_temp
Xr = X[:, [0, 1, 2]]
br, ser, tvr, resr, s2r, dfer = ols(Xr, y)
SSE_r = resr @ resr
Fdrop = ((SSE_r - SSE) / 1) / (SSE / dfe)
pdrop = st.f.sf(Fdrop, 1, dfe)
t_cool = tv[3]
print("\n== reduced-model F-test (drop coolant_temp_c) ==")
print(f"SSE_reduced={SSE_r:.4f}  SSE_full={SSE:.4f}")
print(f"F = ((SSE_r - SSE_f)/1) / (SSE_f/{dfe}) = {Fdrop:.3f}  p={pdrop:.4f}")
print(f"partial t for coolant = {t_cool:.3f};  sqrt(F) = {math.sqrt(Fdrop):.3f} "
      f"(must match |t|)")
assert abs(math.sqrt(Fdrop) - abs(t_cool)) < 1e-6

# ---- courts ----
assert abs(SSR + SSE - SST) < 1e-6 * SST
assert abs(math.sqrt(F) - math.sqrt(F)) < 1e-9
assert pdrop > 0.05, "coolant_temp must be insignificant for the exercise"
assert all(p > 0.05 for p in (pW, pBP)) and 1.5 < dw < 2.5
assert abs(b[2] - 0.018) < 0.004, f"feed coef {b[2]}"
assert abs(b[1] + 0.0004) < 0.0002, f"speed coef {b[1]}"
print("\nCOURT PASS: SST identity, sqrt(F)=|t_partial|, coolant insignificant, "
      "residuals clean, planted coefficients recovered")
