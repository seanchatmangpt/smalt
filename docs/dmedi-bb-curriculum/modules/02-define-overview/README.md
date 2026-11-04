# Module 02 — Define Overview: Baselines, DPMO, and the Y You Promise to Move

DMEDI Black Belt curriculum. Running case: CascadeProjects Precision Components
(CPPC), SR-71 drone-gimbal CNC line. This module opens the Define phase: turn a
vague complaint ("the gimbal line is slow and scrappy") into a measured baseline
for each CTQ so the charter (Module 03) can promise a number.

## Data (this module owns these CSVs)

- `data/bore-inspection-dpmo.csv` — 20 inspection days: units inspected and defects
  found on the bore operation (CTQ-1 defect stream at the current baseline).
- `data/order-lead-time.csv` — 40 completed orders with received/shipped dates and
  measured lead-time days (CTQ-2 order-to-ship).

No generator is needed; both CSVs are the authored dataset for this module and
every number below re-derives from them (key: `keys/solution-key.md`).

## Learning objectives

By the end of this module you can:

1. Compute DPU, DPMO, and sigma level from a defects log, and defend the choice of
   opportunities-per-unit (measurable: correct DPMO to ±1 on the module dataset).
2. Compute and interpret a baseline median and P90 for a cycle-time Y, and state
   the % of orders breaching a target (measurable: lead-time baseline reproduced).
3. Write a Y statement in the form "baseline -> target, measured by <operational
   definition>, by <gate week>" for all three CPPC CTQs (measurable: rubric in
   Section 5).
4. Explain why a Define-phase baseline uses the VOICE OF THE PROCESS data, not
   anecdotes, and identify which pinned running-case constant each Y cites
   (measurable: exercises 5-6).

## Worked example 1 — DPMO for the bore operation (15 min instructor derivation)

Step 1 — total the log. From `bore-inspection-dpmo.csv`:
units inspected = 4,048 over 20 days; defects found = 49. Show the totals, do not
quote them.

Step 2 — DPU = defects / units = 49 / 4048 = **0.01210 defects per unit**.

Step 3 — choose opportunities per unit. DPMO is meaningless until opportunities
are pinned. For the gimbal housing the measured bore inspection carries 6 defect
opportunities (bore diameter, taper, Ra, chamfer, edge break, seating datum — the
same six surfaces the Module 27 design controls protect). DPO = 49 / (4048 x 6)
= 49 / 24,288 = 0.0020175. **DPMO = 2017.5**.

Step 4 — sigma level (short-term, 1.5-shift convention):
z = Phi^-1(1 - 0.0020175) = 2.875; sigma level = 2.875 + 1.5 = **4.38** (4.375
before rounding).
If instead you count 1 opportunity per unit (bore only), DPMO = 12,104.7 and the
sigma level drops to 3.75. Same parts, same defects — the number moved because the
OPERATIONAL DEFINITION moved. That is the Define lesson.

Step 5 — say what it is NOT: DPMO 2017.5 does not mean the process is good; it
counts detected defects at inspection, not escapes. Capability (Cpk 0.72, Module
12) is the product-side truth; DPMO is the inspection-side truth. Define-phase
baselines state both.

## Worked example 2 — the CTQ-2 lead-time Y (10 min)

From `order-lead-time.csv` (n = 40): mean 17.8 d, median 17.35 d, sd 4.35 d,
P90 24.1 d, min 9.1, max 26.3. Orders breaching the 7-day target: 40 of 40
(**100%**). Sample mean 17.8 vs pinned running-case baseline 18.4 d — consistent
sampling noise; the pinned constant is the registry value, the CSV is the sample.

Y statement this produces: "Order-to-ship lead time moves from a 17.35-day median
(100% of orders over target) to <= 7 days, measured per the Module 07 operational
definitions (lead-time OD on this exact CSV layout; OD-11 cycle time on the
machine leg), by gate week W15."
Every element (baseline, target, OD, gate) is auditable — that is what makes it a
Y statement instead of a wish.

## Timing (90-min session)

- Warm-up: what is wrong with "improve quality" as a goal (5 min)
- Worked example 1: DPMO derivation (15 min)
- Worked example 2: lead-time Y (10 min)
- Lab: re-derive both baselines from the CSVs in python3 or Minitab (30 min)
- Draft Y statements for CTQ-1/2/3 and peer-review against the rubric (25 min)
- Gate quiz: exercises 1-6 (5 min)

## Tool note

- Minitab: counts first (Calc > Calculator for totals; Stat > Basic Statistics >
  Display Descriptive Statistics for the lead-time columns). DPMO itself:
  Calc > Calculator with the arithmetic shown above, or Quality Tools > SiZ
  (if installed). Normal quantile for sigma level: Calc > Probability
  Distributions > Inverse Cumulative Normal, input probability = 1 - DPO.
- python3 mirror: the full re-derivation is in `keys/solution-key.md` (csv +
  statistics + math.erf inverse via statistics.NormalDist.inv_cdf).

## Consistency pins consumed

- RUNNING-CASE.md: CTQ-2 baseline 18.4 d, target <= 7 d; CTQ-1 spec
  12.000 +/- 0.025 mm; CTQ-3 cost ceiling $28.50 (derived in Module 06).
- Module 06 pins the cost gap ($30.00 x 0.95 = $28.50 allowable, $13.30 gap);
  this module only cites the ceiling in the CTQ-3 Y statement.
- Module 07 owns OD-1..OD-15; this module cites OD-11 (cycle time / lead time)
  as the measuring definition.

## Gate checklist

- [ ] DPU, DPMO (6-opportunity), and sigma level reproduced from the CSV
- [ ] The 1-opportunity vs 6-opportunity contrast explained (why the definition moves the number)
- [ ] Lead-time median/P90/%-over-target reproduced; % over target = 100%
- [ ] Three Y statements drafted, each with baseline -> target -> OD -> gate
- [ ] CTQ-3 Y statement cites $28.50, not $30.00, as the target
