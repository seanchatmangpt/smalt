#!/usr/bin/env python3
"""Module 02 court — re-derives every number in the README, solution-key, lab,
and exercises from this module's two CSVs. Exit 0 = pass; exit 1 = mismatches."""
import csv, os, statistics, sys
MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from math import sqrt
from statistics import NormalDist

FAILS = []
N = 0
def check(name, got, want, tol=0.0):
    global N
    N += 1
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

# ---- CTQ-1 defect stream ----
rows = list(csv.DictReader(open(os.path.join(MOD, 'data/bore-inspection-dpmo.csv'))))
U = sum(int(r['units_inspected']) for r in rows)
D = sum(int(r['defects_found']) for r in rows)
DPU = D / U
DPMO1 = D / U * 1e6
DPMO6 = D / (U * 6) * 1e6
DPO = D / (U * 6)
z = NormalDist().inv_cdf(1 - DPO)
check('days', len(rows), 20)
check('units', U, 4048)
check('defects', D, 49)
check('DPU_5dp', round(DPU, 5), 0.01210)
check('DPMO_1opp', round(DPMO1, 1), 12104.7)
check('DPMO_6opp', round(DPMO6, 1), 2017.5)
check('DPO_7dp', round(DPO, 7), 0.0020175)
check('z_3dp', round(z, 3), 2.875)
check('sigma_level_2dp', round(z + 1.5, 2), 4.38)
check('sigma_level_1opp', round(NormalDist().inv_cdf(1 - D / U) + 1.5, 2), 3.75)

# ---- CTQ-2 lead time ----
rows2 = list(csv.DictReader(open(os.path.join(MOD, 'data/order-lead-time.csv'))))
lt = [float(r['lead_time_days']) for r in rows2]
srt = sorted(lt)
def pct(d, p):
    k = (len(d) + 1) * p; fl = int(k); fr = k - fl
    return d[fl - 1] + fr * (d[fl] - d[fl - 1])
over7 = sum(1 for v in lt if v > 7)
check('lead_n', len(lt), 40)
check('lead_mean', round(statistics.mean(lt), 2), 17.8)
check('lead_median', round(statistics.median(lt), 2), 17.35)
check('lead_sd', round(statistics.stdev(lt), 2), 4.35)
check('lead_min', min(lt), 9.1)
check('lead_max', max(lt), 26.3)
check('lead_P90', round(pct(srt, 0.9), 1), 24.1)
check('over7_count', over7, 40)
check('over7_pct', round(100 * over7 / len(lt), 1), 100.0)
check('se_mean', round(statistics.stdev(lt) / sqrt(len(lt)), 2), 0.69)

if FAILS:
    print("MODULE 02 COURT: FAIL")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print(f"MODULE 02 COURT: PASS ({N} checks)")
sys.exit(0)
