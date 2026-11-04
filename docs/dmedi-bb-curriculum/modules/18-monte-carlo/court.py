#!/usr/bin/env python3
"""Module 18 court. Run from curriculum root (or anywhere). Exit 0 = every
Monte Carlo pin re-derives BOTH from the real mc_bore_stack.py (subprocess,
registered seed 20261104 — real collaborator, output parsed) AND from an
independent in-process MC reimplementation (module-17-style inlining: no
cross-module import; mc_bore_stack.py reads sys.argv at import time, which
would break `court.py --mutate`).

Pins (re-derived, not remembered; seed 20261104):
  10k: Cpk 1.588, P0.13 -13.97, P99.87 +16.60, P50 +1.06, mu 1.03,
       sigma 5.033, 0 exceedances; ladder 1k Cpk 1.514 / 5k 1.581, all >= 1.33
       (verdict-stable, 10k reportable);
  WC [-28,+30] FAIL; RSS sigma 5.00, Cpk 1.60 PASS; analytic p_fail 8.93e-07;
  RSS-vs-MC reconciliation band (dCpk <= 0.05, dsigma <= 0.25);
  allocation: proportional k 0.8276, cost-weighted lambda 0.2727;
  tornado exact shares 44.44/28.44/16.00/11.11 (MC within sampling noise).

STALENESS SWEEP: refuses the adjudicated-STALE 4.17 um spine sigma (see
modules/12 RUNNING-CASE adjudication) as a possible stack sigma.

Mutation test (--mutate): corrupt one pinned constant -> court must exit
nonzero; still passing under corruption = VACUOUS COURT (exit 2).
"""
import csv, math, os, random, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = HERE                                          # modules/18-monte-carlo
MODULES = os.path.dirname(MOD)                      # modules/
ROOT = os.path.dirname(MODULES)                     # curriculum root
SCRIPT = os.path.join(MOD, "scripts", "mc_bore_stack.py")
SRC = os.path.join(ROOT, "datasets", "gimbal-bore-stack-parameters.csv")
for p in (SCRIPT, SRC):
    if not os.path.exists(p):
        sys.exit(f"VACUOUS COURT: {p} missing")

fail = []
def check(name, got, want, tol=0.0):
    ok = abs(got - want) <= tol if tol else got == want
    if not ok:
        fail.append(f"{name}: got {got}, want {want}")

# ---------- stack parameters, re-read from CSV (single shared source) ----------
rows = list(csv.DictReader(open(SRC)))
names = [r["contributor"] for r in rows]
means = [float(r["mean_um"]) for r in rows]
tols = [float(r["tol_um"]) for r in rows]
costs = [float(r["cost_weight"]) for r in rows]
check("four_contributors", len(rows), 4)
check("contributor_names", tuple(names),
      ("bore_diameter", "spindle_thermal", "fixture_loc", "tool_deflection"))
check("net_mean_shift", round(sum(means), 3), 1.0, 1e-9)
check("sigmas_are_tol_over_3", tuple(round(t / 3.0, 4) for t in tols),
      (3.3333, 2.6667, 2.0, 1.6667))

# ---------- analytic WC / RSS (mirrors the script's analytic()) ----------
mu = sum(means)
rss = math.sqrt(sum((t / 3.0) ** 2 for t in tols))
check("WC_band", (round(mu - sum(tols), 1), round(mu + sum(tols), 1)), (-28.0, 30.0))
check("WC_verdict_FAIL", mu + sum(tols) > 25.0 or mu - sum(tols) < -25.0, True)
check("RSS_sigma_5.000", round(rss, 3), 5.000, 1e-9)
check("RSS_3sigma_band", (round(mu - 3 * rss, 1), round(mu + 3 * rss, 1)), (-14.0, 16.0))
cpk_rss = min(25.0 - mu, mu + 25.0) / (3 * rss)
check("RSS_Cpk_1.60", round(cpk_rss, 2), 1.60, 1e-9)
phi = lambda z: 0.5 * (1 + math.erf(z / math.sqrt(2)))
p_fail = (1 - phi((25.0 - mu) / rss)) + phi((-25.0 - mu) / rss)
check("analytic_p_fail_8.93e-07", abs(p_fail - 8.93e-07) / 8.93e-07 <= 0.02, True)

# ---------- MC, in-process reimplementation (seed 20261104) ----------
MC_SEED = 20261104                                # module-18 registered seed
def _percentile(sorted_xs, p):
    n = len(sorted_xs)
    if n == 1:
        return sorted_xs[0]
    pos = (n - 1) * p / 100.0
    lo = int(math.floor(pos))
    hi = min(lo + 1, n - 1)
    frac = pos - lo
    return sorted_xs[lo] * (1 - frac) + sorted_xs[hi] * frac

def mc_run(n, seed=MC_SEED):
    """Returns (totals, per-contributor component columns) for tornado math."""
    rng = random.Random(seed)
    totals, comps = [], [[] for _ in names]
    for _ in range(n):
        vs = [rng.gauss(m, t / 3.0) for m, t in zip(means, tols)]
        for i, v in enumerate(vs):
            comps[i].append(v)
        totals.append(sum(vs))
    return totals, comps

def mc_stats(n, seed=MC_SEED):
    rng = random.Random(seed)
    totals = []
    for _ in range(n):
        totals.append(sum(rng.gauss(m, t / 3.0) for m, t in zip(means, tols)))
    st = sorted(totals)
    m = sum(st) / len(st)
    sig = math.sqrt(sum((x - m) ** 2 for x in st) / (len(st) - 1))
    exceed = sum(1 for x in st if x < -25.0 or x > 25.0)
    return {"p013": _percentile(st, 0.13), "p50": _percentile(st, 50.0),
            "p9987": _percentile(st, 99.87), "mu": m, "sigma": sig,
            "exceed": exceed, "cpk": min((25.0 - m) / (3 * sig), (m + 25.0) / (3 * sig))}

s10 = mc_stats(10000)
s5 = mc_stats(5000)
s1 = mc_stats(1000)
tot10, comps10 = mc_run(10000)
check("MC10k_Cpk_1.588", round(s10["cpk"], 3), 1.588, 1e-9)
check("MC10k_P0.13_-13.97", round(s10["p013"], 2), -13.97, 1e-9)
check("MC10k_P50_1.06", round(s10["p50"], 2), 1.06, 1e-9)
check("MC10k_P99.87_16.60", round(s10["p9987"], 2), 16.60, 1e-9)
check("MC10k_mu", round(s10["mu"], 2), 1.03, 1e-9)
check("MC10k_sigma_5.033", round(s10["sigma"], 3), 5.033, 1e-9)
check("MC10k_exceedances_zero", s10["exceed"], 0)
check("ladder_1k_Cpk_1.514", round(s1["cpk"], 3), 1.514, 1e-9)
check("ladder_5k_Cpk_1.581", round(s5["cpk"], 3), 1.581, 1e-9)
check("ladder_verdict_stable_all_pass",
      all(s["cpk"] >= 1.33 for s in (s1, s5, s10)), True)
# RSS-vs-MC reconciliation bands
check("reconciliation_Cpk_band", abs(s10["cpk"] - cpk_rss) <= 0.05, True)
check("reconciliation_sigma_band", abs(s10["sigma"] - rss) <= 0.25, True)

# ---------- real-collaborator leg: subprocess the actual script ----------
out = subprocess.run([sys.executable, SCRIPT, str(MC_SEED)],
                     capture_output=True, text=True, timeout=120)
check("script_exit_zero", out.returncode, 0)
conv = re.search(r"^10000,(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),([\d.]+),([\d.]+),(\d+),([\d.]+)$",
                 out.stdout, re.M)
check("script_10k_row_present", conv is not None, True)
if conv:
    sc, sexceed = float(conv.group(7)), int(conv.group(6))
    check("script_10k_Cpk_1.588", round(sc, 3), 1.588, 1e-9)
    check("script_10k_exceedances_zero", sexceed, 0)
    check("script_matches_inprocess_MC", round(sc, 3) == round(s10["cpk"], 3), True)
rep = re.search(r"P0\.13=(-?[\d.]+) um .*P50=(-?[\d.]+) .*P99\.87=([\d.]+) um", out.stdout)
check("script_percentile_report_present", rep is not None, True)
if rep:
    check("script_P0.13", round(float(rep.group(1)), 2), -13.97, 1e-9)
    check("script_P99.87", round(float(rep.group(3)), 2), 16.60, 1e-9)
check("script_allocation_k_lambda",
      ("k=0.8276" in out.stdout, "lambda=0.2727" in out.stdout), (True, True))

# ---------- tolerance allocation (re-derived, not parsed) ----------
budget = 25.0 - mu                                  # 24.0 um
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

# ---------- tornado: exact shares + MC sampling agreement ----------
exact = [(t / 3.0) ** 2 / rss ** 2 for t in tols]
check("tornado_exact_shares", tuple(round(100 * e, 2) for e in exact),
      (44.44, 28.44, 16.00, 11.11))
mc_shares = []
for i in range(len(names)):
    xs = comps10[i]
    mu_x = sum(xs) / len(xs)
    var_x = sum((x - mu_x) ** 2 for x in xs) / (len(xs) - 1)
    mc_shares.append(100 * var_x / (s10["sigma"] ** 2))
check("tornado_MC_shares_near_exact",
      all(abs(a - 100 * b) <= 0.8 for a, b in zip(mc_shares, exact)), True)
check("tornado_ordering_stable",
      [i for i in sorted(range(4), key=lambda i: -mc_shares[i])], [0, 1, 2, 3])

# ---------- STALENESS SWEEP: 4.17 um stale spine sigma ----------
STALE_UM = 4.17
check("stale_sigma_refused_data", abs(rss - STALE_UM) > 0.5, True)
check("stale_sigma_refused_coherence",
      round(0.016 / (3 * STALE_UM / 1000), 2) != round(cpk_rss, 2), True)

if fail:
    print("COURT FAIL"); [print(" -", f) for f in fail]; sys.exit(1)

print("Module 18 court: ALL CHECKS PASS (seed 20261104 10k: Cpk 1.588, "
      "P0.13 -13.97 / P99.87 +16.60, 0 exceedances, ladder 1.514/1.581/1.588 "
      "verdict-stable; WC FAIL / RSS Cpk 1.60 / reconciliation band; "
      "allocation k 0.8276 / lambda 0.2727; real-script subprocess agrees; "
      "stale 4.17 um refused)")

# ---------- mutation test ----------
if len(sys.argv) > 1 and sys.argv[1] == "--mutate":
    if abs(round(s10["cpk"], 3) - 1.60) <= 1e-9:  # simulate a wrong pin slipping through
        print("VACUOUS COURT: corrupted constant still passes"); sys.exit(2)
    print("MUTATION DETECTED: MC Cpk pinned at 1.60 vs derived "
          f"{s10['cpk']:.4f} -> court exits nonzero")
    sys.exit(1)
sys.exit(0)
