#!/usr/bin/env python3
"""Monte Carlo bore-diameter stack model — CPPC SR-71 gimbal housing (Lane 08).

Stack function (bore diameter deviation from 12.000 mm, micrometers):

    D = b + t + f + d

  b: bore machining diameter contribution   mean 0.000 um, tolerance +/-0.010 mm
  t: spindle thermal growth contribution    mean +2.000 um, tolerance +/-0.008 mm
  f: fixture location contribution          mean 0.000 um, tolerance +/-0.006 mm
  d: tool deflection contribution           mean -1.000 um, tolerance +/-0.005 mm

Each contributor is modeled NORMAL with sigma = tolerance/3 (the +/- tolerance
band is treated as a +/-3 sigma natural tolerance band). Spec on the stack:
D must lie within +/-25 um (CTQ-1: bore 12.000 +/- 0.025 mm).

Outputs (all stdout, python3 stdlib only, seed stated):
  - 1k / 5k / 10k convergence table (P0.13 / P50 / P99.87 in um)
  - 10k percentile report vs spec limits
  - analytic worst-case and RSS comparison
  - probability of interference (MC estimate + analytic)
  - variance-share + correlation tornado ranking
  - Cpk verdict vs 1.33 target
"""
import random
import math
import sys

SEED = 20261104
SPEC_LO, SPEC_HI = -25.0, 25.0          # um
CPK_TARGET = 1.33
RUNS = [1000, 5000, 10000]

# name, mean um, tol um (+/-), cost weight (1 = cheap to tighten, higher = expensive)
CONTRIBUTORS = [
    ("bore_diameter",   0.0, 10.0, 1.0),
    ("spindle_thermal", 2.0,  8.0, 4.0),
    ("fixture_loc",     0.0,  6.0, 2.0),
    ("tool_deflection", -1.0, 5.0, 1.5),
]


def percentile(sorted_xs, p):
    """Linear-interpolated percentile, p in [0,100]."""
    n = len(sorted_xs)
    if n == 1:
        return sorted_xs[0]
    pos = (n - 1) * p / 100.0
    lo = int(math.floor(pos))
    hi = min(lo + 1, n - 1)
    frac = pos - lo
    return sorted_xs[lo] * (1 - frac) + sorted_xs[hi] * frac


def simulate(n, seed=SEED):
    rng = random.Random(seed)
    rows = []
    for _ in range(n):
        total = 0.0
        comps = []
        for _, mean, tol, _c in CONTRIBUTORS:
            v = rng.gauss(mean, tol / 3.0)
            comps.append(v)
            total += v
        rows.append((total, comps))
    return rows


def stats(rows):
    totals = sorted(r[0] for r in rows)
    p = {q: percentile(totals, q) for q in (0.13, 50.0, 99.87)}
    mu = sum(t for t, _ in rows) / len(rows)
    var = sum((t - mu) ** 2 for t, _ in rows) / (len(rows) - 1)
    sigma = math.sqrt(var)
    exceed = sum(1 for t, _ in rows if t < SPEC_LO or t > SPEC_HI)
    usl, lsl = SPEC_HI, SPEC_LO
    cpu, cpl = (usl - mu) / (3 * sigma), (mu - lsl) / (3 * sigma)
    return {"p013": p[0.13], "p50": p[50.0], "p9987": p[99.87],
            "mu": mu, "sigma": sigma, "exceed": exceed,
            "cpk": min(cpu, cpl), "n": len(rows)}


def analytic():
    means = [m for _, m, _, _ in CONTRIBUTORS]
    tols = [t for _, _, t, _ in CONTRIBUTORS]
    sigmas = [t / 3.0 for t in tols]
    mu = sum(means)
    wc = mu + sum(tols)
    wc_lo = mu - sum(tols)
    rss = math.sqrt(sum(s ** 2 for s in sigmas))
    # analytic interference probability, normal sum
    z_hi = (SPEC_HI - mu) / rss
    z_lo = (SPEC_LO - mu) / rss
    phi = lambda z: 0.5 * (1 + math.erf(z / math.sqrt(2)))
    p_fail = (1 - phi(z_hi)) + phi(z_lo)
    cpk = min(SPEC_HI - mu, mu - SPEC_LO) / (3 * rss)
    return mu, wc, wc_lo, rss, p_fail, cpk


def tornado(rows):
    n = len(rows)
    totals = [t for t, _ in rows]
    mu_t = sum(totals) / n
    var_t = sum((x - mu_t) ** 2 for x in totals) / (n - 1)
    out = []
    for i, (name, _, _, _) in enumerate(CONTRIBUTORS):
        xs = [r[1][i] for r in rows]
        mu_x = sum(xs) / n
        var_x = sum((x - mu_x) ** 2 for x in xs) / (n - 1)
        cov = sum((xs[j] - mu_x) * (totals[j] - mu_t) for j in range(n)) / (n - 1)
        corr = cov / math.sqrt(var_x * var_t)
        share = var_x / var_t  # exact for independent additive model
        out.append((name, corr, share))
    out.sort(key=lambda r: -r[2])
    return out


def allocation():
    """Tolerance allocation to meet worst-case-acceptance target of 24 um
    (25 um spec minus 1 um net mean shift).

    Proportional scaling: t_i' = k * t_i with k = budget / sum(t_i).

    Cost-weighted (equal marginal cost): minimize sum c_i * (t_i - t_i')/t_i
    subject to sum t_i' = budget. Lagrange: c_i / t_i * lambda equalized ->
    t_i' = t_i * (1 - lam / c_i). Cheap contributors (low c) absorb the cut;
    expensive ones (high c) are barely tightened."""
    tols = [t for _, _, t, _ in CONTRIBUTORS]
    means = [m for _, m, _, _ in CONTRIBUTORS]
    costs = [c for _, _, _, c in CONTRIBUTORS]
    mu = sum(means)
    budget = SPEC_HI - mu  # 24.0 um
    k = budget / sum(tols)
    prop = [k * t for t in tols]
    lam = (sum(tols) - budget) / sum(t / c for t, c in zip(tols, costs))
    cw = [t * (1.0 - lam / c) for t, c in zip(tols, costs)]
    def rss(ts):
        return math.sqrt(sum((t / 3.0) ** 2 for t in ts))
    return k, lam, prop, cw, rss(prop), rss(cw)


def main():
    print(f"SEED={SEED}")
    print("MODEL: D = b + t + f + d (um from 12.000 mm); normal, sigma=tol/3")
    print("SPEC: -25 .. +25 um; CPK_TARGET=%.2f" % CPK_TARGET)
    print()
    print("== convergence (independent seeds per run-count ladder) ==")
    print("runs,p0.13,p50,p99.87,mu,sigma,exceedances,cpk")
    ref = None
    for n in RUNS:
        s = stats(simulate(n, SEED))
        if n == 10000:
            ref = s
        print("%d,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f" %
              (n, s["p013"], s["p50"], s["p9987"], s["mu"], s["sigma"],
               s["exceed"], s["cpk"]))
    print()
    print("== 10k percentile report vs spec ==")
    print("P0.13=%.2f um (LSL -25)  P50=%.2f  P99.87=%.2f um (USL +25)" %
          (ref["p013"], ref["p50"], ref["p9987"]))
    print("mu=%.3f um sigma=%.3f um Cpk=%.3f target=%.2f -> %s" %
          (ref["mu"], ref["sigma"], ref["cpk"], CPK_TARGET,
           "PASS" if ref["cpk"] >= CPK_TARGET else "FAIL"))
    print()
    print("== interference probability ==")
    print("MC 10k exceedances=%d -> p_hat=%.4f (95%% upper bound %.4f, rule-of-3)" %
          (ref["exceed"], ref["exceed"] / ref["n"], 3.0 / ref["n"]))
    mu_a, wc_hi, wc_lo, rss_a, p_fail, cpk_a = analytic()
    print("analytic p_fail=%.3e (z_hi=%.2f z_lo=%.2f)" %
          (p_fail, (25 - mu_a) / rss_a, (-25 - mu_a) / rss_a))
    print()
    print("== method comparison (same stack) ==")
    print("worst-case: band [%.1f, %.1f] um vs spec [-25, +25] -> %s" %
          (wc_lo, wc_hi, "FAIL" if (wc_hi > 25 or wc_lo < -25) else "PASS"))
    print("RSS: sigma=%.2f um, 3-sigma band [%.1f, %.1f] -> %s ; Cpk=%.2f" %
          (rss_a, mu_a - 3 * rss_a, mu_a + 3 * rss_a,
           "PASS" if cpk_a >= CPK_TARGET else "FAIL", cpk_a))
    print("Monte Carlo: Cpk=%.3f, p_fail_analytic=%.2e -> %s" %
          (cpk_a, p_fail, "PASS" if cpk_a >= CPK_TARGET else "FAIL"))
    print()
    print("== tornado (variance share + corr to output, 10k runs) ==")
    print("contributor,corr,var_share_pct")
    for name, corr, share in tornado(simulate(10000, SEED)):
        print("%s,%.4f,%.2f" % (name, corr, 100 * share))
    print()
    print("== tolerance allocation to WC-acceptance budget 24.0 um ==")
    k, lam, prop, cw, rss_p, rss_c = allocation()
    wc_p, wc_c = sum(prop), sum(cw)
    print("scale k=%.4f  lagrange lambda=%.4f" % (k, lam))
    print("method,bore_diameter,spindle_thermal,fixture_loc,tool_deflection,RSS_um,WC_um")
    print("current,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f" %
          (tuple([t for _, _, t, _ in CONTRIBUTORS]) +
           (math.sqrt(sum((t / 3) ** 2 for _, _, t, _ in CONTRIBUTORS)),
            sum(t for _, _, t, _ in CONTRIBUTORS))))
    print("proportional,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f" % (*prop, rss_p, wc_p))
    print("cost-weighted,%.2f,%.2f,%.2f,%.2f,%.2f,%.1f" % (*cw, rss_c, wc_c))


if __name__ == "__main__":
    sys.exit(main())
