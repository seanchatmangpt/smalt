#!/usr/bin/env python3
"""Solution key — Module 11: crossed Gage R&R (ANOVA method).

Re-derives every reported figure from the raw CSV (provenance law).
Exit 0 = key verified; any assertion failure = non-zero exit.

Usage: python3 modules/11-msa/keys/gage_rr_key.py
"""
import sys, os
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CSV = os.path.join(ROOT, "data", "gage-rr-bore.csv")

n_parts, n_appr, n_trials = 10, 3, 3
K = 5.15  # AIAG 99% spread multiplier (6.0 in MSA 4th ed); cancels in all %Study Var ratios

rows = []
with open(CSV) as f:
    next(f)
    for line in f:
        p, a, t, y = line.strip().split(",")
        rows.append((int(p), a, int(t), float(y)))
assert len(rows) == 90, f"expected 90 rows, got {len(rows)}"

y = np.array([r[3] for r in rows]); P = np.array([r[0] for r in rows])
Ap = np.array([ord(r[1]) - 65 for r in rows])
ybar = y.mean()

p_mu = np.array([y[P == p].mean() for p in range(1, n_parts + 1)])
a_mu = np.array([y[Ap == a].mean() for a in range(n_appr)])
cell = np.array([[y[(P == p + 1) & (Ap == a)].mean() for a in range(n_appr)]
                 for p in range(n_parts)])

SS_total = ((y - ybar) ** 2).sum()
SS_part = n_appr * n_trials * ((p_mu - ybar) ** 2).sum()
SS_appr = n_parts * n_trials * ((a_mu - ybar) ** 2).sum()
SS_int = n_trials * ((cell - p_mu[:, None] - a_mu[None, :] + ybar) ** 2).sum()
SS_err = SS_total - SS_part - SS_appr - SS_int

MS_part = SS_part / (n_parts - 1)
MS_appr = SS_appr / (n_appr - 1)
MS_int = SS_int / ((n_parts - 1) * (n_appr - 1))
MS_e = SS_err / (n_parts * n_appr * (n_trials - 1))

var_e = MS_e
var_int = max(MS_int - MS_e, 0) / n_trials
var_av = max(MS_appr - MS_int, 0) / (n_parts * n_trials)
var_pv = max(MS_part - MS_int, 0) / (n_appr * n_trials)

sig_e = np.sqrt(var_e); sig_av = np.sqrt(var_av + var_int)
sig_grr = np.sqrt(var_e + var_av + var_int)
sig_pv = np.sqrt(var_pv); sig_tv = np.sqrt(sig_grr ** 2 + var_pv)

EV, AV, GRR, PV, TV = (K * s * 1000 for s in (sig_e, sig_av, sig_grr, sig_pv, sig_tv))  # um
pctEV, pctAV, pctGRR, pctPV = (100 * v / TV for v in (EV, AV, GRR, PV))
ndc = int(1.41 * sig_pv / sig_grr)

keys = {
    "grand_mean_mm": round(ybar, 4),
    "MS_part": round(MS_part, 7), "MS_appr": round(MS_appr, 7),
    "MS_int": round(MS_int, 7), "MS_e": round(MS_e, 7),
    "F_part": round(MS_part / MS_int, 2), "F_appr": round(MS_appr / MS_int, 2),
    "EV_um": round(EV, 3), "AV_um": round(AV, 3), "GRR_um": round(GRR, 3),
    "PV_um": round(PV, 3), "TV_um": round(TV, 3),
    "pctEV": round(pctEV, 2), "pctAV": round(pctAV, 2),
    "pctGRR": round(pctGRR, 2), "pctPV": round(pctPV, 2),
    "ndc": ndc,
    "sigma_repeat_mm": round(sig_e, 5), "sigma_reprod_mm": round(sig_av, 5),
    "sigma_grr_mm": round(sig_grr, 5), "sigma_part_mm": round(sig_pv, 5),
    "sigma_total_mm": round(sig_tv, 5),
}

# ---- teaching-band + verdict gates (court) ----
assert 10.0 <= keys["pctGRR"] <= 30.0, f"%GRR {keys['pctGRR']} outside 10-30 teaching band"
assert keys["ndc"] >= 5, "ndc must be >= 5 for a marginal-acceptable teaching case"
assert keys["pctPV"] > keys["pctGRR"], "part-to-part must dominate in this seeded case"
assert keys["pctEV"] > keys["pctAV"], "repeatability must dominate reproducibility here"

print("GAGE-RR KEY (re-derived from data/gage-rr-bore.csv, seed 411)")
for k, v in keys.items():
    print(f"  {k} = {v}")
print("  verdict = %GRR in 10-30%%: acceptable for process analysis,")
print("             not acceptable for SPC on a 50 um tolerance; ndc >= 5.")
sys.exit(0)
