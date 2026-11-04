# Teachability Scorecard — DMEDI BB Curriculum (Lane 20, 2026-11-04)

> **SUPERSEDED (2026-11-04, RECONCILIATION lane / GAP-5 refresh):** this v1
> 43/45 CONDITIONAL PASS is superseded by
> `teachability-scorecard-v2.md` (GAP-4 remediation) — **45/45 PASS** on all
> five requirements. The v1 fails on modules 18-monte-carlo and
> 45-capstone-brief were remediated in the GAP-4 wave. Kept for audit trail.

> **SUPERSEDED** by `teachability-scorecard-v2.md` (2026-11-04 reconciliation):
> BB-20's two FAIL findings (18, 45) were re-adjudicated against the post-remediation
> tree in v2's "BB-20 reconciliation" section. Preserved verbatim below for the
> per-module evidence detail and the slides spot-check v2 does not carry.

Read-only teachability court over `modules/` (45 module dirs, 293 files, audited at
poll-stabilization ~40 min into the wave). Five requirements per module: (a) objectives,
(b) worked example with instructor derivation visible, (c) student exercise + solution
key showing derivation, (d) realistic timing estimate, (e) required-tool note.

## Receipt basis

- 33 court/key scripts executed: **33/33 exit 0** (listed below).
- 3 independent python3 re-derivations from raw CSVs (see Spot-checks).
- Per-module content reads: READMEs, labs, exercises, keys, worksheets, slides.

## Court runs (all exit 0)

modules/01..10 courts; 11 gage_rr_key; 12 capability_key; 13 score_concepts;
14/15 derive_keys; 16 derive_selection; 18 mc_bore_stack (covers 17's court);
19 court; 23/24/25 derive_keys; 26 derive_keys; 27 derive_keys; 33-44 courts.
Full list with rc=0 in session receipt; every script re-derives its module's numbers
from registered CSVs per the provenance law.

## Per-module scorecard

| Module | (a) Objectives | (b) Worked example | (c) Exercise + key | (d) Timing | (e) Tools | Verdict |
|---|---|---|---|---|---|---|
| 01-intro-dmedi | PASS | PASS (key shows verbatim re-derivation script + answers) | PASS (exercises + key; Cpk 0.94-vs-0.72 reconciliation taught) | PASS (~2 h est.) | PASS (python3 stdlib) | PASS |
| 02-define-overview | PASS | PASS (README derives DPMO/baselines) | PASS (exercises + keys/solution-key.md) | PASS | PASS | PASS |
| 03-charter-mgpp-risk-comms | PASS | PASS (3 filled charter examples, derivations shown) | PASS (worksheets + keys/solution-key.md) | PASS | PASS | PASS |
| 04-voice-of-customer | PASS | PASS (Kano compute.py re-derivation) | PASS (exercises + solution-key.md) | PASS | PASS | PASS |
| 05-qfd | PASS | PASS (QFD weights re-derived by data/compute.py, honest 4.17-um flag) | PASS (exercises + solution-key.md) | PASS | PASS | PASS |
| 06-target-costing | PASS | PASS (should-cost line-by-line derivations) | PASS (worksheets + solution-key.md, step-by-step) | PASS | PASS | PASS |
| 07-scorecards | PASS | PASS (OD-1..15, hierarchy derivations) | PASS (worksheets + solution-key.md; thin: worksheets are modeled not fill-in) | PASS | PASS (explicit no-stat-engine note) | PASS |
| 08-intro-minitab | PASS | PASS (Describe output line-by-line re-derived in key) | PASS (exercises + solution-key.md) | PASS | PASS (Minitab + python3 mirror, 40 hits) | PASS |
| 09-basic-statistics | PASS | PASS (descriptives table + CLT demo) | PASS (exercises + solution-key.md) | PASS | PASS | PASS |
| 10-variation-control-charts | PASS | I-MR/Xbar-R/p-chart arithmetic fully derived in README | PASS (exercises + solution-key.md) | PASS | PASS | PASS |
| 11-msa | PASS | PASS (gage-rr key derives EV/AV/PV/TV, ndc, kappa) | PASS (2 labs + 2 python keys) | PASS (4 h runtime) | PASS | PASS |
| 12-process-capability | PASS | PASS (Cp/Cpk from raw measurements, transform decision) | PASS (2 labs + capability_key.py) | PASS (4 h) | PASS | PASS |
| 13-concept-generation | PASS | PASS (12-card portfolio scored by score_concepts.py) | PASS (workshop + solution-key.md) | PASS | PASS | PASS |
| 14-triz-product | PASS | PASS (contradiction matrix walkthrough, cases solved step-numbered) | PASS (workshop + derive_keys.py) | PASS | PASS | PASS |
| 15-triz-transactional | PASS | PASS (2 end-to-end cases, derive_keys receipt) | PASS (workshop + derive_keys.py) | PASS | PASS | PASS |
| 16-concept-selection-pugh-ahp | PASS | PASS (Pugh + AHP on same 4 concepts, derive_selection.py rc=0) | PASS (exercises + solution-key.md) | PASS | PASS | PASS |
| 17-statistical-tolerance | PASS | PASS (WC/RSS/MC side-by-side, fully derived) | PASS w/ note (exercise + key inline in README; key = script + allocation table, no separate key file) | PASS (~90 min) | PASS (python3 + Minitab + spreadsheet equivalents) | PASS |
| 18-monte-carlo | PASS | PASS (ladder/percentiles/tornado fully derived) | **FAIL** (no student exercise; no student-facing key — walkthrough + court script only) | PASS (~80 min) | PASS (python3 + Minitab + spreadsheet) | **FAIL** |
| 19-hypothesis-testing | PASS | PASS (power curve + 1-sample t, arithmetic visible) | PASS w/ note (learner z-variant drill embedded in README; key.md keys it) | PASS | PASS (scipy-based key) | PASS |
| 20-confidence-intervals | PASS | PASS (CI-trap numeric example fully derived) | PASS w/ note (interpretation lab embedded in README §4 + key.md) | PASS | PASS | PASS |
| 21-testing-means-medians-variances | PASS | PASS (pooled-vs-Welch, paired 400x contrast, ANOVA) | PASS w/ note (learner drill embedded; key.md) | PASS | PASS | PASS |
| 22-proportion-chi-square | PASS | PASS (1-prop z, 2-prop z, chi-square GOF/independence by hand then tool) | PASS w/ learner drill embedded + key.md | PASS | PASS | PASS |
| 23/24/25 (regression, multi-vari) | PASS | PASS (OLS by hand, VIF by auxiliary regressions, variance components) | PASS (labs + exercises + derive_keys.py exit 0) | PASS | PASS | PASS |
| 26-design-fmea | PASS | PASS (12 failure modes, RPN/AP re-derived by derive_keys.py) | PASS (solution-key.md + derive_keys.py) | PASS | PASS | PASS |
| 27-detailed-design | PASS | 2 worked examples (guard-band + CP-13 thermal verify) | PASS (exercises + keys/solution-key.md) | PASS | PASS | PASS |
| 28-2way-anova | PASS | PASS (SS partition + closure to 1e-9, simple effects) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 29-intro-doe | PASS | PASS (run-count/error-df arithmetic, OFAT counterexample) | PASS (README §4 lab + keys/solution-key.md) | PASS | PASS | PASS |
| 30-full-factorial-doe | PASS | PASS (Yates effects by hand, half-normal) | PASS (README §8 lab + keys/solution-key.md) | PASS | PASS | PASS |
| 31-fractional-factorial-doe | PASS | PASS (generator/alias algebra by hand, group-closure checked) | PASS (README lab + solution-key.md) | PASS | PASS | PASS |
| 32-catapult-simulation | PASS | PASS (2^4+center points, curvature t, determinism court) | PASS (README lab + solution-key.md rc=0 courts) | PASS (2.5 h session) | PASS (seeded simulator) | PASS |
| 33-key-lean-concepts | PASS | PASS (VSM decomposition, takt/Little's Law) | PASS (lab + exercises + keys/solution-key.md) | PASS | PASS | PASS |
| 34-lean-design | PASS | PASS | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 35-dfma | PASS | PASS (teardown-based) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 36-intro-reliability | PASS | PASS (Weibull fit derivation) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 37-doe-curvature | PASS | PASS (center-point t-test + axial path) | PASS (exercises carry "### Key (derivation shown)" blocks + court) | PASS (3.5 h) | PASS | PASS |
| 38-conjoint | PASS | PASS (part-worth utilities) | PASS (3 embedded "Key (derivation shown)" blocks + court) | PASS | PASS | PASS |
| 39-mixture-designs | PASS | b_ij = 4·(y_ij − (b_i+b_j)/2) derivation | PASS (3 embedded key blocks + court) | PASS | PASS | PASS |
| 40-robust-design | PASS | PASS (S/N ratios derived dB arithmetic) | PASS (3 embedded key blocks + court) | PASS | PASS | PASS |
| 41-helicopter-rsm-lab | PASS | PASS (screening → steepest ascent → RSM) | PASS (3 embedded key blocks + court) | PASS | PASS | PASS |
| 42-prototype-pilot | PASS | PASS (pilot exit checks, lot-size derivation) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 43-process-control | PASS | PASS (control limits from 42 pilot data) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 44-implementation-planning | PASS | PASS (roadmap/training/audit/handoff derivations) | PASS (lab + keys/solution-key.md) | PASS | PASS | PASS |
| 45-capstone-brief | PASS (§8) | **FAIL** (no worked example with instructor derivation — brief is a contract; the reconciliation is directed, not demonstrated) | **FAIL** (workbook = student exercise, but no solution key; rubric/checklist is a defensible-by-design substitute, fails the stated requirement) | PASS (§9 effort per phase) | PASS (§10) | **FAIL** |

## Failing modules (fail ≥1 of five)

1. **18-monte-carlo** — (c) FAIL: no student exercise and no student-facing solution
   key; module is a walkthrough + court script. Fix: add `exercises.md` (seeded
   re-run with different stack parameters) + `keys/solution-key.md` derived from the
   same script with different seed.
2. **45-capstone-brief** — (b) FAIL: no worked example with instructor derivation
   shown (the pinned-constant reconciliation is assigned, not demonstrated);
   (c) FAIL: no solution key (workbook is prompt-only; rubric/phase-gate-checklist is
   a defensible-by-design substitute but not a key). Fix: add a worked mini-capstone
   phase (one phase demonstrated end-to-end) and/or a key for the §2.1 reconciliation
   showing the derivation.

## Course-level verdict

**CONDITIONAL PASS — 43/45 modules teachable as landed.** All five requirements PASS
in 43 modules; 2 modules fail (18, 45) on the exercise/key requirement (45 also on
worked example). Course is otherwise exceptional: 33/33 exit-checked court scripts,
provenance law enforced, adjudicated sigma (7.407 um) propagated correctly, zero
real placeholders.

## Placeholder grep

`grep -rniE 'TBD|lorem|placeholder|TODO|XXX'` over modules/ data/ datasets/ MANIFEST.md
RUNNING-CASE.md → **12 hits, 0 real placeholders.** All 12 are self-referential: courts
checking FOR placeholders (module 03 court.py, court.md), doctrine lines ("zero-placeholder
law", "UNSTATED is an honest observation, not a placeholder"). No module content carries
TBD/TODO/lorem/XXX.

## Slides check (separate spot-check, not one of five)

- 25/45 modules have slides-outline.md; **20 lack one**: 03, 06, 07, 11, 12, 13, 14, 15,
  17, 18, 19, 20, 21, 22, 28, 29, 30, 31, 32, 45. None of these use lecture-format
  delivery: 03/06/07 are worksheet-based; 11/12 lab-based; 13-15 workshop-based;
  17/18 README-walkthrough; 20-22 use the README as the lecture artifact; 28-32
  README+lab; 45 capstone.
- Existing outlines carry per-slide bullets: 22 existing outlines verified (per-slide
  headings + bullets; module 27 uses a different bullet style but has 6 bullet lines).
- Work-list item: the 20 missing outlines are consistent with those modules' alternate
  delivery formats — flag as LOW priority, not a teachability failure.

## Spot-checks (python3 re-derivation from raw CSVs)

1. **Module 01 Cpk** — CSV n=50 → mu 12.00859, s 5.82 um, sample Cpk 0.940; key derives
   pinned Cpk 0.72 from the adjudicated mu/sigma pair and teaches the 0.94-vs-0.72
   sampling-spread reconciliation. MATCHES key. PASS.
2. **Module 23** — `derive_keys.py` executed: exit 0 (all OLS numbers re-derive from
   regression-simple.csv).
3. **Module 37** — from bore-curvature.csv: fact n=16 ybar 11.590 s 3.297; center n=6
   ybar 5.390 s 2.239; s_pooled 3.067, SE 1.468, **t = 4.223 — exact match** to the
   embedded key claim. PASS.
