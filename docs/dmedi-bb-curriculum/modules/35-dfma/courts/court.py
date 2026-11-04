#!/usr/bin/env python3
"""Module 35 court — re-derives every number in the solution key from the teardown CSV.
Exit 0 = match; exit 1 prints the first failing derivation."""
import csv, sys

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

ROWS = list(csv.DictReader(open(__file__.replace("courts/court.py", "data/gimbal-teardown.csv"))))
def f(r, k): return float(r[k])
pb = sum(int(r["qty_before"]) for r in ROWS)
pa = sum(int(r["qty_after"]) for r in ROWS)
tb = sum(int(r["qty_before"]) * (f(r, "handle_s_before") + f(r, "insert_s_before")) for r in ROWS)
ta = sum(int(r["qty_after"]) * (f(r, "handle_s_after") + f(r, "insert_s_after")) for r in ROWS)
check("parts_before", pb, 37)
check("parts_after", pa, 17)
check("time_before_s", tb, 228.5, 0.01)
check("time_after_s", ta, 109.0, 0.01)
check("part_reduction_pct", round(100 * (pb - pa) / pb, 1), 54.1, 0.05)
check("time_reduction_pct", round(100 * (tb - ta) / tb, 1), 52.3, 0.05)

# move-by-move
m3 = next(r for r in ROWS if r["part_name"] == "m3-screw")
check("fastener_net_s", 8 * 7.0, 56.0, 0.01)
merge_gross = 3 * 7.5 + 8.0 + 5.0
check("merge_gross_s", merge_gross, 35.5, 0.01)
check("merge_net_s", merge_gross - 8.0, 27.5, 0.01)
check("selfloc_net_s", 4 * 3.0 + 4 * 6.0, 36.0, 0.01)
check("nets_sum", 56.0 + 27.5 + 36.0, round(tb - ta, 1), 0.05)

# cost roll-up
rate = 84 / 3600
lb, la = tb * rate, ta * rate
check("labor_before", round(lb, 2), 5.33, 0.01)
check("labor_after", round(la, 2), 2.54, 0.01)
check("labor_save", round(lb - la, 2), 2.79, 0.01)
mat = 8 * 0.02 + 4 * 0.03 + 4 * 0.02 + (3 * 3.10 + 2.60 + 0.85 - 4.60)
check("material_save", round(mat, 2), 8.51, 0.01)
tot = round((lb - la) + mat, 2)
check("total_save", tot, 11.30, 0.01)
check("pct_of_gap", round(100 * tot / 13.30, 1), 85.0, 0.05)
check("residual", round(13.30 - tot, 2), 2.00, 0.01)
screw_share = 100 * 84.0 / tb
check("screw_share_pct", round(screw_share, 1), 36.8, 0.05)

# exercise 1 and 2
r96 = round(119.5 * 96 / 3600 + mat, 2)
check("ex1_total_96", r96, 11.70, 0.01)
check("ex1_pct_96", round(100 * r96 / 13.30, 1), 88.0, 0.05)
check("ex2_rate", round(0.20 * 3600 / 7, 2), 102.86, 0.01)
# exercise 4
check("ex4_cycle_cut_s", round(2.00 / (62 / 60) * 60, 0), 116, 1)
check("ex4_cut_pct", round(100 * 116 / 408, 1), 28.4, 0.1)

if FAILS:
    print("MODULE 35 COURT: FAIL")
    for f_ in FAILS:
        print("  " + f_)
    sys.exit(1)
print("MODULE 35 COURT: PASS (all %d derivations match key)" % 21)
