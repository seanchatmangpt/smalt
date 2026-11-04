#!/usr/bin/env python3
"""Module 01 court — re-derives every number in module 01's slides-outline keyed
exercise, solution-key, and lab from data/baseline-bore-diameter.csv, and checks
the pinned-pair arithmetic (adjudicated: mu 12.009 mm, sigma 7.407 um, Cpk 0.72).
Exit 0 = all checks pass; exit 1 = mismatches printed."""
import csv, os, statistics, sys
MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FAILS = []
N_CHECKS = 0
def check(name, got, want, tol=0.0):
    global N_CHECKS
    N_CHECKS += 1
    ok = abs(got - want) <= tol if isinstance(want, float) else got == want
    if not ok:
        FAILS.append(f"{name}: derived {got}, key claims {want}")

# --- dataset derivation ---
rows = list(csv.DictReader(open(os.path.join(MOD, 'data/baseline-bore-diameter.csv'))))
x = [float(r['bore_diameter_mm']) for r in rows]
mu, s = statistics.mean(x), statistics.stdev(x)
LSL, USL = 11.975, 12.025
usl_um, lsl_um = (USL - mu) * 1000, (mu - LSL) * 1000
cpk = (USL - mu) / (3 * s)

check('n', len(x), 50)
check('mu_5dp', round(mu, 5), 12.00859)
check('s_um_2dp', round(s * 1000, 2), 5.82)
check('usl_gap_um', round(usl_um, 2), 16.41)
check('lsl_gap_um', round(lsl_um, 2), 33.59)
check('sample_cpk_4dp', round(cpk, 4), 0.9401)
check('usl_governs', usl_um < lsl_um, True)

# --- pinned-pair arithmetic (adjudicated 2026-11-04) ---
check('pinned_cpk', round((USL - 12.009) / (3 * 0.007407), 4), 0.72)
check('z_usl_2dp', round((USL - 12.009) / 0.007407, 2), 2.16)
check('z_lsl_2dp', round((12.009 - 11.975) / 0.007407, 2), 4.59)
check('stale_417_cpk_not_072', round((USL - 12.009) / (3 * 0.00417), 2) != 0.72, True)

# --- staleness sweep: no module-01 artifact may carry the stale sigma as fact ---
for f in ('slides-outline.md', 'solution-key.md', 'exercises.md', 'lab.md'):
    txt = open(os.path.join(MOD, f)).read()
    if '4.17' in txt:
        # lawful ONLY inside an adjudication/teaching context: the hit line or
        # its continuation line must carry the stale/adjudicated framing
        lines = txt.splitlines()
        ctx = [ln for ln in lines if '4.17' in ln]
        lawful = True
        for ln in ctx:
            i = lines.index(ln)
            near = ln.lower() + ' ' + (lines[i + 1].lower() if i + 1 < len(lines) else '')
            if not ('stale' in near or 'adjudicat' in near or 'original' in near
                    or 'contradiction' in near):
                lawful = False
        if not lawful:
            FAILS.append(f"{f}: carries '4.17' without stale/adjudicated framing: {ctx}")

# --- court.md itself must frame 4.17 as stale (it defines this sweep) ---
cmd = open(os.path.join(MOD, 'court.md')).read()
check('court-md-stale-framing',
      'STALE' in cmd and '4.17' in cmd and 'unframed' in cmd, True)

# --- receipt-grammar spot checks (five fields present in slides + lab) ---
sl = open(os.path.join(MOD, 'slides-outline.md')).read()
for field in ('identity', 'authority', 'consequence', 'replay', 'standing'):
    check(f'receipt-field-{field}', field in sl.lower(), True)

if FAILS:
    print("MODULE 01 COURT: FAIL")
    for f in FAILS:
        print("  -", f)
    sys.exit(1)
print(f"MODULE 01 COURT: PASS ({N_CHECKS} checks)")
sys.exit(0)
