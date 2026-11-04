# statistical-tolerance

Module 17 — Statistical Tolerance Analysis (CPPC gimbal bore stack)

## Learning objectives

By the end of this module you can:

1. Compute the **worst-case** stack band for the four-contributor bore stack and
   state why its FAIL verdict is conservative by construction.
2. Compute the **RSS** stack sigma and Cpk from the per-contributor tolerances
   (sigma_i = tol_i/3) and state the independence/normality assumptions it carries.
3. Read a **Monte Carlo** stack simulation (convergence ladder, percentile report,
   interference bound) and reconcile it against the RSS verdict.
4. Perform a **tolerance allocation** to a worst-case budget by proportional
   scaling and by cost-weighted (Lagrange) allocation, and choose between them
   on cost, not habit.
5. Defend which verdict to trust when the three methods disagree, naming the
   assumption each method carries.

## Timing (per activity)

- Stack parameter walkthrough (`datasets/gimbal-bore-stack-parameters.csv`) (10 min)
- Method 1 worst-case derivation (10 min)
- Method 2 RSS derivation (15 min)
- Method 3 Monte Carlo walkthrough + court run (15 min)
- Side-by-side comparison discussion (10 min)
- Tolerance-allocation exercise + script re-derivation (25 min)
- Court:
  `python3 modules/18-monte-carlo/scripts/mc_bore_stack.py` (5 min)

Total ~90 min.

## Why this matters

A stack-up tells you whether individually acceptable parts assemble into an
acceptable whole. Three methods answer the same question with different
assumptions, and they routinely disagree — the BB must know which verdict to
trust and why.

## The shared assembly (all exercises use ONE stack)

CTQ-1: bore diameter 12.000 ± 0.025 mm. Model the stack as the sum of four
contributors to bore-diameter deviation from nominal (all values in µm;
tolerance = symmetric ± band; see `datasets/gimbal-bore-stack-parameters.csv`):

| contributor | mean | tolerance | cost weight (tightening cost) |
|---|---|---|---|
| bore machining diameter | 0.000 | ±10.0 | 1.0 (cheap) |
| spindle thermal growth | +2.000 | ±8.0 | 4.0 (expensive) |
| fixture locating | 0.000 | ±6.0 | 2.0 |
| tool deflection | −1.000 | ±5.0 | 1.5 |

Net mean shift = +1.0 µm. All exercises and Module 18 reuse this exact stack.

## Method 1 — worst case

Assume every contributor sits at its worst simultaneous limit:
total = |1.0| + (10 + 8 + 6 + 5) = 30.0 µm band [−28.0, +30.0] vs spec ±25.

**Verdict: FAIL.** Worst case ignores that extremes rarely coincide, so it is
conservative — it will force tolerances tighter than the process needs.

## Method 2 — RSS (root sum of squares)

If contributors are independent, variances add. With each ±tolerance read as a
±3σ natural band, σ_i = tol/3:

σ_stack = sqrt(3.333² + 2.667² + 2.000² + 1.667²) = 5.000 µm exactly.

3σ band = [1.0 − 15.0, 1.0 + 15.0] = [−14.0, +16.0] vs spec ±25.
Cpk = min(25 − 1, 1 + 25) / (3 × 5.0) = 24/15 = **1.60**.

**Verdict: PASS** (target 1.33). RSS assumes independence and normality —
check both before trusting it (Module 18 tests the assumption directly).

## Method 3 — Monte Carlo

Simulate the stack 10,000 times with seed 20261104 and measure, don't assume.
Full method, convergence ladder, percentile report, and tornado in Module 18.
Headline: Cpk = 1.588 at 10k runs, zero exceedances, analytic interference
probability 8.9e-07. **Verdict: PASS** — and it validates RSS's assumption.

## Side-by-side (the exam answer)

| method | band vs ±25 µm spec | verdict | assumption risk |
|---|---|---|---|
| worst case | [−28, +30] | FAIL | none (fully conservative) |
| RSS | [−14, +16], Cpk 1.60 | PASS | independence + normality |
| Monte Carlo | P0.13 −13.97 / P99.87 +16.60, Cpk 1.588 | PASS | seed/model fidelity |

Same stack, three verdicts. Worst case fails by construction (band 29 µm >
spec width 50 µm minus mean shift); RSS and MC agree because the additive
normal model is exactly the model RSS assumes. When MC and RSS disagree, the
distribution shape (skew, correlation, shifted means) is the suspect — this
stack has none, so they concur.

## Exercise — tolerance allocation to a worst-case budget

A key customer audits worst case, so the shop must shrink the WC total from
29.0 to 24.0 µm (25 µm spec − 1 µm net mean). Two allocations, both hitting
the budget exactly (re-derive: Module 18 script, `allocation()`):

| method | bore | thermal | fixture | deflection | WC total | RSS σ | cost index paid |
|---|---|---|---|---|---|---|---|
| current | 10.0 | 8.0 | 6.0 | 5.0 | 29.0 | 5.00 | — |
| proportional (k = 0.8276) | 8.28 | 6.62 | 4.97 | 4.14 | 24.0 | 4.14 | all tightened 17.2% |
| cost-weighted (λ = 0.2727) | 7.27 | 7.45 | 5.18 | 4.09 | 24.0 | 4.11 | bore -27%, thermal -7% |

Proportional scaling multiplies every tolerance by k = 24/29. Cost-weighted
allocation equalizes marginal tightening cost (minimize Σ c_i·(t_i−t_i′)/t_i
s.t. Σ t_i′ = budget; Lagrange gives t_i′ = t_i·(1−λ/c_i)). Same budget met,
but the expensive-to-tighten spindle thermal loop is barely touched — that is
the cheaper engineering plan for nearly the same RSS σ (4.11 vs 4.14).

## Court (re-derive, never trust)

```
python3 modules/18-monte-carlo/scripts/mc_bore_stack.py   # exit 0 required
```
Every number in this module re-derives from that single exit-checked run:
WC band, RSS σ = 5.00, Cpk 1.60, allocation table. If your hand arithmetic
disagrees with the script, the script wins — then audit the script.
