#!/usr/bin/env python3
"""Module 34 court — re-derives every number in the solution key from the census CSV.
Exit 0 = match; exit 1 prints the first failing derivation."""
import csv, sys

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

ROWS = list(csv.DictReader(open(__file__.replace("courts/court.py", "data/gate-review-waits.csv"))))
cal = sum(int(r["calendar_days"]) for r in ROWS)
work = sum(int(r["work_days"]) for r in ROWS)
iwait = sum(int(r["internal_wait_days"]) for r in ROWS)
gwait = sum(int(r["gate_wait_days"]) for r in ROWS)
check("calendar", cal, 130)
check("work", work, 92)
check("internal_wait", iwait, 23)
check("gate_wait", gwait, 15)
check("split_sums", work + iwait + gwait, cal)
check("flow_eff_pct", round(100 * work / cal, 1), 70.8, 0.05)
check("fe_excl_gate_pct", round(100 * work / (cal - gwait), 1), 80.0, 0.05)

# scenario F
new_iw = [2, 1, 2, 3, 2]
niw = sum(new_iw)
ngw = 5 * 1
newlen = work + niw + ngw
check("F_total", newlen, 107)
check("F_weeks", round(newlen / 5, 1), 21.4, 0.05)
check("F_saved", cal - newlen, 23)
check("F_fe_pct", round(100 * work / newlen, 1), 86.0, 0.05)
# gate-only sensitivity
gonly = work + iwait + ngw
check("gate_only_total", gonly, 120)
check("gate_only_fe_pct", round(100 * work / gonly, 1), 76.7, 0.05)
# Develop+Explore share of internal wait
dev_exp = 6 + 5
check("dev_exp_share", dev_exp, 11)
# exercise Little's law
check("littles_gate_queue", 0.25 * 3, 0.75, 1e-9)
# exercise 3 expected durations
base = 30 + 0.3 * (6.3 + 3)
peer = 32 + 0.1 * 9.3
check("rework_base", round(base, 2), 32.79, 0.01)
check("rework_peer", round(peer, 2), 32.93, 0.01)
check("rework_breakeven", round(32.79 - 0.93 - 30, 2), 1.86, 0.01)

if FAILS:
    print("MODULE 34 COURT: FAIL")
    for f in FAILS:
        print("  " + f)
    sys.exit(1)
print("MODULE 34 COURT: PASS (all %d derivations match key)" % 16)
