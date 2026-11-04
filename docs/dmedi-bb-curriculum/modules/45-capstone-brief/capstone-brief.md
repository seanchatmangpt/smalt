# Capstone Project Brief — CPPC SR-71 Gimbal CNC Line (Module 45)

**Module**: 45-capstone-brief
**Role in course**: the integrating artifact. The capstone is the student's end-to-end DMEDI
project on the CPPC running case: every tool taught in Modules 01–44 is applied once, on real
(synthetic, seed-stated) data, to move the pinned CTQs from baseline to sustained target and
receipt it at the week-26 gate review.
**Prerequisite**: Modules 01–44 complete (courts passed). The capstone re-derives everything;
prior module solution keys are reference material, never copyable answers.

## 1. The project in one paragraph

CascadeProjects Precision Components (CPPC), a 140-person machining shop, is launching a new
CNC production line for the SR-71 drone-gimbal housing (aluminum 7075, 3-axis mill). You are
the Black Belt. Over a 26-week DMEDI program you must take the line from baseline to:

| CTQ | Baseline | Target | Gate horizon |
|---|---|---|---|
| CTQ-1 bore diameter 12.000 mm ± 0.025 mm | Cpk 0.72 (μ = 12.009 mm) | Cpk ≥ 1.33 sustained 30 days | weeks 21–26 |
| CTQ-2 order-to-ship lead time | 18.4 days | ≤ 7 days | week 26 |
| CTQ-3 unit cost | $41.80 | ≤ $28.50 ceiling | week 26 |

All numbers re-derive from `data/` and `datasets/` CSVs per the RUNNING-CASE provenance law.
Every claim you make in the capstone must name its dataset, its computation (python3, stdlib),
and the exact command that replays it.

## 2. Program scaffold (fixed for all students)

- **Team**: you are the BB; name a sponsor (Manufacturing Engineering manager), a process owner
  (CNC line lead), and 2 team members (quality engineer, production planner).
- **Calendar**: 26 weeks; gate reviews at weeks 5/9/15/21/26. A gate that misses its calendar
  slot is rescheduled, never skipped; a skipped gate voids every downstream gate.
- **Data law**: synthetic datasets with stated seeds; any number that cannot be re-derived from
  a registered CSV is inadmissible at a gate.
- **Honesty law**: a phase that did not happen is reported as not-done, not narrated as done.
  The Implement gate fails loudly if the 30-day sustainment window has fewer than 30 daily
  subgroup records.

### 2.1 Pinned-constant inconsistency (read before the Measure gate)

The spine pins baseline Cpk = 0.72 with μ = 12.009 mm and σ = 7.407 µm (ADJUDICATED
2026-11-04: the ORIGINAL spine σ = 4.17 µm computed Cpk ≈ 1.28 and was ruled stale —
see RUNNING-CASE.md and the MANIFEST cross-module note). **Capstone law**: use the
adjudicated pair (σ = 7.407 µm) and state the adjudication explicitly in your
Measure-gate workbook section — a capstone that silently inherits the stale
σ = 4.17 µm constant fails the gate. Re-derive your working baseline
Cpk from `data/bore-baseline-100.csv` (sample) and `data/xbar-r-subgroups.csv` (within-subgroup
σ estimate) and reconcile both against the pinned value; document the reconciliation method.

## 3. Phase-by-phase scope

Each phase below names WHAT the student must produce and the GATE QUESTION a reviewer asks.
Section-by-section fill-in structure lives in `capstone-workbook.md`; deliverable checklists,
gate questions, and scoring live in `phase-gate-checklist.md` and `scoring-rubric.md`.

### Phase 1 — Define (weeks 1–5, gate at week 5)

Produce: project charter on the Module 03 template; CTQ tree from VOC (Module 04 method);
MGPP business case (market/growth/profit/position) with the CTQ-3 costing ceiling derived, not
asserted; risk register with owners and triggers; communications plan.

Gate question: *"If I stopped this project today, would the charter alone tell me what success
measured, who is accountable, and what could kill it — with numbers, not adjectives?"*
Reject if: CTQs are not traceable to specific customer statements; the $28.50 ceiling has no
cost-buildup derivation; risks have no trigger conditions.

### Phase 2 — Measure (weeks 6–9, gate at week 9)

Produce: MSA (gage R&R) on the bore measurement system per the MSA module method, computed
from `datasets/gage-rr-bore.csv`; baseline capability study with Cpk re-derived from raw CSVs
(between/within reconciliation from the two bore CSVs); VOC→QFD house of quality linking
customer statements to engineering characteristics with scored relationships; COPQ estimate
for CTQ-2 and CTQ-3 baselines.

Gate question: *"Can I trust the numbers, and are they the numbers?"* Reject if: %GRR is not
computed with the accept/reject/<10% / 10–30% / >30% decision bands applied to the actual
value; baseline Cpk is quoted without the python3 command that produced it; the QFD roof
correlations are asserted without a stated scoring convention.

### Phase 3 — Explore (weeks 10–15, gate at week 15)

Produce: concept generation (≥ 4 candidate concepts for closing the capability gap, e.g.
process-parameter window, tooling/coating change, thermal-stabilization, machine-selection);
Pugh matrix and AHP scoring per the selection module, with the selected concept carrying
falsifiable claims; hypothesis tests on baseline data (e.g. is the day-17–19 lead-time
excursion in `data/lead-defectives.csv` special cause or shift in p — test it, don't narrate
it); Multi-Vari analysis of bore variation (within-part / part-to-part / temporal) and a
regression of bore deviation on candidate explanatory variables; tolerance analysis and Monte
Carlo simulation of the selected concept's predicted capability.

Gate question: *"Does the selected concept win on evidence, and is its claim falsifiable?"*
Reject if: fewer than 3 concepts scored; the Pugh/AHP result is asserted without the weight
derivation; the Monte Carlo gives a predicted Cpk with no stated distribution assumptions or
verification run; hypothesis tests report p-values without test assumptions checked.

### Phase 4 — Develop (weeks 16–21, gate at week 21)

Produce: DFMEA on the selected concept with RPN ranking and reduction actions; DOE program —
screening (fractional factorial on the four pinned factors: spindle RPM, feed rate, coolant
%, tool coating; responses: bore deviation µm and Ra) followed by a response-surface run on
the surviving factors; the helicopter lab executed as a skills proof (factorial DOE on a
physical/simulated flying device, full design → run → analyze → report); robust-design
analysis (factor effects vs noise effects, variance transmission); reliability allocation
mapping the spindle MTBF target 1,200 h / B10 = 900 h down to component targets.

Gate question: *"Is the design proven, or merely proposed?"* Reject if: DOE runs lack
randomization and residual diagnostics; the helicopter lab is described but its data and
analysis are absent; the reliability allocation doesn't reconcile to the 1,200 h / 900 h
targets; predicted process capability post-DOE is not stated as a number with a CI.

### Phase 5 — Implement (weeks 21–26, gate at week 26)

Produce: pilot plan and executed pilot run at production rates; process control plan (CTQ ×
control method × sample size/frequency × reaction rule); control charts on pilot data with
sustainment evidence; updated FMEA and lessons-learned; handoff package (owner, training,
reaction plan, audit cadence) and the final program receipt.

Gate question: *"Would this line hold the gains if the Black Belt left tomorrow?"* Reject if:
the 30-day sustainment window has missing days; the control plan has CTQs without reaction
rules; the handoff has no named owner who accepted it; the final receipt cannot be replayed
command-for-command.

## 4. Program-level falsifiers (any one voids the capstone)

1. A gate passed with any deliverable missing or any number un-re-derivable from its CSV.
2. The final receipt claims CTQ-1 ≥ 1.33 sustained 30 days without 30 consecutive daily
   subgroup records at or above target.
3. A module tool cited in the traceability table (§6) never appears in any workbook section.
4. The pinned-constant discrepancy (§2.1) is silently inherited rather than adjudicated.
5. Weights, gate questions, or checklists altered from this brief without a filed amendment.

## 5. Deliverable set (what you hand in at week 26)

1. This workbook, fully populated: `capstone-workbook.md`.
2. Computation receipts: one runnable python3 script per phase whose output is quoted in the
   workbook (identity + replay fields of every receipt).
3. Raw + derived data: registered CSVs you generated, appended to the dataset MANIFEST with
   seed and generator statement.
4. Gate-review minutes: five one-page gate records, each listing the deliverables presented,
   the reviewer's gate-question verdict, and open risks carried forward.
5. Final program receipt: five fields (identity/authority/consequence/replay/standing) per the
   Module 01 receipt format, with CTQ-1/2/3 final measured values.

## 6. Cross-module traceability table

Every capstone artifact ↔ the module that taught it. The court checks each of the 45 modules
appears at least once; a module with no capstone artifact is a curriculum gap, not a student
omission. (Module titles for 06–27 and 31–44 are the course catalog titles; landed modules
match the repo directories.)

| Module | Title | Capstone artifact(s) fed |
|---|---|---|
| 01 | Intro to DMEDI | Program receipt format; five-gate calendar; honesty law |
| 02 | Define overview (DMEDI vs DMAIC) | Phase-1 framing memo: why DMEDI for the CNC line |
| 03 | Charter / MGPP / risk / comms | Charter; MGPP case; risk register; comms plan |
| 04 | Voice of Customer | VOC statements → CTQ tree inputs |
| 05 | QFD | House of quality; CTQ prioritization weights |
| 06 | Project selection & financials | CTQ-3 cost buildup → $28.50 ceiling derivation |
| 07 | Stakeholder & team formation | Named sponsor/owner/team; RACI in charter |
| 08 | Intro to Minitab (analysis env) | Analysis environment setup receipt; all module analyses |
| 09 | Basic statistics | Distributional checks behind every CI and test |
| 10 | Variation & control charts | Baseline stability proof before capability claims |
| 11 | MSA / Gage R&R | Phase-2 MSA from gage-rr-bore.csv |
| 12 | Process capability (Cpk/Ppk) | Baseline Cpk reconciliation; post-DOE predicted Cpk |
| 13 | SIPOC & process mapping | Order-to-ship map behind CTQ-2 baseline |
| 14 | COPQ / yield / DPMO | COPQ estimate for CTQ-2/CTQ-3 |
| 15 | Sampling & data collection plans | Pilot sampling plan; sustainment daily subgroups |
| 16 | Multi-Vari analysis | Bore variation family study (within/part/temporal) |
| 17 | Hypothesis testing fundamentals | Lead-time excursion test; all test assumption checks |
| 18 | t-tests & paired comparisons | Before/after pilot comparisons (CTQ-2, CTQ-3) |
| 19 | ANOVA (one-way) | Factor screening on categorical levels (coating) |
| 20 | Chi-square & proportions | Lead-defectives p-shift test (p-chart court) |
| 21 | Regression (simple/multiple) | Bore deviation regression model in Explore |
| 22 | Logistic regression | Defective/non-defective model on lead-defectives |
| 23 | Non-parametric methods | Assumption-failed fallback tests, documented |
| 24 | SPC fundamentals / I-MR | Sustainment I-MR chart on bore deviation |
| 25 | X-bar/R and attribute charts | Sustainment subgroup charts; p-chart on pilot defects |
| 26 | Measurement-system monitoring | Ongoing MSA audit cadence in control plan |
| 27 | FMEA (process) | PFMEA in control-plan section |
| 28 | Two-way ANOVA | RPM × feed interaction analysis in DOE follow-up |
| 29 | Intro to DOE | DOE program framing; helicopter lab design |
| 30 | Full factorial DOE | Screening run on 4 pinned factors |
| 31 | Fractional factorial & screening | Resolution IV screen, aliasing statement |
| 32 | Response surface methods | RSM on surviving factors; optimum window |
| 33 | Blockings, randomization, covariates | DOE blocking on raw-stock lots; randomization proof |
| 34 | Concept generation methods | ≥ 4 concepts in Explore gate |
| 35 | Pugh matrix & AHP selection | Scored selection with weight derivation |
| 36 | Tolerance analysis & Monte Carlo | Predicted Cpk simulation of selected concept |
| 37 | Robust design (Taguchi) | Noise-factor analysis; variance transmission |
| 38 | DFMEA | Phase-4 DFMEA with RPN reduction actions |
| 39 | Reliability (MTBF/B10 allocation) | Spindle 1,200 h / B10 900 h allocation |
| 40 | DFM / Design for assembly | Housing design feedback into concept |
| 41 | Pilot planning & execution | Pilot run at production rates |
| 42 | Control plans | CTQ × method × reaction-rule table |
| 43 | Sustainment & handoff | 30-day sustainment evidence; owner acceptance |
| 44 | Program closeout & receipts | Final five-field program receipt |
| 45 | Capstone (this module) | Integration of all of the above |

## 7. Standing

| Item | Standing |
|---|---|
| Brief | ALIVE (authored this session, this repo) |
| Traceability coverage | 45/45 modules (court-checked, see court receipt) |
| Rubric weights sum | verified 100 (python3-checked, see court receipt) |
| Pinned-constant defect | OPEN (course-level, Lane 19 owns adjudication; capstone §2.1 documents the workaround law) |

## 8. Learning objectives

After completing the capstone the Black Belt candidate can:

1. Integrate all prior module tools (QFD, MSA, capability, concept selection, DOE, robust design, reliability, pilot, SPC, handoff) into one coherent 26-week DMEDI program on the CPPC running case, with every phase feeding the next through re-derived numbers.
2. Produce replayable evidence for every claim: each number names its registered dataset, its python3 (stdlib) computation, and the exact command that reproduces it.
3. Re-derive the pinned CTQ trajectory — bore Cpk 0.72 → ≥ 1.33 sustained 30 days, lead time 18.4 → ≤ 7 days, unit cost $41.80 → ≤ $28.50 — and defend each gate crossing at the week-5/9/15/21/26 reviews.
4. Apply the honesty law under schedule pressure: report a phase that did not happen as not-done, and pass a gate only on measured evidence (the Implement gate fails loudly on a sustainment window with fewer than 30 daily subgroup records).
5. Assemble and defend a five-field program receipt (identity, authority, consequence, replay, standing) at the week-26 closeout, scored against the five-dimension rubric in `scoring-rubric.md`.

## 9. Timing and effort per phase

The capstone spans the 26-week program calendar (gate reviews at weeks 5/9/15/21/26).
Realistic student effort, per phase:

| Phase | Modules consumed | Effort |
|---|---|---|
| Define + Measure (charter, VOC, QFD, MSA, baseline Cpk) | 01–12 | (40 h) |
| Explore (concept gen/selection, hypothesis testing, Multi-Vari, regression) | 13–28 | (50 h) |
| Develop (DOE program, curvature, mixture, robust design, helicopter lab, prototype/pilot plan) | 29–41 | (60 h) |
| Implement + control (pilot execution, control plan, 30-day sustainment) | 42–43 | (30 h) |
| Handoff + closeout (receipt, brief writing, gate review prep) | 44–45 | (20 h) |

Total ≈ 200 h of student effort across the 26 calendar weeks (≈ 8 h/week), consistent with
a Black Belt project workload. Phase boundaries align with the gate reviews; a phase that
runs past its gate is rescheduled per §2, never skipped.

## 10. Tooling note

- **Primary analysis environment**: python3, standard library only (as taught in Module 08's
  Minitab-introduction session and mirrored in every module's `data/compute.py` key scripts).
  Every capstone computation must replay with `python3` and no third-party packages.
- **Minitab path** (if the student's site licenses it): any capstone statistic may be
  cross-checked in Minitab (Stat > Basic Statistics / DOE > Factorial / Control Charts),
  but Minitab output alone is not evidence — the replayable python3 command is the
  receipt; Minitab is the confirmation mirror, never the source of record.
- **Replay law**: a claim whose command was not shown at the gate is inadmissible
  (§1 data law). The week-26 auditor re-runs the receipt commands from a clean checkout.
