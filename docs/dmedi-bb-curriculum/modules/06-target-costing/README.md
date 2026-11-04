# Module 06 — Target Costing (CTQ-3)

Six Sigma DMEDI Black Belt curriculum — CascadeProjects Precision Components
(CPPC) running case. Pinned spine: `../../RUNNING-CASE.md`.

## Learning objectives

After this module the BB candidate can:

1. Derive an allowable cost from market willingness-to-pay and a required return
   on sales (price-point derivation), and defend it against cost-plus thinking.
2. Build a bottom-up should-cost teardown from physical parameters (billet mass,
   cycle time, edge life, loaded rates, yield math) — every line derived, none
   quoted.
3. Rank cost drivers by exposure and decompose the allowable-vs-driven gap into
   quantified driver targets (DOE feed gains, Cpk yield math, SMED, near-net
   billet, in-cycle gauging).
4. Prove the decomposition additive: line-level savings must sum to the total
   gap closure, with the residual disclosed as design margin.

## The running-case numbers

CTQ-3: unit cost baseline $41.80 (driven cost), target-costing ceiling $28.50
(allowable cost). Gap $13.30. This module derives both ends of that gap from
first principles and closes it with $14.71 of driver-target savings, landing the
projected unit cost at $27.09 — $1.41 (5.2%) below the ceiling.

## Bundle contents

| File | Content |
|---|---|
| `worksheets/01-should-cost-teardown.md` | Baseline parameters, seven cost lines, yield math (2*Phi(-3*Cpk)) |
| `worksheets/02-cost-driver-table.md` | Seven drivers ranked by exposure with levers |
| `worksheets/03-gap-worksheet.md` | Allowable-vs-driven gap decomposed; closure table |
| `worksheets/04-price-point.md` | WTP conjoint blend, price selection, sensitivity |
| `courts/court.py` | Re-derives every line and rollup; exit 0 required |

## Court (exit-checked)

```
python3 courts/court.py
```

The court re-derives the baseline teardown from raw parameters and asserts:

- rounded rollup == $41.80 (pinned)
- gap == $13.30; allowable == $30.00 * 0.95 == $28.50 (pinned)
- WTP blend == $30.35; future state == $27.09 <= ceiling
- savings decomposition additive (line diffs sum to 41.80 - 27.09)
- yield math matches the pinned Cpk constants (0.72 -> 3.0773%,
  1.33 -> 0.006607%)

## Cross-lane couplings

- Lane 11 (DOE): the feed 630 mm/min / spindle 11,500 RPM optimum and the
  resulting 13.08-min cycle are this module's assumption; Lane 11 confirms or
  supersedes and the teardown re-derives.
- Lane 05 (Measure): Cpk 0.72 / 1.33 consumed via the pinned constants only.
- Lane 19 (coherence court): sees `03-gap-worksheet.md` as the CTQ-3 authority.

## Timing estimate

4.0 h total: walkthrough of the teardown derivation (45 min), cost-driver ranking
exercise (30 min), gap worksheet build (40 min), price-point derivation (30 min),
solution-key reconciliation vs your own worksheet (25 min), court run and debrief
(30 min).

## Tool note

python3 mirror: every number in `solution-key.md` re-derives via
`python3 courts/court.py` (stdlib `math.erf`/`sqrt` only; 19/19 checks, exit 0
required). Minitab path: this module needs no statistical engine — the only
distribution math is 2 x Phi(-3 x Cpk), which Minitab computes as
Calc > Probability Distributions > Normal with cumulative, x = -3 x Cpk,
mean 0, SD 1 (enter 2 x the result for the two-sided rate).
