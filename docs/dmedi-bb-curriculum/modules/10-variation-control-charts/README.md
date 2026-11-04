# Module 10 — Variation and Control Charts: Common Cause, Special Cause, and the First Chart

DMEDI Black Belt curriculum. Running case: CPPC bore diameter. Module 09 showed
subgroup means move less than individuals (sigma_xbar = sigma/sqrt n); this module
turns that into the first control charts. Module 43 owns the CONTROL PLAN on the
Module 42 pilot data; this module owns the variation concept and the baseline
chart arithmetic on the pre-pilot datasets.

Note on authorship: this README and `exercises.md` complete the module-10 kit
authored in-concert with `lab.md`, `solution-key.md`, `slides-outline.md`, and
`courts/court.py` (which re-derives every number below and exits 0 — run it:
`python3 modules/10-variation-control-charts/courts/court.py` from the
curriculum root).

## Data (registered seeds, shared root `data/`, byte-exact regeneration)

- `data/xbar-r-subgroups.csv` — seed 42011, 25 subgroups x n = 5,
  `random.gauss(12.009, 0.007407)` with a +0.015 mm planted mean shift in
  subgroups 18-20 (the special cause the charts must catch).
- `data/bore-baseline-100.csv` — seed 42008, 100 individuals, same process
  (drives the I-MR chart).
- `data/lead-defectives.csv` — seed 42012, 25 days, n in {80,100,120},
  Bernoulli p = 0.14, p = 0.30 planted on days 17-19 (drives the p-chart).

All three are registered in `datasets/MANIFEST.md`; the court regenerates each
byte-exact from its seed before deriving anything — dataset integrity is the
first gate, not an assumption.

## Learning objectives

1. Distinguish common-cause from special-cause variation, and explain why acting
   on common cause as if it were special cause (tampering) destabilizes a
   process (measurable: exercise 2).
2. Select the right chart for the data: X-bar/R vs I-MR vs p vs u vs c
   (measurable: exercise 1, four scenario picks with justification).
3. Compute X-bar/R limits from the constants (A2 = 0.577, D3 = 0, D4 = 2.114,
   d2 = 2.326 for n = 5), derive A2 from A2 = 3/(d2 x sqrt n), and identify
   rule-1 breaches (measurable: exercises 3-4, values reproduced to 4 dp).
4. Execute a Phase I iteration: remove confirmed special causes, recompute
   limits, and detect the signal the inflated limits hid (measurable:
   exercise 5 — subgroup 18 recovered).
5. Keep control limits and specification limits separate in speech and on the
   chart, and route a signal to an OCAP investigation rather than a disposition
   (measurable: exercise 6).

## Worked example — X-bar/R on the bore baseline (20 min, derivation visible)

Dataset: `data/xbar-r-subgroups.csv` (seed 42011, planted shift in 18-20).

1. Per subgroup: mean and range R = max - min (25 of each).
2. X-double-bar = mean of the 25 subgroup means = **12.0116 mm**.
3. R-bar = mean of the 25 ranges = **0.0191 mm**.
4. Constants for n = 5: A2 = 0.577, D3 = 0, D4 = 2.114, d2 = 2.326.
   Derivation of A2 (do not just quote it): A2 = 3/(d2 x sqrt n)
   = 3/(2.326 x 2.2361) = **0.577**.
5. Limits:
   - UCL(X-bar) = 12.0116 + 0.577 x 0.0191 = 12.0116 + 0.0110 = **12.0226 mm**
   - LCL(X-bar) = 12.0116 - 0.0110 = **12.0006 mm**
   - UCL(R) = 2.114 x 0.0191 = **0.0404 mm**; LCL(R) = 0.
6. sigma-hat = R-bar/d2 = 0.0191/2.326 = 0.008212 mm = **8.21 um**; and
   sigma_xbar = 8.21/sqrt(5) = **3.672 um** — the Module 09 CLT number made
   operational: this is WHY the X-bar limits are tighter than I-chart limits.
7. Read the chart: rule 1 breaches at subgroups **19 (12.0278)** and
   **20 (12.0267)** — the planted shift surfacing. Subgroup 18 (12.0220) is
   inside the inflated UCL but joins via Test 5 (2-of-3 beyond 2 sigma).
8. Phase I: remove the confirmed special causes (subgroups 18-20) from limit
   estimation, recompute: Xbb 12.0097, Rbar 0.0192, UCL 12.0208, LCL 11.9986,
   R UCL 0.0406. Subgroup 18 (12.0220) now BREACHES — the all-data limits
   carried a bias toward silence: the variation the chart must detect was
   widening the limits used to detect it. Trial limits are recomputed;
   Phase II freezes them for future production.

Same drill for the two sibling charts (full arithmetic in `solution-key.md`,
court-verified): the I-MR chart on `bore-baseline-100.csv` (mean 12.0098,
MRbar 0.0077, limits 11.9893/12.0303, observation 41 below LCL but INSIDE spec —
control limits and spec limits answer different questions) and the p-chart on
`lead-defectives.csv` (pbar = 388/2560 = 0.1516, per-day limits because n
varies; rule 1 at days 17, 18; day 19 frac 0.240 vs its own UCL 0.259 — inside).

## In control, on target, capable — three different verdicts

Phase I Xbb 12.0097 vs nominal 12.000: the shifted-out process is stable AND
9.7 um high — in control is not on target. sigma-hat ~8.2 um against the spread
the 1.33 Cpk target permits at the customer spec half-width (0.025/(3 x 1.33) =
6.27 um): the spread exceeds the allowance, so this process is incapable even if
centered — capable is a separate question again (Module 12 owns it; Module 43
builds the plan that sustains it).

## Timing (90-min session)

- Variation concept and tampering demo (15 min)
- Worked example: X-bar/R derivation + Phase I (20 min)
- Chart-selection gallery + I-MR and p-chart derivations (20 min)
- Lab (see `lab.md`): build all three charts in Minitab/python3 (20 min)
- Read-out: in-control vs on-target vs capable; run rules (10 min)
- Gate quiz: exercises 1-8 (5 min)

## Tool note

- Minitab: Stat > Control Charts > Variables Charts for Subgroups > Xbar-R
  (subgroup size 5; Options > Estimate = R-bar default; Options > Tests =
  T1/T2/T3/T5/T6). I-MR: Stat > Control Charts > Variables Charts for
  Individuals > I-MR. p-chart: Stat > Control Charts > Attribute Charts > P
  with `orders_inspected` as subgroup size (variable-n limits are automatic).
  Phase I re-estimation: Options > Estimate > use subgroups 1-17, 21-25.
- python3 mirror: the verbatim derivation script and its verified output are in
  `solution-key.md`; the automated gate is `courts/court.py` (exit 0), which
  also regenerates all three datasets from seeds to prove the inputs.

## Consistency pins consumed

- RUNNING-CASE.md: spec 12.000 +/- 0.025 mm; mu 12.009 mm; sigma 7.407 um
  (adjudicated 2026-11-04); Cpk 0.72 baseline regime; lead-time CTQ-2 context.
- Module 43 (`lab.md`, `keys/solution-key.md`): owns the control plan, pilot
  charts (seed 42016), A2/D3/D4 constants (same values), and the OCAP format.
  No duplication: module 10 reads and builds charts on baseline data; module 43
  governs the improved process with a plan.
- Module 09: sigma_xbar = sigma/sqrt(n) — realized here as sigma_xbar 3.672 um.
- datasets/MANIFEST.md: seeds 42008/42011/42012 registered to this module.

## Gate checklist

- [ ] `python3 modules/10-variation-control-charts/courts/court.py` exits 0
- [ ] All four X-bar/R limits and sigma-hat reproduced to 4 dp
- [ ] A2 derived from A2 = 3/(d2 sqrt n), not quoted
- [ ] Subgroups 18-20 classified special cause; Phase I limits recomputed; subgroup 18 recovered
- [ ] I-chart obs 41 case stated: below LCL, inside spec, two different questions
- [ ] p-chart days 17-18 flagged with per-day limits; day 19 dispositioned
- [ ] One sentence: what Module 43 adds to the charts you just built
