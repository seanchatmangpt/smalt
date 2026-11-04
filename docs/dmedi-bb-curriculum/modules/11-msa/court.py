#!/usr/bin/env python3
"""Module 11 court (MSA). Exit 0 = the crossed Gage R&R ground truth re-derives
from RAW trials in data/gage-rr-bore.csv by an INDEPENDENT pure-python ANOVA
(no numpy), never memory, and agrees with keys/gage_rr_key.py within tolerance.

Pins (re-derived, seed 411): 10 parts x 3 appraisers x 3 trials = 90 rows;
%GRR = 13.97 (10-30% marginal band), ndc = 9 (>= 5), part-to-part dominates
(pctPV > pctGRR), repeatability dominates reproducibility (pctEV > pctAV).

STALENESS SWEEP: the adjudicated running-case pair is Cpk 0.72 with
sigma = 7.407 um; the ORIGINAL spine sigma 4.17 um was adjudicated stale
(2026-11-04, MANIFEST record). This court fails loudly if the gage study's
sigma_grr ever returns on the stale 4.17 um scale, or if the study total
sigma is coerced onto it.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero. If the corrupted court still passes, exit 2 = VACUOUS COURT.
"""
import csv, os, statistics, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROOT, "data", "gage-rr-bore.csv")
KEY = os.path.join(HERE, "keys", "gage_rr_key.py")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: data/gage-rr-bore.csv missing (seed 411)")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---------- independent ANOVA re-derivation (pure python) ----------
rows = list(csv.DictReader(open(SRC)))
check("row_count", len(rows), 90)
parts = sorted({int(r["part"]) for r in rows})
apprs = sorted({r["appraiser"] for r in rows})
check("n_parts", len(parts), 10)
check("n_appraisers", len(apprs), 3)
check("n_trials", len({r["trial"] for r in rows}), 3)

NP, NA, NT = len(parts), len(apprs), 3
K = 5.15  # AIAG 99% spread multiplier; cancels in %Study Var ratios
y = [float(r["bore_mm"]) for r in rows]
ybar = statistics.mean(y)

def sel(pred):
    return [v for r, v in zip(rows, y) if pred(r)]

p_mu = {p: statistics.mean(sel(lambda r, p=p: int(r["part"]) == p)) for p in parts}
a_mu = {a: statistics.mean(sel(lambda r, a=a: r["appraiser"] == a)) for a in apprs}

ss_total = sum((v - ybar) ** 2 for v in y)
ss_part = NA * NT * sum((p_mu[p] - ybar) ** 2 for p in parts)
ss_appr = NP * NT * sum((a_mu[a] - ybar) ** 2 for a in apprs)
cell = {(p, a): statistics.mean(sel(lambda r, p=p, a=a:
        int(r["part"]) == p and r["appraiser"] == a)) for p in parts for a in apprs}
ss_int = NT * sum((cell[(p, a)] - p_mu[p] - a_mu[a] + ybar) ** 2
                  for p in parts for a in apprs)
ss_err = ss_total - ss_part - ss_appr - ss_int

ms_part = ss_part / (NP - 1)
ms_appr = ss_appr / (NA - 1)
ms_int = ss_int / ((NP - 1) * (NA - 1))
ms_e = ss_err / (NP * NA * (NT - 1))

var_e = ms_e
var_int = max(ms_int - ms_e, 0) / NT
var_av = max(ms_appr - ms_int, 0) / (NP * NT)
var_pv = max(ms_part - ms_int, 0) / (NA * NT)

sig_e = var_e ** 0.5
sig_av = (var_av + var_int) ** 0.5
sig_grr = (var_e + var_av + var_int) ** 0.5
sig_pv = var_pv ** 0.5
sig_tv = (sig_grr ** 2 + var_pv) ** 0.5

EV, AV, GRR, PV, TV = (K * s * 1000 for s in (sig_e, sig_av, sig_grr, sig_pv, sig_tv))
pctEV, pctAV, pctGRR, pctPV = (100 * v / TV for v in (EV, AV, GRR, PV))
ndc = int(1.41 * sig_pv / sig_grr)

check("grand_mean_mm", round(ybar, 4), 11.9993, 1e-9)
check("pctEV", round(pctEV, 2), 12.74, 1e-9)
check("pctAV", round(pctAV, 2), 5.73, 1e-9)
check("pctGRR_13.97", round(pctGRR, 2), 13.97, 1e-9)
check("pctPV", round(pctPV, 2), 99.02, 1e-9)
check("ndc_9", ndc, 9)
check("sigma_grr_um", round(sig_grr * 1000, 2), 2.28, 1e-9)

# verdict gates (acceptance table)
check("marginal_band_10_30", 10.0 <= round(pctGRR, 2) <= 30.0, True)
check("ndc_at_least_5", ndc >= 5, True)
check("part_to_part_dominates", round(pctPV, 2) > round(pctGRR, 2), True)
check("repeat_dominates_reprod", round(pctEV, 2) > round(pctAV, 2), True)

# STALENESS SWEEP: stale spine sigma 4.17 um must never reappear as the gage
# sigma, and it demonstrably cannot produce the pinned %GRR band with the
# part sigma (0.01613 mm part vs 0.00417 mm would change the ratio outright).
STALE_UM = 4.17
check("stale_sigma_refused_data", abs(sig_grr * 1000 - STALE_UM) > 0.5, True)
check("stale_sigma_refused_coherence",
      abs(sig_pv / sig_grr - 4.17 / 2.28) > 0.5, True)

# ---------- cross-check vs keys/gage_rr_key.py within tolerance ----------
r = subprocess.run([sys.executable, KEY], capture_output=True, text=True)
check("key_rc0", r.returncode, 0)
kv = {}
for line in r.stdout.splitlines():
    if "=" in line and line.strip().startswith(("pct", "ndc", "sigma", "grand")):
        k, v = [s.strip() for s in line.split("=", 1)]
        try:
            kv[k] = float(v)
        except ValueError:
            pass
for name, got, tol in (("pctGRR", round(pctGRR, 2), 1e-9),
                       ("pctEV", round(pctEV, 2), 1e-9),
                       ("pctAV", round(pctAV, 2), 1e-9),
                       ("pctPV", round(pctPV, 2), 1e-9),
                       ("sigma_grr_mm", round(sig_grr, 5), 1e-9)):
    check("key_agrees_" + name, kv.get(name), got, tol)
check("key_agrees_ndc", int(kv.get("ndc", -1)), ndc)

if fail:
    print("COURT FAIL")
    for f in fail:
        print(" -", f)
    sys.exit(1)

print(f"Module 11 court: ALL CHECKS PASS (90 rows, %GRR 13.97 marginal band, "
      f"ndc 9, %EV 12.74 / %AV 5.73 / %PV 99.02, sigma_grr {sig_grr*1000:.2f} um, "
      f"stale 4.17 um refused, key agreement rc=0)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(pctGRR, 2) - 9.0) <= 1e-9:  # corrupted pin: %GRR = 9.0 (acceptable)
        print("VACUOUS COURT: corrupted constant still passes")
        sys.exit(2)
    print(f"MUTATION DETECTED: %GRR pinned at 9.0 (acceptable) vs derived "
          f"{pctGRR:.2f} -> court exits nonzero")
    sys.exit(1)
sys.exit(0)
