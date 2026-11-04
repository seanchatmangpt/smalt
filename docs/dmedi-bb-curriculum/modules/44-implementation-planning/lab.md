# Module 44 Lab — Assemble the Handoff Package

**Prerequisites**: Modules 42–43 artifacts exist (pilot receipt, control plan, OCAPs, courts both exit 0).

## Part 1 — Verify the roadmap arithmetic
Confirm with python3: pilot 30-day window: starts week-16 day 4 (16.5 + 30/7 = week 20.8, before the week-21 gate; a week-17 start ends at 21.29 and misses the gate); no overlap between phases; phase boundaries land on gate weeks (16→21→26). The court script does this exit-checked.

## Part 2 — Training records register
Fill the role matrix from Slide 3: for each of the 20 role slots (12 operators + 3 inspectors + 3 shift leaders + 1 process engineer + 1 quality manager), record role, training window (weeks 21–24), evidence, signer. 20/20 rows filled = complete.

## Part 3 — Audit cadence plan
Produce the cadence table (weekly weeks 22–26 → biweekly→monthly months 2–3 → quarterly month 4+) with the decay law and the escalation-back-up trigger written in.

## Part 4 — Write the program receipt
One receipt naming: subject (CPPC SR-71 gimbal CNC line), the three CTQ targets, the week-21 and week-26 gate receipts, replay commands (the three court scripts, Modules 42/43/44), standing.

## Part 5 — Handoff checklist cross-check
For each of the 7 checklist items, run the existence check the court uses: control plan (Module 43 key), OCAPs (3 named in Module 43 key), capability receipt (Module 42 key), MSA evidence (Module 11), training register (this lab), audit record (this lab), program receipt. The court exits 1 naming any missing item.

## Court
`python3 modules/44-implementation-planning/court.py` from the curriculum root.

## Timing (per activity)

| Part | Activity | Time |
|---|---|---|
| 1 | Verify the roadmap arithmetic | (10 min) |
| 2 | Training records register | (15 min) |
| 3 | Audit cadence plan | (15 min) |
| 4 | Write the program receipt | (10 min) |
| 5 | Handoff checklist cross-check | (10 min) |

Total 60 min — consistent with the slides-outline estimate (lab 1.0 h).
