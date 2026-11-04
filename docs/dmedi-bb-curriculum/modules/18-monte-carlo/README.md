# monte-carlo

Module 18 — Monte Carlo Simulation (CPPC gimbal bore stack)

## Learning objectives

By the end of this module you can:

1. Build and run a seeded Monte Carlo simulation of the Module 17 bore stack
   (stdlib `random.Random`, 10k draws) and report percentiles, mu/sigma, and
   exceedance counts.
2. Interpret a **convergence ladder** (1k/5k/10k) and apply the decision rule
   that a verdict flip between ladder steps forbids reporting.
3. Compute an **interference probability** honestly: rule-of-three upper bound
   when zero exceedances occur, analytic normal-sum p_fail, and why a 10k
   simulation cannot resolve a 1-in-a-million tail.
4. Produce a **sensitivity tornado** (variance share + output correlation) and
   read it as a tolerance-tightening priority list.
5. Reconcile worst-case, RSS, and Monte Carlo verdicts on the same stack and
   state the assumption each method carries.
6. Run the exit-checked court (`scripts/mc_bore_stack.py`, rc=0) and verify the
   allocation table Module 17 cites.

## Timing (per activity)

- Spec + implementation walkthrough, incl. spreadsheet/Minitab equivalent (15 min)
- Convergence-ladder run + reading (15 min)
- Percentile report vs spec limits (10 min)
- Interference probability + rule-of-three honesty lesson (10 min)
- Tornado derivation and reading (15 min)
- Verdict reconciliation vs Module 17 + court run `scripts/mc_bore_stack.py` (15 min)

Total ~80 min.

## Spec

Simulate the Module 17 stack (same 4 contributors, same spec ±25 µm,
Cpk target 1.33):

- **Runs**: 10,000 (ladder of 1,000 / 5,000 / 10,000 for convergence)
- **Seed**: 20261104, python3 stdlib `random.Random(seed)`, `gauss(mean, sigma)`
- **Model**: each contributor normal with σ = tolerance/3 (±tol read as a ±3σ
  natural band); stack = sum of the four
- **Outputs**: P0.13 / P50 / P99.87 vs spec limits, exceedance count,
  Cpk, sensitivity tornado

## Implementation

Canonical implementation (stdlib only, exit-checked):

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py   # must exit 0
```

### Spreadsheet equivalent

Column A:D = four contributor draws: `=NORM.INV(RAND(), mean, tol/3)`
(NORM.INV over RAND() is not seed-reproducible across engines — use it for
teaching, the python3 script for the graded keys). Column E = `=SUM(A2:D2)`.
Percentiles: `=PERCENTILE.INC($E$2:$E$10001, 0.0013 / 0.5 / 0.9987)`;
Cpk: `=MIN(25-AVERAGE(E:E), AVERAGE(E:E)+25)/(3*STDEV.S(E:E))`. Set the
workbook to iterative-recalc off and one random-trigger cell, or values will
drift on every edit. Minitab equivalent: Stat > Quality Tools > Tolerance
Interval, or the Monte Carlo simulations in Minitab Statistical Engine
(define inputs with distribution Normal, mean, σ = tol/3; output formula
y = x1+x2+x3+x4; 10,000 draws; report percentile tables).

## Convergence — ladder before you trust

Actual ladder output (seed 20261104, full table in
`datasets/monte-carlo-bore-stack-summary.csv`):

| runs | P0.13 | P50 | P99.87 | mu | sigma | Cpk |
|---|---|---|---|---|---|---|
| 1,000 | −12.47 | 1.39 | 17.14 | 1.377 | 5.202 | 1.514 |
| 5,000 | −14.04 | 1.08 | 16.77 | 1.039 | 5.053 | 1.581 |
| 10,000 | −13.97 | 1.06 | 16.60 | 1.029 | 5.033 | 1.588 |

P99.87 moves 17.14 → 16.77 → 16.60 µm: still settling at 10k because tail
percentiles are estimate-hungry (P99.87 uses ~13 points per 10k draws).
Decision rule used here: if the verdict (Cpk ≥ 1.33) flips between ladder
steps, do NOT report — raise runs. Here Cpk moves 1.514 → 1.581 → 1.588,
converging well above target, so the verdict is stable at 10k.

## Percentile report (10k runs) vs spec limits

- P0.13 = −13.97 µm vs LSL −25 µm → 11.0 µm margin
- P50 = +1.06 µm (the +1 µm net mean shift, as expected)
- P99.87 = +16.60 µm vs USL +25 µm → 8.4 µm margin
- mu = 1.029 µm, sigma = 5.033 µm (analytic: 1.000 / 5.000)
- Cpk = 1.588 vs target 1.33 → **PASS**

## Interference probability — and an honesty lesson

MC 10k: **zero** exceedances. That does NOT mean p = 0 — with n = 10k the
rule-of-three 95% upper bound is 3/10,000 = 3.0e-04. The analytic normal-sum
probability is 8.93e-07 (z_hi = 4.80, z_lo = −5.20). A 10k-run simulation
cannot resolve a 1-in-a-million event; report the bound, not a fake zero.
If you need the tail estimate itself, run 10^7 draws or use the analytic z.

## Sensitivity tornado (10k runs)

Variance share is exact for this additive model (σ_i²/Σσ²) and the Pearson
correlation of each contributor against the output confirms the ranking:

| rank | contributor | corr to output | variance share |
|---|---|---|---|
| 1 | bore_diameter | 0.670 | 44.8% |
| 2 | spindle_thermal | 0.534 | 28.9% |
| 3 | fixture_loc | 0.387 | 15.7% |
| 4 | tool_deflection | 0.331 | 11.3% |

Read: bore machining carries ~45% of output variance — it is the first
lever (and it is the cheapest to tighten, cost weight 1.0, which is why the
Module 17 cost-weighted allocation cuts it hardest). Thermal growth is the
second lever but the most expensive (weight 4.0); attack it with a warm-up
cycle, not a tolerance call-out.

## Verdicts, cross-checked against Module 17

| method | verdict | Cpk |
|---|---|---|
| worst case | FAIL | — |
| RSS | PASS | 1.60 |
| Monte Carlo | PASS | 1.588 (10k) |

Consistency court: MC's 10k percentiles (−13.97 / +16.60) straddle the RSS
3σ band (−14.0 / +16.0) with the small sampling spread the ladder shows;
MC Cpk 1.588 ≈ RSS 1.60 (sampling noise explains the 0.012 gap). The three
verdicts are consistent: WC fails by its own conservative construction; the
two statistical methods agree because the simulated model IS the additive
independent-normal model RSS assumes. Target verdict vs Cpk 1.33: the
design PASSES as toleranced — no allocation is required unless a customer
mandates worst-case acceptance (then use the Module 17 allocation table).

## Court (re-derive, never trust)

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py; echo RC=$?   # RC=0
```

Cross-checks enforced: (1) every percentile and tornado row above re-derives
from the exit-checked run; (2) MC Cpk, RSS Cpk, and WC band are computed on
the SAME stack parameters in one script so the comparison cannot drift;
(3) MC sigma 5.033 vs analytic 5.000 within 0.7% — if they diverge beyond
sampling noise, the model and the RSS assumption disagree and the stack must
be re-examined before any verdict ships.
