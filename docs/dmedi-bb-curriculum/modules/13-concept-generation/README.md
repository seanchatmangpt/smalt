# Module 13 — Concept Generation

# Concept Generation (Develop)

Course spine: CascadeProjects Precision Components (CPPC). Read
`../../RUNNING-CASE.md` first; every example here uses its pinned constants
without varying them.

## Where this sits in DMEDI

Concept generation is the first act of **Develop**: before any factor is tested
in a DOE, candidate solutions to the CTQ gap must exist, be made distinct, and
be scored. Garbage concepts in → garbage DOE out. This module converts the
Define/Measure problem statement (bore diameter Cpk 0.72 baseline vs target
Cpk >= 1.33) into a scored concept portfolio that Module 14 (TRIZ) then
enriches and Module 15 (transactional TRIZ) mirrors on CTQ-2.

## Learning objectives

By the end of this module you can:

1. Run four structured ideation tools on a real CTQ gap: structured
   brainstorming, analogical transfer, function-analysis-based ideation, and
   SCAMPER.
2. Collapse a raw idea list into a distinct concept set using affinity mapping
   (12 raw ideas -> 8 concepts, 4 merges).
3. Score a concept portfolio for novelty and feasibility with weighted,
   reproducible arithmetic (no remembered answers — every score re-derives
   from `datasets/concept-portfolio.csv` via `scripts/score_concepts.py`).
4. Defend a portfolio decision: top score wins a Develop slot, runner-up is
   carried as a fallback, bottom score is explicitly killed with a reason.

## The problem on the table

- CTQ-1: bore diameter, spec 12.000 mm +/- 0.025 mm, baseline
  Cpk = 0.72 (pinned in RUNNING-CASE.md; the Cpk re-derivation itself is
  Lane 05's court, not this module's).
- Gap: the process is not capable; both mean offset (mu = 12.009 mm, i.e.
  +9 um above nominal) and variation contribute. Sigma note: Lane 05's module
  12 court reconciled the running-case pin — Cpk 0.72 reproduces at
  sigma = 7.407 um (the 4.17 um figure belongs to different datasets); this
  module cites Cpk 0.72 and does not use sigma numerically.
- Candidate concepts must attack mean offset, variation, or both.

## The four tools, applied to the CPPC bore problem

### 1. Structured brainstorming (round-robin with a fixed stimulus deck)

Random or free-form brainstorming clusters on the first idea spoken. The
structured variant forces coverage: each participant writes ideas against a
rotating stimulus (function question, constraint question, resource question)
for 3 minutes, then passes. For CPPC the three prompts were:

- Function: "How else could a 12.000 mm hole be produced or finished?"
- Constraint: "What would we do if the tool could never be changed mid-shift?"
- Resource: "What energy or information in the machine is currently wasted?"

Output rules: one idea per card, no criticism during capture, every card
survives to affinity mapping.

### 2. Analogical transfer

Ask: who else solves "hold a dimension while a cutting edge wears"? Structured
analogy sources for CPPC:

- Woodworking planers: adjustable mouth + test cuts (intermediate reference).
- Transfer printing: a master template carries the dimension, the tool copies.
- Jet engine overhaul: borescopes and compensating shims — measure, then
  offset, rather than rework.
- Watchmaking: jewel bearings are lapped to fit the *measured* hole, not a
  nominal.

Transfer lesson: strong analogies separate the *reference* (who defines
12.000?) from the *actuator* (who moves metal). Weak analogies in the raw list
were killed in affinity mapping.

### 3. Function-analysis-based ideation

Build the function model of the boring operation, then attack each function:

- Boring bar SUPPORTS tool; tool REMOVES material; coolant REMOVES heat;
  operator ADJUSTS offset (weekly, by trial cuts).
- Harmful functions to eliminate: holder DEFLECTS under cut; thermal growth of
  spindle SHIFTS axis; wear of tool EDGE GROWS bore.
- Ideation questions per function: can the function be done better elsewhere,
  by another component, or continuously instead of episodically?

This is where the thermal-error concept (C7) and the compensated in-process
gauge (C1) came from: operator ADJUSTS offset episodically is the harmful
episodic function; making adjustment continuous or automatic is the concept
direction.

### 4. SCAMPER on the existing process

Applied to "mill the bore in one pass with a manual offset":

| Letter | Question | CPPC answer that became a concept |
|---|---|---|
| Substitute | What if the reference changes? | C1: gauge sets reference, not trial cuts |
| Combine | What if rough and finish are separated? | C3: segmented rough/finish toolpath |
| Adapt | What do other shops do? | C5: re-grip elimination from 5-axis practice |
| Modify/Magnify | What if speed changes? | C2: adaptive feed instead of fixed feed |
| Put to other use | What waste signal exists? | C6: acoustic emission as wear signal |
| Eliminate | What can be removed? | C4: eliminate heat, not correct it (cryo cooling) |
| Reverse/Rearrange | What if compensation is continuous? | C7: thermal model drives live offset |

## Affinity mapping: 12 raw ideas -> 8 concepts

The workshop produced 12 raw idea cards (funnel seed 1317 registered per the
data provenance law). Four affinity merges collapsed them to the 8 distinct
concepts in the portfolio:

1. "auto-offset", "servo Compensation", "feedback gauge" -> C1 (one concept:
   measure and compensate).
2. "high RPM test", "aggressive feed" -> C2 (one concept: adaptive cutting
   parameters).
3. "two-pass program", "spring pass control" -> C3 (one concept: segmented
   rough/finish).
4. "coolant mix change", "chilled coolant" -> C4 (one concept: aggressive
   thermal control).

No concept is admitted to scoring without a named TRIZ anchor (the anchor
column in the dataset) — this is the handoff seam to Module 14.

## Scoring the portfolio

Score = 0.4 * novelty + 0.6 * feasibility, both on 1-5 scales defined below.
Weights favor feasibility because the program gate (week 9) requires a
validated pilot, not a patent filing.

- Novelty: 1 = standard practice in this shop, 3 = new to this shop, practiced
  elsewhere in the industry, 5 = not standard practice anywhere we can cite.
- Feasibility: 1 = requires capabilities CPPC does not have and cannot buy in
  the program window, 3 = one new capability required, 5 = implementable with
  current equipment and skills.

Ranking (re-derive with `python3 scripts/score_concepts.py`):

| Rank | ID | Concept | Novelty | Feasibility | Score |
|---|---|---|---|---|---|
| 1 | C1 | Compensated in-process gauge | 3 | 5 | 4.20 |
| 2 | C7 | Thermal-error model + offset | 4 | 4 | 4.00 |
| 3 | C3 | Segmented rough/finish toolpath | 2 | 5 | 3.80 |
| 4 | C5 | Multi-axis re-grip elimination | 3 | 4 | 3.60 |
| 5= | C2 | Adaptive feed control | 4 | 3 | 3.40 |
| 5= | C6 | Acoustic-emission tool monitor | 4 | 3 | 3.40 |
| 7 | C4 | Cryogenic spindle cooling | 4 | 2 | 2.80 |
| 8 | C8 | Gradient-index boring bar | 5 | 1 | 2.60 |

Portfolio decision: C1 enters the Module 14 TRIZ deepening and the week-9
pilot slot; C7 is the named fallback; C8 is explicitly killed (novelty cannot
rescue an infeasible concept inside a 26-week program); C4 is parked pending a
cost study against CTQ-3 (unit cost ceiling $28.50).

## Files in this bundle

- `workshop.md` — learner exercises.
- `solution-key.md` — numbered, self-consistent answers; all arithmetic
  re-derives from the dataset.
- `datasets/concept-portfolio.csv` — the 8 concepts with scores' inputs.
- `scripts/score_concepts.py` — the only lawful way to produce the ranking.
- `court.py` — executable court: wraps `score_concepts.py` (rc 0), re-derives the ranking independently from `datasets/concept-portfolio.csv`; `python3 court.py` exit 0, `--mutate` exit 1.

## See Also

- `../14-triz-product/README.md` — TRIZ deepening of C1.
- `../15-triz-transactional/README.md` — the same toolkit on CTQ-2.
- `../../RUNNING-CASE.md` — pinned constants.
