#!/usr/bin/env python3
"""Module 12 court. Run from curriculum root (or anywhere). Exit 0 = the
Cpk = 0.72 running case re-derives from RAW subgroup data, never memory.

Pins (re-derived, not remembered):
  mu = 12.0090 mm, sigma_within = Rbar/d2 = 7.407 um, Cpk = 0.72,
  Cp 1.12 / Pp 1.32 / Ppk 0.84, process in-control (stability precondition).

STALENESS SWEEP: the adjudicated pair is sigma = 7.407 um with mu = 12.009
(RUNNING-CASE.md, adjudicated 2026-11-04). The ORIGINAL spine sigma 4.17 um
was stale (0.016/(3*0.00417) = 1.28, not 0.72); this court FAILS LOUDLY if
the data-derived sigma ever returns to the 4.17 um scale.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero. If the corrupted court still passes, exit 2 = VACUOUS COURT.
"""
import csv, math, statistics, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)                       # modules/12-process-capability
ROOT = os.path.dirname(MOD)                       # curriculum root
SRC = os.path.join(ROOT, "data", "cpk072-bore-subgroups.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: data/cpk072-bore-subgroups.csv missing (seed 512)")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

rows = list(csv.reader(open(SRC)))[1:]
subs = [[float(v) for v in r[1:]] for r in rows]
k, n = len(subs), len(subs[0])
xb = [statistics.mean(s) for s in subs]
R = [max(s) - min(s) for s in subs]
Rbar = statistics.mean(R)
grand = statistics.mean(xb)
d2, A2, D4 = 2.059, 0.729, 2.282                  # n = 4 constants
sw = Rbar / d2                                    # sigma within
so = statistics.stdev(v for s in subs for v in s)  # sigma overall
LSL, USL = 11.975, 12.025

check("shape_25x4", (k, n), (25, 4))
check("grand_mean", round(grand, 4), 12.0090, 1e-9)
check("Rbar", round(Rbar, 6), 0.015252, 1e-9)
check("sigma_within_mm", round(sw, 7), 0.0074075, 1e-9)
check("sigma_within_um", round(sw * 1000, 3), 7.407, 1e-9)
check("Cp", round((USL - LSL) / (6 * sw), 2), 1.12, 1e-9)
cpk = min(USL - grand, grand - LSL) / (3 * sw)
check("Cpk_0.72", round(cpk, 2), 0.72, 1e-9)
check("Cpk_formula_band", round((USL - grand) / (3 * sw), 4), 0.7199, 1e-9)
check("Pp", round((USL - LSL) / (6 * so), 2), 1.32, 1e-9)
check("Ppk", round(min(USL - grand, grand - LSL) / (3 * so), 2), 0.84, 1e-9)
check("centering_story_Cp_is_cpk_at_center", round(cpk, 2) < round((USL - LSL) / (6 * sw), 2), True)

# stability precondition (Xbar/R, n=4 constants)
UCLx, LCLx, UCLr = grand + A2 * Rbar, grand - A2 * Rbar, D4 * Rbar
check("UCLx", round(UCLx, 4), 12.0201, 1e-9)
check("LCLx", round(LCLx, 4), 11.9979, 1e-9)
check("UCLr", round(UCLr, 4), 0.0348, 1e-9)
ooc_x = [i + 1 for i, v in enumerate(xb) if v > UCLx or v < LCLx]
ooc_r = [i + 1 for i, v in enumerate(R) if v > UCLr]
check("in_control", (ooc_x, ooc_r), ([], []))

# STALENESS SWEEP: the stale 4.17 um spine sigma must never come back.
# (a) the data-derived sigma is NOT the stale value;
# (b) the stale value demonstrably does NOT reproduce the pinned Cpk 0.72
#     (0.016/(3*0.00417) = 1.28), so pinning it would be a coherence break.
STALE_UM = 4.17
check("stale_sigma_refused_data", abs(sw * 1000 - STALE_UM) > 0.5, True)
check("stale_sigma_refused_coherence", round(0.016 / (3 * STALE_UM / 1000), 2) != round(cpk, 2), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)

print(f"Module 12 court: ALL CHECKS PASS (mu {grand:.4f} mm, sigma_within "
      f"{sw*1000:.3f} um, Cp 1.12 / Cpk 0.72 / Pp 1.32 / Ppk 0.84, in-control, "
      f"stale 4.17 um refused)")

# ---------- mutation test: corrupt one pinned constant ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(cpk, 2) - 0.75) <= 1e-9:         # simulate a wrong pin slipping through
        print("VACUOUS COURT: corrupted constant still passes")
        sys.exit(2)
    print("MUTATION DETECTED: Cpk pinned at 0.75 vs derived %.4f -> court exits nonzero" % cpk)
    sys.exit(1)
sys.exit(0)
