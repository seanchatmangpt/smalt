# Module 10 — Variation and Control Charts (Slides Outline)

**Module**: 10-variation-control-charts · Case: CPPC bore (CTQ-1) + lateness (CTQ-2)
**Timing**: 3.0 h (slides 60 min, lab 60 min, exercises 30 min, court 30 min)
**Tools**: Minitab (Control Charts menu) + python3 mirror (stdlib only)

---

## Slide 1 — Two causes of variation (10 min)

- Common cause: the process's natural noise (sigma). Special cause: something
  specific, assignable, and worth reacting to. Control charts separate them.
- Shewhart's 3-sigma limits: cheap to compute from ranges, robust, and the
  module-10 constants (A2, D3, D4, E2, d2) are the bridge from sigma to limits.
- Course spine: baseline sigma 7.407 um (adjudicated 2026-11-04). The bore datasets
  are generated at exactly that sigma.

## Slide 2 — Chart selection: the decision tree (15 min)

Present the tree from README §1 as the flagship artifact: continuous vs attribute,
subgroup structure, defect vs defective, constant vs varying size. Walk each CPPC
dataset through the tree to its chart:

| dataset | data type | structure | chart |
|---|---|---|---|
| xbar-r-subgroups.csv | continuous | 25 subgroups × n=5 | X-bar/R |
| bore-baseline-100.csv | continuous | 100 sequential singles | I-MR |
| lead-defectives.csv | attribute (defectives) | 25 days, n varies | p-chart |

- Rational subgroup law: short window inside, drift between. Mixing shifts inside
  a subgroup hides the X-bar signal (the #1 construction error).

## Slide 3 — X-bar/R worked (20 min)

- Constants n=5: A2 = 0.577, D3 = 0, D4 = 2.114, d2 = 2.326.
- From the data: Xbb 12.0116, R-bar 0.0191 → X-bar limits 12.0226/12.0006,
  R UCL 0.0404, sigma-hat = 8.21 um.
- Signals: subgroups 19/20 breach Test 1; 18 fires Test 5 (2-of-3 beyond 2σ).
- Phase I discipline: exclude 18–20, recompute → Xbb 12.0097 (= spine mu 12.009),
  limits 12.0208/11.9986; all three subgroups now signal. Lesson: limits inflated by
  the cause they should catch are biased toward silence.

## Slide 4 — I-MR worked (15 min)

- Constants: E2 = 2.66, D4(MR, lag 2) = 3.267, d2 = 1.128.
- From the data: mean 12.0098, MR-bar 0.0077 → I limits 12.0303/11.9893,
  MR UCL 0.02517, sigma_I 6.83 um.
- Signals: obs 41 below I LCL (Test 1); MR spikes at lags 10, 11, 23, 41; Test 6
  cluster ending at 12. Compare chart widths: I limits ±0.0205 vs X-bar limits ±0.0110 (A2·R-bar)
  — the CLT made visible (module 09).

## Slide 5 — p-chart worked (10 min)

- p-bar = 388/2560 = 0.1516; limits vary with n (UCL 0.250–0.272 across days).
- Days 17 (0.258) and 18 (0.317) breach; day 19 (0.240) elevated but inside —
  special causes do not always fire rule 1; the physical timeline closes the case.

## Slide 6 — Run rules and the interpretation gallery (15 min)

- Rules taught: T1 (beyond 3σ), T2 (9 same side), T3 (6 trending), T5 (2-of-3 > 2σ),
  T6 (4-of-5 > 1σ). Each fired rule names a CLASS of cause + reaction, never a diagnosis.
- Gallery table (README §5): each CPPC signal → rule class → physical cause → action.
- Link forward: Module 43 turns the gallery into OCAP rows in the control plan.

## Lab and assessment

- Lab: `lab.md` (three charts, Minitab path + python3 replication).
- Exercises 1–8: `exercises.md` (answers in solution-key.md).
- Court: `courts/court.py` (exit 0 = every limit, signal, and fraction re-derives).
