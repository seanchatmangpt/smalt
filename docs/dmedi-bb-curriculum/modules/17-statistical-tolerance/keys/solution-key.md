# Module 17 Solution Key — Statistical tolerance stack (all numbers re-derived)

## The incantation

The court **is** the derivation. One exit-checked run re-derives every pinned
number in this module from the raw stack CSV plus a seeded MC executed inline
(no cross-module imports — the D18 portability law). Run from the curriculum
root:

```
python3 modules/17-statistical-tolerance/court.py; echo RC=$?   # RC=0
```

Full captured output (2026-11-04 run):

```
Module 17 court: ALL CHECKS PASS (WC [-28,+30] FAIL, RSS sigma 5.000
Cpk 1.60, MC Cpk 1.588 seed 20261104, reconciliation band, allocation
k 0.8276 / lambda 0.2727, stale 4.17 um refused)
```

The court's verdict line is the pin set; it does not print the per-run MC
table. The MC table below re-derives from the court's own inline model
verbatim (same `random.Random(20261104)`, same `gauss(mean, tol/3)` draws,
same linear-interpolated percentiles), extracted into this documented
heredoc so it can be replayed independently of the court:

```
python3 - <<'EOF'
import random, math
SEED = 20261104                                  # module-17/18 registered seed
CONTRIBUTORS = [                                 # (name, mean um, tol um)
    ("bore_diameter",   0.0, 10.0),
    ("spindle_thermal", 2.0,  8.0),
    ("fixture_loc",     0.0,  6.0),
    ("tool_deflection", -1.0, 5.0),
]
LO, HI = -25.0, 25.0
def pct(xs, p):                                  # linear-interpolated percentile
    n = len(xs); pos = (n - 1) * p / 100.0
    lo = int(pos); hi = min(lo + 1, n - 1); f = pos - lo
    return xs[lo] + (xs[hi] - xs[lo]) * f
def mc(n):
    rng = random.Random(SEED)
    t = [sum(rng.gauss(m, tl / 3.0) for _, m, tl in CONTRIBUTORS) for _ in range(n)]
    s = sorted(t)
    mu = sum(s) / len(s)
    sg = math.sqrt(sum((x - mu) ** 2 for x in s) / (len(s) - 1))
    ex = sum(1 for x in s if x < LO or x > HI)
    cpu, cpl = (HI - mu) / (3 * sg), (mu - LO) / (3 * sg)
    print(f"n={n:6d} seed=20261104 mu={mu:.3f} sigma={sg:.3f} "
          f"P0.13={pct(s,0.13):.2f} P99.87={pct(s,99.87):.2f} "
          f"exceed={ex} Cpk={min(cpu,cpl):.3f}")
for n in (1000, 10000):
    mc(n)
EOF
```

Executed output of that heredoc (2026-11-04):

```
n=  1000 seed=20261104 mu=1.377 sigma=5.202 P0.13=-12.47 P99.87=17.14 exceed=0 Cpk=1.514
n= 10000 seed=20261104 mu=1.029 sigma=5.033 P0.13=-13.97 P99.87=16.60 exceed=0 Cpk=1.588
```

Court-vs-heredoc match evidence (the 10k row must agree with the court's
pins to the court's own rounding tolerances):

| court check | court pin | heredoc 10k | match |
|---|---|---|---|
| MC_mu | 1.03 (2 dp) | 1.029 | yes |
| MC_Cpk_1.588 | 1.588 (3 dp) | 1.588 | yes |
| MC_P0.13 | −13.97 (2 dp) | −13.97 | yes |
| MC_P99.87 | +16.60 (2 dp) | 16.60 | yes |
| MC_exceedances_zero | 0 | 0 | yes |

Same RNG (`random.Random(20261104)`), same draw order (contributors in CSV
row order), same estimator definitions — divergence here would mean the
heredoc drifted from the court, and the table above is the drift alarm.

## Data provenance

Stack parameters re-read from `datasets/gimbal-bore-stack-parameters.csv`
(MANIFEST-registered; 4 contributors):

| contributor | mean (µm) | tol (µm) | σ_i = tol/3 | cost weight |
|---|---|---|---|---|
| bore_diameter | 0.000 | 10.0 | 3.3333 | 1.0 (cheap) |
| spindle_thermal | +2.000 | 8.0 | 2.6667 | 4.0 (expensive) |
| fixture_loc | 0.000 | 6.0 | 2.0000 | 2.0 |
| tool_deflection | −1.000 | 5.0 | 1.6667 | 1.5 |

Net mean shift = 0 + 2 + 0 − 1 = **+1.0 µm** (court check `net_mean_shift`).
Spec ±25 µm; net WC budget to spec = 25 − 1 = 24.0 µm.

## E1 — Method 1: worst case

Every contributor at its worst simultaneous limit:

- WC hi = +1.0 + (10 + 8 + 6 + 5) = **+30.0 µm** (court `WC_band_hi`)
- WC lo = +1.0 − 29.0 = **−28.0 µm** (court `WC_band_lo`)
- Verdict: band [−28, +30] vs spec ±25 → **FAIL** (court `WC_verdict_FAIL`)

Why it fails: WC band width 58 µm > usable spec width (50 − 1 mean shift).
Conservative by construction — it assumes extremes coincide, which never
happens in an additive independent model.

## E2 — Method 2: RSS

Independence + normality ⇒ variances add; each ±tol read as ±3σ:

- σ_stack = √(3.333² + 2.667² + 2.000² + 1.667²) = **5.000 µm exactly**
  (court `RSS_sigma_5.000`, 3 dp)
- 3σ band = [1 − 15, 1 + 15] = **[−14.0, +16.0]** (court `RSS_3sigma_band_*`)
- Cpk = min(25 − 1, 1 + 25) / (3 × 5.000) = 24/15 = **1.60** (court
  `RSS_Cpk_1.60`, 2 dp) → PASS vs 1.33 target (`RSS_verdict_PASS_vs_1.33`)
- Assumption risk: independence and normality — exactly what the MC tests.

## E3 — Method 3: Monte Carlo (seed 20261104)

From the heredoc table, 10k row:

- µ = 1.029, σ = 5.033 µm — the sample σ 5.033 vs RSS 5.000 is sampling
  noise, not model disagreement (reconciliation band ±0.25 µm)
- P0.13 = **−13.97**, P99.87 = **+16.60** (linear-interpolated percentiles)
- Exceedances = **0** of 10,000
- Cpk = min(25 − 1.029, 1.029 + 25)/(3 × 5.033) = 23.971/15.099 = **1.588**
  (court `MC_Cpk_1.588`) → PASS
- Convergence: at 1k the same seed gives Cpk 1.514 / P99.87 17.14; by 10k
  Cpk 1.588 / P99.87 16.60 — no verdict flip, all ≥ 1.33.

**Reconciliation** (court `reconciliation_*` checks): |Cpk_MC − Cpk_RSS| =
|1.588 − 1.600| = **0.012 ≤ 0.05**; |σ_MC − σ_RSS| = |5.033 − 5.000| =
**0.033 ≤ 0.25**. MC and RSS agree because the additive independent normal
model is exactly the model RSS assumes.

## E4 — Analytic interference probability

z_hi = (25 − 1)/5.000 = 4.80; z_lo = (−25 − 1)/5.000 = −5.20

p_fail = (1 − Φ(4.80)) + Φ(−5.20) ≈ 7.9e-07 + 1.0e-07 = **8.9e-07**

Court check `analytic_p_fail_8.9e-07` admits 8.9e-07 within 2%. MC found 0
exceedances in 10k; rule-of-three upper bound 3/10,000 = 3.0e-04 — the MC
cannot resolve 8.9e-07 at 10k runs, and it does not claim to.

## E5 — Tolerance allocation to a 24.0 µm WC budget

Budget = 25 − 1 = 24.0 µm. Both allocations hit the budget exactly
(court `*_WC_meets_budget`); re-derived from the CSV tolerances + cost
weights:

- **Proportional**: k = 24/29 = **0.8276**; t′ = k·t → (8.28, 6.62, 4.97,
  4.14); RSS σ = 5.000·k = **4.14 µm**
- **Cost-weighted (Lagrange)**: λ = (29 − 24)/Σ(t_i/c_i) = 5/18.333 =
  **0.2727**; t′ = t·(1 − λ/c) → (7.27, 7.45, 5.18, 4.09); RSS σ =
  **4.11 µm**

| method | bore | thermal | fixture | deflection | WC total | RSS σ | cost paid |
|---|---|---|---|---|---|---|---|
| current | 10.0 | 8.0 | 6.0 | 5.0 | 29.0 | 5.00 | — |
| proportional (k = 0.8276) | 8.28 | 6.62 | 4.97 | 4.14 | 24.0 | 4.14 | all tightened 17.2% |
| cost-weighted (λ = 0.2727) | 7.27 | 7.45 | 5.18 | 4.09 | 24.0 | 4.11 | bore −27%, thermal −7% |

Engineering read: same budget met, but cost-weighted barely touches the
expensive spindle-thermal loop (8.0 → 7.45, −7%; court
`cw_thermal_barely_touched`) while the cheap bore op absorbs −27% — nearly
the same RSS σ (4.11 vs 4.14). Choose on cost, not habit.

## E6 — Staleness sweep: the 4.17 µm spine sigma is refused

The adjudicated-STALE 4.17 µm sigma from the Module 12 RUNNING-CASE
adjudication must never re-enter as a stack sigma. The court refuses it two
ways (`stale_sigma_refused_data`: |5.000 − 4.17| = 0.83 > 0.5;
`stale_sigma_refused_coherence`: 0.016/(3×4.17/1000) = 1.28 ≠ 1.60 — the
stale sigma would imply Cpk 1.28, not the derived 1.60).

## Gate receipt

```
python3 modules/17-statistical-tolerance/court.py; echo RC=$?        # RC=0
python3 modules/17-statistical-tolerance/court.py --mutate; echo RC=$?  # RC=1
```

--mutate output: `MUTATION DETECTED: RSS Cpk pinned at 1.33 vs derived
1.6000 -> nonzero` — the court can fail, so its PASS carries information.
