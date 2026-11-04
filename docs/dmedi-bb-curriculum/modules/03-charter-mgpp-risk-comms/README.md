# Module 03 — Charter, MGPP, Risk, and Comms: The Paper That Owns the Project

DMEDI Black Belt curriculum. Running case: CPPC SR-71 gimbal CNC line. Module 02
produced measured baselines; this module locks them into a charter, a metrics
plan (MGPP), a risk register, and a communication plan.

## Data (this module owns these CSVs)

Secondary/transactional examples used to practice quantified problem statements
and data-integrity review BEFORE signing a charter:

- `data/ed-door-to-provider-minutes.csv` — 80 ED visits, door-to-provider minutes
  (healthcare charter example).
- `data/insurance-claims-cycle-time.csv` — 60 claims with `cycle_time_days` filled
  and `closed_date` blank on every row (deliberate data-integrity teaching case).

Every number re-derives in `keys/solution-key.md`.

## Learning objectives

1. Draft a charter whose problem and goal statements carry measured baselines
   (measurable: goal statement reproduced with baseline -> target -> OD -> gate).
2. Trace each goal to the MGPP: CTQ -> Y -> x tree with operational definitions
   from Module 07's OD-1..OD-15 (measurable: exercise 4 mapping complete).
3. Detect a data-integrity defect (timestamp column present-but-unfilled) and
   state its charter risk before the gate (measurable: exercise 3).
4. Build a risk register with likelihood x impact scoring and a named owner per
   risk (measurable: exercise 5 register has 3+ risks with owners).
5. Price a scope-cut decision with the pinned cost constants (measurable: the
   $28.50 / $13.30 arithmetic shown).

## Pinned constants consumed (cite, never re-derive here)

- **Cost**: price $30.00 x (1 - 5% ROS) = $28.50 allowable unit cost; baseline
  $41.80; **gap $13.30** (derived and decomposed in Module 06; pinned here).
- **Capability**: baseline Cpk = 0.72 on bore diameter (mu = 12.009 mm,
  sigma = 7.407 um, adjudicated 2026-11-04); Define-gate target Cpk >= 1.33
  sustained 30 days (RUNNING-CASE.md).
- **Traceability**: OD-1..OD-15 operational definitions live in Module 07
  `worksheets/02-operational-definitions.md`; the CTQ->Y->x tree and gate weeks
  W5/9/15/21/26 live in Module 07 `worksheets/05-mgpp-traceability.md`.

## Worked example 1 — the CPPC charter, quantified (20 min, derivation visible)

**Problem statement — every claim is a number from a prior module:**

1. Quality Y: bore diameter runs at Cpk 0.72 against a 1.33 target (RUNNING-CASE
   pin). In sigma terms the mean sits 2.16 sigma from USL
   ((12.025 - 12.009) / 0.007407 = 2.16) and 4.60 sigma from LSL — the upper side
   binds. This is a centering AND spread problem; Module 09's tail arithmetic
   makes the escape rate visible.
2. Delivery Y: order-to-ship median 17.35 d (Module 02 re-derivation; registry
   18.4 d) against a <= 7-day target; 40/40 sampled orders over target.
3. Cost Y: unit cost $41.80 against the $28.50 ceiling — the gap is
   $41.80 - $28.50 = **$13.30 per unit**, which Module 06 decomposes across
   material, tooling, and changeover lines.

**Goal statement (quality leg, model for the rest):**
"Raise bore-diameter Cpk from 0.72 to >= 1.33 sustained 30 days, measured per
OD-1/OD-2 (CMM, 5 parts/shift, trailing 30-day window, n >= 250), at gate W21."

Why this sentence is lawful: baseline (0.72) and target (1.33) are pinned
constants; the OD names gauge, sample, frequency, and computation; the gate week
comes from the MGPP. Remove any element and the charter becomes unauditable.

**Business case**: the $13.30/unit gap on the program's planned volume funds the
26-week program; quality escapes fund the rest (scrap at 12.0293-class bores,
Module 09). Scope: OP30 finish bore + the order-to-ship flow; out of scope:
billet supply chain (OD-15 is a leading measure, not a project Y).

## Worked example 2 — data integrity before you sign (10 min)

`insurance-claims-cycle-time.csv`: all 60 rows carry `cycle_time_days`
(mean 16.07, median 15.8, sd 4.88, max 26.6) while `closed_date` is blank on
every row. The metric exists; its evidentiary chain does not. Charter risk: you
cannot audit any cycle-time claim in this file against its timestamps, so the
baseline is UNVERIFIED until the field pipeline is fixed. Lawful charter action:
add a data-quality action row to the MGPP ("OD for claims cycle time re-pinned
from ERP timestamps, owner: claims IT, gate W5") instead of quoting a number you
cannot replay. The ED dataset (n = 80, median 52.0 min, 75/80 = 93.8% over the
30-minute target) shows the contrast: timestamps present, baseline auditable.

## Timing (90-min session)

- The four charter artifacts and what makes each auditable (10 min)
- Worked example 1: CPPC charter derivation (20 min)
- Worked example 2: data-integrity review (10 min)
- Lab: draft risk register + comms matrix from the case (30 min)
- Exercise set 1-6 with gate discussion (15 min)
- Gate quiz (5 min)

## Tool note

- Minitab: Stat > Basic Statistics > Display Descriptive Statistics for both
  CSVs; use the median/P90 columns for problem statements. Datability check
  (missing-column counts): Data > Count Missing, or a histogram of
  `door_to_provider_min` by `arrival_hour` (Graph > Boxplot > With Groups) to
  show the hour effect before it becomes a scoped x.
- python3 mirror: full re-derivation in `keys/solution-key.md` (csv +
  statistics + percentage counts).

## Gate checklist

- [ ] Problem statement cites Cpk 0.72, 17.35 d median, and the $13.30 gap — each sourced
- [ ] Goal statements carry baseline -> target -> OD -> gate, all four elements
- [ ] Cpk target is 1.33 sustained 30 days (not "better quality")
- [ ] The claims data-integrity defect is named with a lawful charter response
- [ ] Risk register: 3+ risks, likelihood x impact scored, one named owner each
- [ ] Comms plan names audience, artifact, cadence, owner per stakeholder
