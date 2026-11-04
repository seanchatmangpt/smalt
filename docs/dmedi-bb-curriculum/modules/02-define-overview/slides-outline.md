# Module 02 — Define Overview (Slides Outline)

**Module**: 02-define-overview
**Timing estimate**: 90-min session (README carries the minute-by-minute plan).
**Required tools**: python3 stdlib (`csv`, `statistics`, `math`), spreadsheet.

**Learning objectives** (measurable forms in README):
1. Turn a complaint into a measured baseline: DPU/DPMO/sigma level from a defect log.
2. Read a cycle-time Y: median, P90, % over target — and pick which goes in the Y statement.
3. Write auditable Y statements (baseline -> target -> OD -> gate) for CTQ-1/2/3.
4. Decide DMEDI vs DMAIC per project brief, and map the Define-phase deliverables.

---

## Slide 1 — Define's job (10 min)
- Define does not solve anything; it makes the problem AUDITABLE.
- Output contract: measured baseline per CTQ, a charter (Module 03), the MGPP
  trace (Module 07), a risk register, a comms plan.
- Rule of the module: every baseline number must re-derive from a CSV.

## Slide 2 — DMEDI vs DMAIC: the decision table (15 min)
| Question | Yes -> | No -> |
|---|---|---|
| Does a stable existing process exist, with data? | DMAIC | DMEDI |
| Is the CTQ carried by a NEW design/equipment? | DMEDI | DMAIC |
| Is the work repairing a regression in something that works? | DMAIC | DMEDI |
- CPPC splits both ways: the CNC LINE is new (DMEDI); the order-fulfillment flow
  exists (DMAIC-style lens inside its Define).
- Trap taught explicitly: method choice is a MEASUREMENT decision (do you have a
  stable baseline to improve?), not a fashion choice.

## Slide 3 — The Define deliverables map (10 min)
- Charter (Module 03) <- baselines (this module) <- raw CSVs (data provenance law).
- MGPP traceability (Module 07) <- Y statements (this module) <- ODs (Module 07).
- Risk register + comms plan (Module 03) <- scope decisions <- the same baselines.
- Each deliverable names its upstream data file — that is what makes the gate
  replayable.

## Slide 4 — DPMO and the operational definition (15 min)
- Worked example 1 in README, derivation visible: totals first, then DPU,
  then opportunities, then sigma level.
- The lesson: 12,104.7 vs 2,017.5 DPMO — same parts, same defects; the
  OPPORTUNITY COUNT is an operational definition, and changing it moves the
  number without touching the process.

## Slide 5 — The cycle-time Y (10 min)
- Worked example 2 in README: median 17.35 d, P90 24.1 d, 40/40 over target.
- Which goes in the Y statement? The median (registry pins 18.4 d registry-level).
  P90 and % breach stay visible: tail drives the customer promise; % breach is
  the honest gate metric for a max-type target.

## Slide 6 — Baseline vs registry constant (10 min)
- Sample mean 17.8 d vs pinned 18.4 d: lawful pair of explanations (sampling
  noise / process moved); se = 0.69 d, so sampling noise explains it.
- Never re-pin a registry constant from one sample; never quote a sample as the
  registry value. State which you are citing.

## Slide 7 — Y statement workshop (15 min)
- Rubric: baseline -> target -> OD -> gate. Remove one element, lose auditability.
- Students draft CTQ-1/2/3 Ys; peer review against the README gate checklist.

## Slide 8 — Recap (5 min)
- Define = measured, auditable problem; the numbers are contracts with data files.
- Lab next: re-derive both baselines yourself, then defend them in the court.

## Keyed lab handoff
Lab: `lab.md` — re-derives the DPMO ladder and lead-time stats from the CSVs;
court: `python3 modules/02-define-overview/courts/court.py` (exit 0 = 14 checks).
