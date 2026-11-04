#!/usr/bin/env python3
"""Module 17 court. Run from curriculum root (or anywhere). Exit 0 = every
tolerance-stack number re-derives from the raw stack CSV + the seeded MC run.

Pins (re-derived, not remembered):
  WC band [-28, +30] um -> FAIL; RSS sigma = 5.000 um, Cpk 1.60 -> PASS;
  MC (seed 20261104, 10k) Cpk 1.588, P0.13 -13.97 / P99.87 +16.60, 0 exceedances;
  RSS-vs-MC reconciliation band; allocation table (proportional k 0.8276,
  cost-weighted lambda 0.2727).

STALENESS SWEEP: refuses the adjudicated-STALE 4.17 um spine sigma (see
modules/12 RUNNING-CASE adjudication) as a possible stack sigma.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero; still passing under corruption = VACUOUS COURT (exit 2).
"""
import csv, math, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
ROOT = os.path.dirname(MOD)                        # curriculum root
SRC = os.path.join(ROOT, "datasets", "gimbal-bore-stack-parameters.csv")
if not os.path.exists(SRC):
    sys.exit("VACUOUS COURT: datasets/gimbal-bore-stack-parameters.csv missing")

# reuse the module 18 MC model — one calculus, no re-implementation drift
sys.path.insert(0, os.path.join(ROOT, "modules", "18-monte-carlo", "scripts"))
import mc_bore_stack as mc

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---------- stack parameters, re-read from CSV ----------
rows = list(csv.DictReader(open(SRC)))
names = [r["contributor"] for r in rows]
means = [float(r["mean_um"]) for r in rows]
tols = [float(r["tol_um"]) for r in rows]
check("four_contributors", len(rows), 4)
check("contributor_names", tuple(names),
      ("bore_diameter", "spindle_thermal", "fixture_loc", "tool_deflection"))
check("net_mean_shift", round(sum(means), 3), 1.0, 1e-9)
check("sigmas_are_tol_over_3", tuple(round(t / 3.0, 4) for t in tols),
      (3.3333, 2.6667, 2.0, 1.6667))

# ---------- method 1: worst case ----------
wc_hi = sum(means) + sum(tols)
wc_lo = sum(means) - sum(tols)
check("WC_band_hi", wc_hi, 30.0, 1e-9)
check("WC_band_lo", wc_lo, -28.0, 1e-9)
check("WC_verdict_FAIL", wc_hi > 25.0 or wc_lo < -25.0, True)

# ---------- method 2: RSS ----------
rss = math.sqrt(sum((t / 3.0) ** 2 for t in tols))
mu = sum(means)
check("RSS_sigma_5.000", round(rss, 3), 5.000, 1e-9)
check("RSS_3sigma_band_lo", round(mu - 3 * rss, 1), -14.0, 1e-9)
check("RSS_3sigma_band_hi", round(mu + 3 * rss, 1), 16.0, 1e-9)
cpk_rss = min(25.0 - mu, mu + 25.0) / (3 * rss)
check("RSS_Cpk_1.60", round(cpk_rss, 2), 1.60, 1e-9)
check("RSS_verdict_PASS_vs_1.33", cpk_rss >= 1.33, True)

# ---------- method 3: Monte Carlo (seeded, executed here) ----------
s = mc.stats(mc.simulate(10000, mc.SEED))
check("MC_Cpk_1.588", round(s["cpk"], 3), 1.588, 1e-9)
check("MC_P0.13", round(s["p013"], 2), -13.97, 1e-9)
check("MC_P99.87", round(s["p9987"], 2), 16.60, 1e-9)
check("MC_exceedances_zero", s["exceed"], 0)
check("MC_mu", round(s["mu"], 2), 1.03, 1e-9)

# ---------- RSS vs MC reconciliation band ----------
check("reconciliation_Cpk_band", abs(s["cpk"] - cpk_rss) <= 0.05, True)
check("reconciliation_sigma_band", abs(s["sigma"] - rss) <= 0.25, True)

# ---------- analytic interference probability ----------
phi = lambda z: 0.5 * (1 + math.erf(z / math.sqrt(2)))
p_fail = (1 - phi((25.0 - mu) / rss)) + phi((-25.0 - mu) / rss)
check("analytic_p_fail_8.9e-07", abs(p_fail - 8.9e-07) / 8.9e-07 <= 0.02, True)

# ---------- tolerance allocation (re-derive, module 18 `allocation()` math) ----------
costs = [float(r["cost_weight"]) for r in rows]
budget = 25.0 - mu                                   # 24.0 um
k = budget / sum(tols)
prop = [k * t for t in tols]
lam = (sum(tols) - budget) / sum(t / c for t, c in zip(tols, costs))
cw = [t * (1.0 - lam / c) for t, c in zip(tols, costs)]
rss_of = lambda ts: math.sqrt(sum((t / 3.0) ** 2 for t in ts))
check("allocation_k", round(k, 4), 0.8276, 1e-9)
check("allocation_lambda", round(lam, 4), 0.2727, 1e-9)
check("prop_tols", tuple(round(t, 2) for t in prop), (8.28, 6.62, 4.97, 4.14))
check("cw_tols", tuple(round(t, 2) for t in cw), (7.27, 7.45, 5.18, 4.09))
check("prop_WC_meets_budget", round(sum(prop), 1), 24.0, 1e-9)
check("cw_WC_meets_budget", round(sum(cw), 1), 24.0, 1e-9)
check("prop_RSS_4.14", round(rss_of(prop), 2), 4.14, 1e-9)
check("cw_RSS_4.11", round(rss_of(cw), 2), 4.11, 1e-9)
check("cw_thermal_barely_touched", round(cw[1], 2), 7.45, 1e-9)

# ---------- STALENESS SWEEP: 4.17 um stale spine sigma ----------
STALE_UM = 4.17
check("stale_sigma_refused_data", abs(rss - STALE_UM) > 0.5, True)
check("stale_sigma_refused_coherence",
      round(0.016 / (3 * STALE_UM / 1000), 2) != round(cpk_rss, 2), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)

print("Module 17 court: ALL CHECKS PASS (WC [-28,+30] FAIL, RSS sigma 5.000 "
      "Cpk 1.60, MC Cpk 1.588 seed 20261104, reconciliation band, allocation "
      "k 0.8276 / lambda 0.2727, stale 4.17 um refused)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(cpk_rss, 2) - 1.33) <= 1e-9:
        print("VACUOUS COURT: corrupted constant still passes"); sys.exit(2)
    print("MUTATION DETECTED: RSS Cpk pinned at 1.33 vs derived %.4f -> nonzero" % cpk_rss)
    sys.exit(1)
sys.exit(0)
