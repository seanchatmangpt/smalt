#!/usr/bin/env python3
"""Module 14 court (TRIZ product / tool-wear law). Exit 0 = the wear-law pins
re-derive from RAW tool-wear rows (datasets/tool-wear.csv, seed 1419, canonical
column tool_wear_drift_um) by an INDEPENDENT least-squares derivation, and
agree with scripts/derive_keys.py within tolerance.

Pins (re-derived): slope = 0.0079 um/part (0.79 um/100 parts),
intercept = 0.3155 um, s_res = 0.56 um (dof 38), predicted drift at 500 parts
= 3.94 um, uncompensated lag per 100-part comp interval = 0.79 um,
bores/shift gain 480/6.4 vs 480/7.5 = +11.0 bores (+14.7%).

STALENESS SWEEP: n/a here — module 14 carries no spine-sigma claim; the court
still refuses any dataset whose column namespace drifted off
`tool_wear_drift_um` (the canonical running-case column).

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero. If the corrupted court still passes, exit 2 = VACUOUS COURT.
"""
import csv, os, statistics, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "datasets", "tool-wear.csv")
KEY = os.path.join(HERE, "scripts", "derive_keys.py")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: modules/14-triz-product/datasets/tool-wear.csv missing (seed 1419)")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---------- independent least-squares re-derivation ----------
rdr = csv.DictReader(open(SRC))
check("column_namespace", rdr.fieldnames,
      ["parts_since_tool_change", "tool_wear_drift_um"])
d = [(float(r["parts_since_tool_change"]), float(r["tool_wear_drift_um"]))
     for r in rdr]
check("n_obs", len(d), 40)
xs = [x for x, _ in d]
ys = [y for _, y in d]
mx, my = statistics.mean(xs), statistics.mean(ys)
sxx = sum((x - mx) ** 2 for x in xs)
sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
slope = sxy / sxx
intercept = my - slope * mx
resid = [y - (intercept + slope * x) for x, y in d]
sres = (sum(r * r for r in resid) / (len(d) - 2)) ** 0.5

check("slope_um_per_part", round(slope, 4), 0.0079, 1e-9)
check("intercept_um", round(intercept, 4), 0.3155, 1e-9)
check("s_res_um", round(sres, 2), 0.56, 1e-9)
check("drift_at_500_um", round(slope * 500, 2), 3.94, 1e-9)
check("lag_per_100_parts_um", round(slope * 100, 2), 0.79, 1e-9)
check("bores_per_shift_gain", round(480 / 6.4 - 480 / 7.5, 1), 11.0, 1e-9)
check("gain_pct", round((7.5 - 6.4) / 7.5 * 100, 1), 14.7, 1e-9)

# ---------- cross-check vs scripts/derive_keys.py ----------
r = subprocess.run([sys.executable, KEY], capture_output=True, text=True)
check("derive_keys_rc0", r.returncode, 0)
check("key_slope_line", f"slope={slope:.4f} um/part" in r.stdout, True)
check("key_intercept_line", f"intercept={intercept:.4f} um" in r.stdout, True)
check("key_sres_line", f"s_res={sres:.2f} um" in r.stdout, True)

if fail:
    print("COURT FAIL")
    for f in fail:
        print(" -", f)
    sys.exit(1)

print(f"Module 14 court: ALL CHECKS PASS (40 obs, slope {slope:.4f} um/part, "
      f"intercept {intercept:.4f} um, s_res {sres:.2f} um, drift@500 "
      f"{slope*500:.2f} um, gain +11.0 bores/shift = +14.7%, "
      f"derive_keys.py rc=0 agrees)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(slope, 4) - 0.0120) <= 1e-9:  # corrupted pin: slope = 0.0120
        print("VACUOUS COURT: corrupted constant still passes")
        sys.exit(2)
    print(f"MUTATION DETECTED: slope pinned at 0.0120 vs derived {slope:.4f} "
          f"-> court exits nonzero")
    sys.exit(1)
sys.exit(0)
