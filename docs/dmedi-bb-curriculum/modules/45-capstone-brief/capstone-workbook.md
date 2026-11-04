# Capstone Workbook — CPPC SR-71 Gimbal CNC Line (Module 45, student fill-in)

**Module**: 45-capstone-brief
**How to use this workbook**: every section below states (a) what the section must contain,
(b) the gate question it answers, (c) the acceptance conditions. The content after each
prompt is YOURS — the brief defines the contract, you supply the evidence. Do not delete the
prompts; answer beneath them. Every number must carry a replay command
(`python3 <script>.py <csv>`), every dataset a seed and generator statement, every claim a
named source. A section whose acceptance conditions are unmet is marked NOT MET with the
reason — an honest NOT MET scores better than an unreceipted claim.

---

## Phase 1 — Define (answers gate question: does the charter alone carry the project?)

### 1.1 Project charter (Module 03 template)
Contents required: problem statement with baseline numbers (Cpk, lead time, unit cost); goal
statement with the pinned targets; scope boundary (what the CNC line project includes and
excludes); named sponsor, process owner, team, Black Belt; milestones tied to the five gate
weeks; sponsor signature line.
Gate question answered: *who is accountable for what, by when, measured how?*
Acceptance: charter complete on template; every number matches the RUNNING-CASE pins or
carries a filed discrepancy note (§2.1 of the brief).

### 1.2 CTQ tree (Module 04 method)
Contents required: customer statements (drone OEM assembly, end-user flight-hours, CPPC
ops) decomposed to CTQ-1/2/3 with measurable specs; at least one second-level decomposition
per CTQ (e.g. bore diameter → bore size + bore roundness).
Gate question answered: *are the CTQs traceable to actual customer statements, not internal
opinions?*
Acceptance: each CTQ cites ≥ 1 customer statement; specs match pinned constants.

### 1.3 MGPP business case
Contents required: Market, Growth, Profit, Position statements, each with a quantified claim;
the $28.50 costing ceiling derived from a cost buildup (material + machine-hour + labor +
overhead absorption), showing the delta from $41.80 baseline and which levers close it.
Gate question answered: *is this project worth doing, in money?*
Acceptance: cost buildup arithmetic re-derivable; profit claim consistent with CTQ-3 target.

### 1.4 Risk register
Contents required: ≥ 8 risks, each with probability/impact scores, trigger condition, owner,
mitigation. At least: raw-material lot variation, gage capability unknown, supplier lead-time,
skill ramp on new line, thermal drift, schedule collision with gate weeks.
Gate question answered: *what could kill this project, and who is watching for it?*
Acceptance: every risk has a trigger (an observable event, not "if things go badly").

### 1.5 Communications plan
Contents required: stakeholder × message × channel × frequency table; gate-review calendar
(weeks 5/9/15/21/26) with named attendees.
Acceptance: five gate reviews scheduled with attendees named.

## Phase 2 — Measure (answers: can I trust the numbers, and are they the numbers?)

### 2.1 MSA / Gage R&R
Contents required: ANOVA or average-and-range gage R&R from `datasets/gage-rr-bore.csv`;
%GRR, ndc, repeatability vs reproducibility split; accept/reject verdict against the
<10% / 10–30% / >30% bands; verdict drives a documented action if not acceptable.
Gate question answered: *is the measurement system fit to produce the baseline?*
Acceptance: %GRR and ndc computed by a replayable script; band verdict stated; if >30%, a
corrective action exists and the baseline is marked provisional.

### 2.2 Baseline capability study
Contents required: normality check; Cpk from `data/bore-baseline-100.csv` (overall) and from
`data/xbar-r-subgroups.csv` (within, via R-bar/d2); reconciliation of the two estimates; the
the 2026-11-04 adjudication (stale σ = 4.17 µm → adjudicated σ = 7.407 µm) stated with your chosen working pair and why.
Gate question answered: *what is the honest starting capability, and where did the number
come from?*
Acceptance: both Cpk estimates quoted with commands; reconciliation method named; discrepancy
not silently inherited.

### 2.3 VOC→QFD house of quality
Contents required: customer statements (weighted) × engineering characteristics matrix with
a stated relationship-scoring convention; roof correlations; technical importance ranking;
CTQ-1 target carried into the matrix.
Gate question answered: *which engineering characteristics actually move customer value?*
Acceptance: scoring convention stated; ranking arithmetic replays.

### 2.4 COPQ baseline
Contents required: COPQ for CTQ-2 (expedite freight, WIP carrying) and CTQ-3 (scrap/rework
from out-of-spec bores) with per-unit and annualized figures derived from baseline DPMO.
Acceptance: DPMO input re-derived from baseline CSVs.

### 2.5 Baseline stability proof
Contents required: I-MR chart logic on the 100-bore baseline and X-bar/R on subgroups;
conclusion states whether the baseline is stable (a capability number on an unstable process
is inadmissible downstream).
Acceptance: stability verdict explicit; special-cause days flagged if any.

## Phase 3 — Explore (answers: does the selected concept win on evidence?)

### 3.1 Concept generation
Contents required: ≥ 4 concepts for closing the capability gap, each described in 2–3
sentences with mechanism of action on bore variation. (Suggested families: parameter window,
tooling/coating, thermal stabilization, machine selection — your own set is fine.)
Acceptance: concepts are distinct mechanisms, not variations of one lever.

### 3.2 Concept selection (Pugh + AHP)
Contents required: Pugh matrix vs baseline datum; AHP pairwise weights with consistency
ratio; combined verdict naming the selected concept.
Gate question answered: *why this concept, on stated criteria, with checkable weights?*
Acceptance: CR < 0.10; Pugh totals re-derivable; selection follows from the scores (or the
override is justified in writing).

### 3.3 Hypothesis tests on baseline
Contents required: test whether days 17–19 of `data/lead-defectives.csv` differ in p from the
rest (two-proportion z or chi-square, assumptions checked); at least one t-test on bore data;
each test states H0/H1, alpha, assumption check, result, conclusion in plain words.
Acceptance: no test reported without its assumption check.

### 3.4 Multi-Vari study
Contents required: bore variation partitioned (within-part / part-to-part / temporal) from
baseline data; the dominant family named with its share of total variance.
Acceptance: variance shares sum to ~100% and re-derive.

### 3.5 Regression
Contents required: regression of bore deviation on ≥ 2 candidate explanatory variables;
residual diagnostics; the model's R² and what it does NOT explain, stated.
Acceptance: diagnostics shown; no causal claim beyond the data.

### 3.6 Tolerance analysis + Monte Carlo
Contents required: tolerance stack for the selected concept; Monte Carlo (stated
distributions + parameters, stated seed) producing predicted Cpk distribution; sensitivity
ranking of inputs.
Gate question answered: *what capability will this concept deliver, with what confidence?*
Acceptance: predicted Cpk stated as distribution with CI; seed registered in MANIFEST.

## Phase 4 — Develop (answers: is the design proven?)

### 4.1 DFMEA
Contents required: DFMEA on the selected concept: functions, failure modes, effects, causes,
controls, RPN; ≥ 3 RPN-reduction actions with before/after RPN.
Acceptance: severity/occurrence/detection scales stated and applied consistently.

### 4.2 Screening DOE
Contents required: fractional factorial (resolution stated, aliasing named) on the four
pinned factors vs both responses (bore deviation µm, Ra); run order randomized; effects
ranked; surviving factors declared with the effect evidence.
Acceptance: aliasing statement present; residuals diagnosed; half-normal/Pareto of effects.

### 4.3 Response-surface DOE
Contents required: RSM (CCD or Box-Behnken) on surviving factors; fitted surface; optimum
window in factor space; confirmation runs at the optimum.
Acceptance: predicted-vs-observed gap at optimum reported and within the stated CI.

### 4.4 Helicopter lab (skills proof)
Contents required: full factorial DOE on the paper-helicopter (factors of your choice, ≥ 3
factors, 2 levels); design matrix, raw flight data, analysis, one graph; one paragraph: what
this lab proves about your DOE competence.
Acceptance: data present; analysis replays; the lab was actually run — a described-but-not-
run lab fails the gate.

### 4.5 Robust design
Contents required: classification of factors into control vs noise; variance transmission to
bore deviation; the robust setting chosen (may differ from the mean-optimal setting) with
reason.
Acceptance: noise factors named from the risk register or DOE evidence, not invented.

### 4.6 Reliability allocation
Contents required: spindle assembly MTBF 1,200 h / B10 900 h allocated down to ≥ 4 component
targets (bearings, motor, drawbar, encoder) with the allocation method stated (equal,
AGREE, or complexity-weighted) and arithmetic re-derivable.
Acceptance: component targets reconcile to assembly targets.

## Phase 5 — Implement (answers: would the line hold the gains without you?)

### 5.1 Pilot plan and run
Contents required: pilot plan (duration, rate, sampling per Module 15 method, abort criteria)
and the executed run record: dates, pieces, rate achieved, deviations.
Acceptance: pilot ran at production rate; deviations logged, not hidden.

### 5.2 Capability proof on pilot
Contents required: Cpk on pilot bore data; paired before/after comparison (t or Mann-Whitney)
on lead time and unit cost; CTQ-2 and CTQ-3 final values vs targets.
Acceptance: comparison test assumption-checked; final CTQ values stated with CI.

### 5.3 Control plan
Contents required: table — CTQ × characteristic × control method (SPC chart type per Module
24/25) × sample size/frequency × reaction rule × owner; PFMEA reference (Module 27); ongoing
MSA audit cadence (Module 26).
Gate question answered: *is every CTQ watched by a named person with a reaction rule?*
Acceptance: no CTQ row without a reaction rule and owner.

### 5.4 Sustainment evidence
Contents required: 30 consecutive daily subgroup records at/above target on the sustainment
control chart; any out-of-control days with reaction records.
Acceptance: 30/30 records present or the gate fails loudly.

### 5.5 Handoff package
Contents required: named accepting owner with signature; training record; reaction plan;
audit cadence; lessons learned (what the program got wrong — required, minimum 3).
Acceptance: owner acceptance is a signature, not a claim.

### 5.6 Final program receipt
Contents required: five fields — identity (exact project subject + data SHA/seeds), authority
(gate reviewers + verdicts), consequence (final CTQ-1/2/3 measured values), replay (script
list that regenerates every number), standing (verdict as of date).
Acceptance: every number in the receipt replays from the listed scripts.

---

## Workbook completion checklist (student self-check before week 26)

- [ ] All five phases have every section populated or honestly NOT MET with reason.
- [ ] Every number has a replay command that exits 0.
- [ ] Every generated dataset is registered (file, seed, generator) in the dataset MANIFEST.
- [ ] The §2.1 pinned-constant discrepancy is adjudicated in Phase 2.
- [ ] Five gate-minute records exist, one per gate, each with reviewer verdicts.
- [ ] The helicopter lab was actually run, with data.
- [ ] Final receipt present with all five fields.

---

## Phase 2 worked-example cross-reference (instructor derivation)

`worked-example-measure.md` demonstrates Phase 2 (Measure) end-to-end with the instructor's
derivation VISIBLE: study plan, %GRR = 13.97% (ndc 9) re-derived from
`data/gage-rr-bore.csv`, Cpk = 0.72 re-derived from `data/cpk072-bore-subgroups.csv`
(σ_within = 7.407 µm, μ = 12.009 mm — the adjudicated pair, re-derived not inherited), the
gate question answered, and the verdict vs target 1.33 stated as NO with the honesty-law
consequences. Study it BEFORE filling §2.1–2.5; your own derivation must stand on raw CSVs
the same way — copy the method, not the numbers.

### Fill-in: my Phase 2 derivation receipt

- MSA %GRR (from `data/gage-rr-bore.csv`, replay command): `____________________`
  %GRR = ______ %  → band verdict (circle one): <10% / 10–30% / >30%  ndc = ______
  If >30%: corrective action + provisional flag: ____________________
- Baseline Cpk (from `data/cpk072-bore-subgroups.csv`, replay command): `____________________`
  μ = ______ mm  R̄ = ______ mm  σ_within = ______ µm  Cp = ______  Cpk = ______
- Adjudication statement (§2.1 of the brief): working pair = σ = ______ µm, because:
  __________________________________________________________________
- Stability verdict (X̄/R limits, out-of-control subgroups): ____________________
- Gate question answered in one sentence (can I trust the numbers; are they the numbers):
  __________________________________________________________________
- Verdict vs Cpk target 1.33 (PASS / NO): ______  If NO: lawful continuation statement
  (program proceeds to Develop with baseline certified): ____________________
