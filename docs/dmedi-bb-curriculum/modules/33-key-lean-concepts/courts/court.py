#!/usr/bin/env python3
"""Module 33 court — re-derives every number in the solution key from the census CSV.
Exit 0 = all derivations match; exit 1 prints the first failing derivation."""
import csv, sys

FAILS = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

ROWS = list(csv.DictReader(open(__file__.replace("courts/court.py", "data/vsm-baseline.csv"))))
wait = sum(float(r["wait_days"]) for r in ROWS)
pmin = sum(float(r["process_min"]) for r in ROWS)
pdays = pmin / 880.0
lead = wait + pdays
check("wait_total", wait, 17.6, 1e-9)
check("process_min", pmin, 677.5, 1e-9)
check("process_days", round(pdays, 4), 0.7699, 1e-9)
check("lead_vs_pinned", lead, 18.4, 0.05)
check("pce_pct", round(100 * pdays / lead, 1), 4.2, 0.05)

# takt
net_s = 2 * 8 * 60 * 2 - 80 * 2  # two shifts of 8h in minutes minus 80 min downtime... careful
net_s = (2 * 8 * 60 - 80) * 60  # 880 min in seconds
takt = net_s / 240.0
check("takt_s", takt, 220.0, 1e-9)
mill_s = 6.8 * 60
check("mill_ratio_takt", round(mill_s / takt, 2), 1.85, 0.01)
check("mill_daily_out", round(net_s / 60 / 6.8), 129, 0)
check("two_mill_effective_s", mill_s / 2, 204.0, 1e-9)

# improvement candidates
def lead_with(**repl):
    w = wait
    for k, v in repl.items():
        for r in ROWS:
            if r["stream_step"] == k:
                w += v - float(r["wait_days"])
    return w + pdays

check("C1_lead", round(lead_with(**{"op40-anodize": 1.0}), 2), 14.77, 0.01)
check("C2_lead", round(lead_with(**{"op60-pack": 1.0}), 2), 16.27, 0.01)
check("C3_lead", round(lead_with(**{"order-entry": 0.5}), 2), 16.67, 0.01)
w3 = wait - (4.6 - 1.0) - (3.1 - 1.0) - (2.2 - 0.5)
check("combined_lead", round(w3 + pdays, 2), 10.97, 0.01)
# kanban internal queues to 0.5 d each: saw, mill, deburr, CMM
w_kanban = w3 - (2.1 - 0.5) - (2.6 - 0.5) - (1.2 - 0.5) - (1.8 - 0.5)
lead_k = w_kanban + pdays
check("kanban_lead", round(lead_k, 2), 5.27, 0.01)
check("kanban_pce_pct", round(100 * pdays / lead_k, 1), 14.6, 0.1)

# Little's law exercise
check("littles_L", round(129 * 2.6), 335, 0)
check("littles_L_w1", round(129 * 1.0), 129, 0)

if FAILS:
    print("MODULE 33 COURT: FAIL")
    for f in FAILS:
        print("  " + f)
    sys.exit(1)
print("MODULE 33 COURT: PASS (all %d derivations match key)" % 15)
