#!/usr/bin/env python3
"""Court: re-derives every cost in module 06 from raw parameters and asserts
the rollups match the pinned RUNNING-CASE constants. Exit 0 = pass, 1 = fail.

Run: python3 courts/court.py   (from modules/06-target-costing/ or anywhere)
"""
import sys
from math import erf, sqrt

PHI = lambda z: 0.5 * (1 + erf(z / sqrt(2)))

FAILS = []

def check(name, cond, detail=""):
    if not cond:
        FAILS.append(f"{name}: {detail}")
    print(("PASS" if cond else "FAIL") + f"  {name}  {detail}")

def close(a, b, tol=1e-9):
    return abs(a - b) <= tol

# ---- pinned constants (RUNNING-CASE.md) ----
BASELINE_UNIT_COST = 41.80
CEILING = 28.50

# ---- raw parameters (worksheets/01) ----
DENSITY = 2.81          # g/cm^3
BILLET = (90, 90, 115)  # mm
PART_KG = 0.98
MAT_PRICE = 4.65        # $/kg
CHIP_CREDIT = 1.20      # $/kg
RATE = 52.0             # $/h
CYCLE = 22.40           # min
INCUT_FRAC = 0.78
INSERTS = 4
EDGE_LIFE = 52.0        # min
INSERT_PRICE = 4.50
SETUP_H = 3.2
LOT = 250
QC_MIN = 1.8
GAUGE_AMORT = 0.19
CPK_BASE = 0.72
OH_PCT = 0.11

def bore_defect_rate(cpk):
    """centered-normal: 2 * Phi(-3*Cpk)"""
    return 2 * PHI(-3 * cpk)

def teardown(cycle, incut_min, billet, setup_h, lot, qc_min, cpk):
    wt = billet[0] * billet[1] * billet[2] / 1000 * DENSITY / 1000  # kg
    matnet = wt * MAT_PRICE - (wt - PART_KG) * CHIP_CREDIT
    mach = cycle / 60 * RATE
    setup = setup_h * RATE / lot
    tool_rate = INSERTS / EDGE_LIFE * INSERT_PRICE  # $ per in-cut minute
    tool = incut_min * tool_rate
    qc = qc_min / 60 * RATE + GAUGE_AMORT
    scrap_content = matnet + 0.55 * mach
    scrap = bore_defect_rate(cpk) * scrap_content
    conv = mach + setup + tool + qc
    oh = OH_PCT * conv
    lines = dict(matnet=matnet, mach=mach, setup=setup, tool=tool,
                 qc=qc, scrap=scrap, oh=oh)
    return lines, sum(round(v, 2) for v in lines.values())

# ---- 1. baseline teardown rolls up to $41.80 ----
b, b_total = teardown(CYCLE, CYCLE * INCUT_FRAC, BILLET, SETUP_H, LOT, QC_MIN, CPK_BASE)
check("baseline-rounded-rollup", close(b_total, BASELINE_UNIT_COST),
      f"{b_total} vs pinned {BASELINE_UNIT_COST}")
check("baseline-defect-rate", close(bore_defect_rate(0.72), 0.030773, 1e-4),
      f"{bore_defect_rate(0.72):.6f}")

# ---- 2. gap ----
gap = round(BASELINE_UNIT_COST - CEILING, 2)
check("gap", close(gap, 13.30), f"{gap}")

# ---- 3. price point: allowable = price - profit ----
price, ros = 30.00, 0.05
check("allowable-cost", close(price * (1 - ros), CEILING), f"{price*(1-ros)}")

# ---- 4. WTP blend ----
wtp = (6500 * 31.80 + 3800 * 29.20 + 1700 * 27.40) / 12000
check("wtp-blend", close(wtp, 30.35, 0.005), f"{wtp:.4f}")

# ---- 5. future state: driver targets deployed ----
F_FEED_RATIO = 630 / 360
F_INCUT = CYCLE * INCUT_FRAC / F_FEED_RATIO
F_AIR = 3.10
F_CYCLE = F_INCUT + F_AIR
F_BILLET = (88, 88, 110)
F_SETUP_H, F_LOT, F_QC_MIN, F_CPK = 1.05, 400, 0.9, 1.33

f, f_total = teardown(F_CYCLE, F_INCUT, F_BILLET, F_SETUP_H, F_LOT, F_QC_MIN, F_CPK)
check("future-cycle", close(F_CYCLE, 13.084, 1e-3), f"{F_CYCLE:.4f} min")
check("future-under-ceiling", f_total <= CEILING, f"{f_total} <= {CEILING}")
check("future-total", close(f_total, 27.09), f"{f_total}")

# ---- 6. savings decomposition additive: sum of per-line diffs = total diff ----
savings = {k: round(b[k], 2) - round(f[k], 2) for k in b}
tot_savings = round(sum(savings.values()), 2)
check("savings-additive",
      close(tot_savings, round(BASELINE_UNIT_COST - f_total, 2)),
      f"line-sum {tot_savings} vs 41.80-{f_total}={round(BASELINE_UNIT_COST - f_total, 2)}")
expected = dict(matnet=0.78, mach=8.07, setup=0.53, tool=2.59, qc=0.78,
                scrap=0.64, oh=1.32)
for k, v in expected.items():
    check(f"savings-{k}", close(savings[k], v), f"{savings[k]} vs {v}")

# ---- 7. yield math ----
check("target-defect-rate", close(bore_defect_rate(1.33), 0.00006607, 1e-7),
      f"{bore_defect_rate(1.33):.8f}")
check("scrap-content-base", close(round(b['matnet'] + 0.55 * b['mach'], 2), 20.88),
      f"{b['matnet'] + 0.55 * b['mach']:.2f}")
check("scrap-content-future", close(round(f['matnet'] + 0.55 * f['mach'], 2), 15.67),
      f"{f['matnet'] + 0.55 * f['mach']:.2f}")

# ---- verdict ----
print()
if FAILS:
    print(f"COURT FAIL: {len(FAILS)} finding(s)")
    for f_ in FAILS:
        print("  -", f_)
    sys.exit(1)
print("COURT PASS: all re-derivations match")
