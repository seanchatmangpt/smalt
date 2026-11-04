# Module 18 Solution Key — Monte Carlo bore stack, seed 20261105 (all numbers re-derived)

Command incantation (run from the curriculum root; the script now takes an
optional seed argument defaulting to the registered teaching seed 20261104):

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py 20261105; echo RC=$?   # RC=0
```

Full captured output of that run (this is the 20261105 seed — NOT the README's
20261104 tables; every number below re-derives from this output, zero copied):

```
SEED=20261105
MODEL: D = b + t + f + d (um from 12.000 mm); normal, sigma=tol/3
SPEC: -25 .. +25 um; CPK_TARGET=1.33

== convergence (independent seeds per run-count ladder) ==
runs,p0.13,p50,p99.87,mu,sigma,exceedances,cpk
1000,-13.274,1.209,18.582,1.352,5.073,0,1.554
5000,-13.843,1.027,16.671,1.073,5.001,0,1.595
10000,-13.961,0.990,16.055,1.014,5.004,0,1.598

== 10k percentile report vs spec ==
P0.13=-13.96 um (LSL -25)  P50=0.99  P99.87=16.06 um (USL +25)
mu=1.014 um sigma=5.004 um Cpk=1.598 target=1.33 -> PASS

== interference probability ==
MC 10k exceedances=0 -> p_hat=0.0000 (95% upper bound 0.0003, rule-of-3)
analytic p_fail=8.930e-07 (z_hi=4.80 z_lo=-5.20)

== method comparison (same stack) ==
worst-case: band [-28.0, 30.0] um vs spec [-25, +25] -> FAIL
RSS: sigma=5.00 um, 3-sigma band [-14.0, 16.0] -> PASS ; Cpk=1.60
Monte Carlo: Cpk=1.600, p_fail_analytic=8.93e-07 -> PASS

== tornado (variance share + corr to output, 10k runs) ==
contributor,corr,var_share_pct
bore_diameter,0.6652,45.28
spindle_thermal,0.5333,27.99
fixture_loc,0.3977,16.12
tool_deflection,0.3294,11.28

== tolerance allocation to WC-acceptance budget 24.0 um ==
scale k=0.8276  lagrange lambda=0.2727
method,bore_diameter,spindle_thermal,fixture_loc,tool_deflection,RSS_um,WC_um
current,10.0,8.0,6.0,5.0,5.00,29.0
proportional,8.28,6.62,4.97,4.14,4.14,24.0
cost-weighted,7.27,7.45,5.18,4.09,4.11,24.0
```

## E1 — Convergence ladder (seed 20261105)

| runs | P0.13 | P50 | P99.87 | mu | sigma | Cpk |
|---|---|---|---|---|---|---|
| 1,000 | −13.27 | 1.21 | 18.58 | 1.352 | 5.073 | 1.554 |
| 5,000 | −13.84 | 1.03 | 16.67 | 1.073 | 5.001 | 1.595 |
| 10,000 | −13.96 | 0.99 | 16.06 | 1.014 | 5.004 | 1.598 |

P99.87 ladder: 18.58 → 16.67 → 16.06 µm — still settling at 10k (P99.87 uses
~13 points per 10k draws; tail percentiles are estimate-hungry). Verdict check:
Cpk 1.554 → 1.595 → 1.598, no flip between any two ladder steps, all ≥ 1.33 →
the 10k verdict MAY be reported.

## E2 — Percentile report vs spec (10k)

- P0.13 = −13.96 µm vs LSL −25 µm → margin 25 − 13.96 = **11.04 µm**
- P50 = +0.99 µm (net mean shift +2 −1 = +1 µm, sampling noise 0.01)
- P99.87 = +16.06 µm vs USL +25 µm → margin 25 − 16.06 = **8.94 µm**
- Cpk by hand: min(25 − 1.014, 1.014 + 25) / (3 × 5.004) = 23.986 / 15.012
  = **1.598** — matches the script exactly.
- Asymmetry note: the lower margin (11.04) exceeds the upper (8.94) because
  the mean sits at +1 µm; Cpk correctly takes the MIN side (the USL side).

## E3 — Interference honesty

- MC 10k: 0 exceedances → p̂ = 0/10,000 = 0. Rule-of-three 95% upper bound:
  3/n = 3/10,000 = **3.0e-04**.
- Analytic normal-sum: z_hi = (25 − 1)/5.00 = 4.80, z_lo = (−25 − 1)/5.00
  = −5.20; p_fail = (1 − Φ(4.80)) + Φ(−5.20) = 7.9e-07 + 1.0e-07 ≈
  **8.93e-07**.
- Two-sentence answer: "p = 0" claims certainty the experiment does not own —
  with n = 10,000 draws, the honest statement is only that p is small enough
  that zero exceedances were likely (p ≲ 3e-04 at 95% confidence). The true
  tail sits near 9e-07, three orders of magnitude below what 10k draws can
  resolve (expected exceedances = 10,000 × 8.93e-07 ≈ 0.009); resolving it
  needs ~10^7 draws or the analytic z.

## E4 — Tornado re-derivation (exact shares from tolerances)

σi = tol/3: bore 10/3, thermal 8/3, fixture 6/3, deflection 5/3 µm.
σi² = 100/9, 64/9, 36/9, 25/9; Σσ² = 225/9 = 25.0 µm². Exact shares:

| rank | contributor | σi² | exact share | MC share (seed 20261105, 10k) |
|---|---|---|---|---|
| 1 | bore_diameter | 11.111 | 44.44% | 45.28% |
| 2 | spindle_thermal | 7.111 | 28.44% | 27.99% |
| 3 | fixture_loc | 4.000 | 16.00% | 16.12% |
| 4 | tool_deflection | 2.778 | 11.11% | 11.28% |

MC shares differ from exact by sampling error of the sample variance (~±0.5
absolute here); the exact ordering 11.111 > 7.111 > 4.000 > 2.778 cannot be
flipped by sampling noise of that size, so the ranking is stable. Bore
machining remains the first lever (~45% of variance, cost weight 1.0).

## E5 — WC / RSS / MC reconciliation

- **Worst case**: band = mu ± Σt = +1 ± (10+8+6+5) = [+1 − 29, +1 + 29] =
  **[−28.0, +30.0] µm** vs spec [−25, +25] → FAIL. Assumption: every
  contributor simultaneously at its 3σ extreme — conservative by
  construction, independent of distribution.
- **RSS**: σ = sqrt(Σσi²) = sqrt(25.0) = 5.00 µm; band mu ± 3σ =
  [−14.0, +16.0]; Cpk = 24/15 = 1.60 → PASS. Assumption: independent,
  additive, normal.
- **Monte Carlo**: Cpk 1.598 (seed 20261105, 10k) → PASS. Same assumption as
  RSS (the simulated model IS the additive independent-normal model) plus
  sampling noise — so MC Cpk must land near 1.60; the observed gap is
  1.598 vs 1.60 = 0.002, well inside sampling noise (compare 1.588 at seed
  20261104). MC sigma 5.004 vs analytic 5.000: 0.08% divergence, far below
  the 0.7% drift-fence.
- Reconciliation: WC fails by its own conservatism; the two statistical
  methods agree because they model the same physics. Verdict vs Cpk 1.33:
  the design PASSES as toleranced; allocation is only needed if a customer
  mandates worst-case acceptance (then the Module 17 table applies).

## E6 — Allocation at 24.0 µm budget

Budget = 25 − mu = 25 − 1 = 24.0 µm. Σt = 29 µm.

**(a) Proportional**: k = 24/29 = 0.8276 → t_i' = k·t_i:
10→8.28, 8→6.62, 6→4.97, 5→4.14. Sum = 24.0 ✓. RSS = (1/3)sqrt(8.28² +
6.62² + 4.97² + 4.14²) = (1/3)sqrt(68.56+43.82+24.70+17.14) = (1/3)sqrt(154.22)
= 4.14 µm.

**(b) Cost-weighted**: λ = (29 − 24) / Σ(t_i/c_i) = 5 / (10/1 + 8/4 + 6/2 +
5/1.5) = 5 / 18.333 = 0.2727. Then t_i' = t_i(1 − λ/c_i):
- bore (c=1.0): 10(1 − 0.2727) = **7.27**
- thermal (c=4.0): 8(1 − 0.2727/4) = 8 × 0.9318 = **7.45**
- fixture (c=2.0): 6(1 − 0.2727/2) = 6 × 0.8636 = **5.18**
- deflection (c=1.5): 5(1 − 0.2727/1.5) = 5 × 0.8182 = **4.09**

Sum = 7.27+7.45+5.18+4.09 = 23.99 ≈ 24.0 ✓ (exact in the script's full
precision; rounded cells sum to 23.99). RSS = 4.11 µm.

Why thermal is tightened least: the Lagrange condition equalizes marginal
cost, so the cut each tolerance absorbs is λ/c_i — thermal's cost weight 4.0
gives it the smallest cut (8→7.45, −6.8%) while bore (c=1.0) absorbs the
largest (10→7.27, −27%). This is why the cheap lever (bore machining) is cut
hardest and thermal is attacked with a warm-up cycle, not a call-out.

## E7 — Verdict-flip honesty drill

If 1k gave Cpk 1.31 and 5k gave 1.36, the verdict FLIPPED between ladder
steps → per the README decision rule the 10k PASS may NOT be reported. The
lawful response is to raise runs (e.g. 50k, 100k) until the ladder is
verdict-stable, then report the stable run with its full ladder. The rule
protects against seeded-lottery cherry-picking: with a finite seed, some
seeds' small-n steps clear target by luck; reporting only those manufactures
a pass the process does not own.

## E8 — Dataset-law drill

The data-provenance law (RUNNING-CASE.md) makes every dataset synthetic and
generated from a STATED seed, with keys re-derived from the generator —
never from a remembered answer. Stating the seed (20261105 here, 20261104 in
the registered README/CSV) in exercises, key, and `datasets/MANIFEST.md`
makes every number replayable by a third party with one command; the solution
key above is the receipt. If the seed changed silently after keys shipped,
every pasted table would stop re-deriving, the manifest checksum/seed
registry would lie, and the course would be teaching numbers nobody can
reproduce — exactly the drift the provenance law exists to prevent.
