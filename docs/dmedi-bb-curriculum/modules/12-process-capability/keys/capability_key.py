#!/usr/bin/env python3
"""Solution key — Module 12: process capability (Cp/Cpk/Pp/Ppk, stability, normality, transform).

Every index re-derived from raw measurements (provenance law). Exit 0 = key verified.

Courts:
  1. Spine court: Cpk on bore-baseline (subgrouped) must equal 0.72 to rounding.
  2. Stability court: Xbar/R chart from the same raw measurements must be in-control
     (capability may only be interpreted on a stable process).
  3. Normality court: right-skewed flatness data must fail Shapiro raw, pass transformed,
     and the capability verdict must FLIP under the transformation.
"""
import sys, os
import numpy as np
from scipy import stats

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
LSL, USL = 11.975, 12.025

# ---------- 1. bore-baseline subgrouped (spine dataset, seed 512) ----------
d = np.loadtxt(os.path.join(ROOT, "data", "cpk072-bore-subgroups.csv"), delimiter=",", skiprows=1)[:, 1:]
k, n = d.shape                      # 25 subgroups x 4
xb = d.mean(axis=1); R = d.max(axis=1) - d.min(axis=1)
Rbar = R.mean(); grand = xb.mean()
d2 = {4: 2.059, 5: 2.326}[n]
A2 = {4: 0.729, 5: 0.577}[n]; D4 = {4: 2.282, 5: 2.114}[n]
sw = Rbar / d2                      # sigma within = Rbar/d2
so = d.std(ddof=1)                  # sigma overall (all individual values)
Cp = (USL - LSL) / (6 * sw); Cpk = min(USL - grand, grand - LSL) / (3 * sw)
Pp = (USL - LSL) / (6 * so); Ppk = min(USL - grand, grand - LSL) / (3 * so)
UCLx, LCLx = grand + A2 * Rbar, grand - A2 * Rbar
UCLr = D4 * Rbar
ooc_x = [i + 1 for i, v in enumerate(xb) if v > UCLx or v < LCLx]
ooc_r = [i + 1 for i, v in enumerate(R) if v > UCLr]

print("CAPABILITY KEY 1 - bore-baseline, 25x4 subgroups (data/cpk072-bore-subgroups.csv, seed 512)")
print(f"  grand mean = {grand:.4f} mm ; Rbar = {Rbar:.5f} mm ; sigma_within = {sw:.5f} ; sigma_overall = {so:.5f}")
print(f"  Cp = {Cp:.2f}   Cpk = {Cpk:.2f}   (within, Rbar/d2)")
print(f"  Pp = {Pp:.2f}   Ppk = {Ppk:.2f}   (overall, sample s)")
print(f"  Z.usl = {round((USL - grand) / sw, 2)} ; est PPM > USL (within, normal) = {round(1e6 * stats.norm.sf((USL - grand) / sw))}")
print(f"  Xbar chart UCL/LCL = {UCLx:.4f}/{LCLx:.4f} ; R chart UCL = {UCLr:.4f}")
print(f"  stability: out-of-control subgroups Xbar={ooc_x} R={ooc_r} -> in-control"
      + ("" if not ooc_x and not ooc_r else " !!! STABILITY COURT FAILS"))

# ---------- 2. Lane 04 individual baseline (coherence check) ----------
xi = np.loadtxt(os.path.join(ROOT, "data", "bore-baseline-100.csv"), delimiter=",", skiprows=1, usecols=1)
mi, si = xi.mean(), xi.std(ddof=1)
print("CAPABILITY KEY 2 - Lane 04 bore-baseline-100 (coherence)")
print(f"  n = {len(xi)} ; mean = {mi:.4f} ; s = {si:.5f}")
print(f"  Pp = {(USL-LSL)/(6*si):.2f} ; Ppk = {min(USL-mi, mi-LSL)/(3*si):.2f}")
print(f"  spine formula min(USL-mu, mu-LSL)/(3 sigma) with ORIGINAL spine mu=12.009 sigma=4.17um = {0.016/(3*0.00417):.2f}")
print(f"  -> ADJUDICATED 2026-11-04: 0.72 requires sigma = 7.407 um at mu = 12.009,")
print(f"     Lane 04 raw data re-derives Cpk ~ {min(USL-mi, mi-LSL)/(3*si):.2f} (overall), NOT 0.72.")

# ---------- 3. stability via Lane 04 chart on xbar-r-subgroups ----------
d5 = np.loadtxt(os.path.join(ROOT, "data", "xbar-r-subgroups.csv"), delimiter=",", skiprows=1)[:, 1:]
xb5 = d5.mean(axis=1); R5 = d5.max(axis=1) - d5.min(axis=1)
Rb5 = R5.mean(); g5 = xb5.mean(); sw5 = Rb5 / 2.326
o5 = [i + 1 for i, v in enumerate(xb5) if v > g5 + 0.577 * Rb5 or v < g5 - 0.577 * Rb5]
o5r = [i + 1 for i, v in enumerate(R5) if v > 2.114 * Rb5]
print("CAPABILITY KEY 3 - Lane 04 Xbar/R chart (data/xbar-r-subgroups.csv, as-observed on disk)")
if o5 or o5r:
    print(f"  out-of-control: Xbar={o5} R={o5r} -> NOT stable as of this run; Lane 04 owns this")
    print(f"     dataset. If intentional (special-cause teaching window), capability may not be")
    print(f"     interpreted on it until the special cause is removed; if not, Lane 04 must fix.")
else:
    print(f"  out-of-control: none -> process stable; capability interpretation lawful.")

# ---------- 4. normality + transformation court (flatness, seed 1203) ----------
xf = np.loadtxt(os.path.join(ROOT, "data", "flatness-lognormal.csv"), delimiter=",", skiprows=1, usecols=1)
USLf = 0.010
lmb = stats.boxcox(xf)[1]
xt = stats.boxcox(xf, lmb)
USLt = (USLf ** lmb - 1) / lmb
Ppk_raw = (USLf - xf.mean()) / (3 * xf.std(ddof=1))
Ppk_t = (USLt - xt.mean()) / (3 * xt.std(ddof=1))
sh_raw = stats.shapiro(xf).pvalue; sh_t = stats.shapiro(xt).pvalue
ppm_raw = 1e6 * stats.norm.sf((USLf - xf.mean()) / xf.std(ddof=1))
ppm_t = 1e6 * stats.norm.sf((USLt - xt.mean()) / xt.std(ddof=1))
print("CAPABILITY KEY 4 - non-normal lab (data/flatness-lognormal.csv, seed 1203, USL 0.010)")
print(f"  skew = {stats.skew(xf):.2f} ; Shapiro raw p = {sh_raw:.5f} ; Box-Cox lambda = {lmb:.4f}")
print(f"  Ppk raw-normal = {Ppk_raw:.2f} ; Ppk transformed = {Ppk_t:.2f}")
print(f"  est PPM > USL raw = {ppm_raw:.0f} ; transformed = {ppm_t:.0f} ; obs {int((xf > USLf).sum())}/60 above USL")
print(f"  Shapiro transformed p = {sh_t:.4f}")

# ---------- courts ----------
assert abs(Cpk - 0.72) <= 0.005, f"SPINE COURT FAIL: Cpk {Cpk:.4f} != 0.72"
assert not ooc_x and not ooc_r, "STABILITY COURT FAIL: spine dataset not in control"
# Lane 04's chart is reported, not asserted: Lane 04 owns that dataset (see key 3 output).
assert sh_raw < 0.05, "NORMALITY COURT FAIL: raw flatness must fail Shapiro"
assert sh_t > 0.05, "NORMALITY COURT FAIL: transformed flatness must pass Shapiro"
assert Ppk_raw >= 0.8 > Ppk_t, "VERDICT-FLIP COURT FAIL: raw Ppk must pass marginally, transformed must fail"
print("ALL COURTS PASS")
sys.exit(0)
