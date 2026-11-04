#!/usr/bin/env python3
"""Module 03 court — re-derives the README/keys numbers from both CSVs, the
pinned-constant arithmetic used in the charter worksheets, and the risk/MGPP
arithmetic in the worksheets. Exit 0 = pass; exit 1 = mismatches."""
import csv, os, statistics, sys
MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAILS = []
N = 0
def check(name, got, want, tol=0.0):
    global N
    N += 1
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

# ---- ED door-to-provider ----
ed = list(csv.DictReader(open(os.path.join(MOD, 'data/ed-door-to-provider-minutes.csv'))))
t = [float(r['door_to_provider_min']) for r in ed]
over30 = sum(1 for v in t if v > 30)
check('ed_n', len(t), 80)
check('ed_mean_1dp', round(statistics.mean(t), 1), 53.1)
check('ed_median', round(statistics.median(t), 1), 52.0)
check('ed_sd_1dp', round(statistics.stdev(t), 1), 16.5)
check('ed_min', min(t), 9.0)
check('ed_max', max(t), 97.0)
check('ed_over30', over30, 75)
check('ed_over30_pct', round(100 * over30 / len(t), 1), 93.8)

# ---- Insurance claims ----
cl = list(csv.DictReader(open(os.path.join(MOD, 'data/insurance-claims-cycle-time.csv'))))
cyc = [float(r['cycle_time_days']) for r in cl if r['cycle_time_days'].strip()]
blank = sum(1 for r in cl if not r['closed_date'].strip())
check('claims_rows', len(cl), 60)
check('claims_with_cyc', len(cyc), 60)
check('claims_blank_closed', blank, 60)
check('claims_mean', round(statistics.mean(cyc), 2), 16.07)
check('claims_median', round(statistics.median(cyc), 2), 15.8)
check('claims_sd', round(statistics.stdev(cyc), 2), 4.88)
check('claims_max', max(cyc), 26.6)

# ---- pinned-constant arithmetic used in the charter examples ----
check('sigma_dist_usl', round((12.025 - 12.009) / 0.007407, 2), 2.16)
check('sigma_dist_lsl', round((12.009 - 11.975) / 0.007407, 2), 4.59)
check('allowable', round(30.00 * (1 - 0.05), 2), 28.50)
check('gap', round(41.80 - 28.50, 2), 13.30)
check('mgpp_annual', round(13.30 * 10000, 0), 133000.0)
check('mgpp_monthly', round(13.30 * 10000 / 12, 0), 11083.0)

# ---- worksheet risk arithmetic (worksheet 06) ----
risks = {'R1': (4, 5, 20), 'R2': (3, 4, 12), 'R3': (2, 4, 8),
         'R4': (3, 3, 9), 'R5': (2, 5, 10)}
for k, (l, i, s) in risks.items():
    check(f'{k}_score', l * i, s)
check('risk_rank_order', sorted(risks, key=lambda k: -risks[k][0] * risks[k][1]),
      ['R1', 'R2', 'R5', 'R4', 'R3'])

# ---- placeholder sweep: no TBD/TODO/placeholder in the module's own docs ----
# (court.md is exempt from the token sweep — it names the tokens to document
# this sweep — but must itself document the sweep to stay honest)
import glob
mds = [f for f in glob.glob(os.path.join(MOD, '**', '*.md'), recursive=True)
       if not f.endswith('court.md')]
cm = open(os.path.join(MOD, 'court.md')).read()
check('court-md-documents-sweep',
      'TBD' in cm and 'placeholder sweep'.lower() in cm.lower(), True)
for f in mds:
    txt = open(f).read()
    for bad in ('TBD', 'TODO', 'FIXME', 'XXX', 'Lorem'):
        if bad in txt:
            FAILS.append(f"{f}: contains placeholder token {bad}")
N += 1

if FAILS:
    print("MODULE 03 COURT: FAIL")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print(f"MODULE 03 COURT: PASS ({N} checks)")
sys.exit(0)
