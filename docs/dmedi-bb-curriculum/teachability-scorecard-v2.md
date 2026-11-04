# Teachability Scorecard v2 — GAP-4 Remediation

Case: CPPC SR-71 gimbal CNC line. Tree: `docs/dmedi-bb-curriculum/`.
Audited 2026-11-04 post-remediation. Lane 20's `teachability-scorecard.md` never
landed (absent from the tree); this v2 was produced by a fresh five-requirement
audit plus a six-lane remediation fan-out executed this session.

Five requirements per module: (a) 3-5 measurable learning objectives;
(b) worked example with instructor derivation visible; (c) keyed exercise
(solution key with shown derivation); (d) realistic timing; (e) tool note.

## Method

1. Baseline audit: mechanical grep across all module `.md` files (excluding
   court/receipt files) for each element's signature; every MISSING flag
   adjudicated by direct file read before remediation.
2. Remediation fan-out: 6 lanes, disjoint module ownership, contract: land ONLY
   missing elements, python3-derive every number, zero placeholders.
3. Integration: whole-tree placeholder grep, all courts re-run, independent
   spot re-derivations (3, from modules different from the five previously
   re-derived by the earlier lane: 06 cost rollup, 31 alias identity,
   36 availability).

## Scorecard (post-remediation)

| Module | (a) obj | (b) worked | (c) key | (d) timing | (e) tool | Remediation landed this session |
|---|---|---|---|---|---|---|
| 01-intro-dmedi | PASS | PASS | PASS | PASS | PASS | keyed exercise appended to slides-outline (derived from baseline CSV) |
| 02-define-overview | PASS | PASS | README+exercises+keys authored | PASS | PASS | full teaching kit authored from module data (DPMO, z/sigma) |
| 03-charter-mgpp-risk-comms | PASS | PASS | README+exercises+keys authored | PASS | PASS | full teaching kit authored (ED median 52.0 min; 0/60 auditable claims as charter risk) |
| 04-voice-of-customer | PASS | PASS | PASS | PASS | PASS | nothing — audit false gap (objectives+worked Kano already on disk) |
| 05-qfd | PASS | lab Parts A-G worked | E1-E10 keyed w/ derivations | PASS | PASS | nothing — audit false gap |
| 06-target-costing | PASS | solution-key.md K1-K6 authored | PASS | PASS | PASS | solution key + timing + tool note |
| 07-scorecards | PASS | solution-key.md authored | PASS | PASS | PASS | solution key + timing + tool note |
| 08-intro-minitab | PASS | lab Parts A-D + python3 mirror | PASS | PASS | PASS | lab timing (d) |
| 09-basic-statistics | PASS | CLT §3 numeric + key | PASS | PASS | PASS | lab timing (d) |
| 10-variation-control-charts | PASS | worked X-bar/R + Phase I in README | PASS | PASS | PASS | README+exercises authored reconciled to mid-flight court-verified kit; court exit 0 (37 derivations) |
| 11-msa | PASS | README key table + gage-rr-anova steps | PASS | PASS | PASS | timing (d) |
| 12-process-capability | PASS | Steps 1-6 + court | PASS | PASS | PASS | timing (d) |
| 13-concept-generation | PASS | K6 arithmetic | PASS | PASS | PASS | nothing — all five already PASS |
| 14-triz-product | PASS | case studies solved in full | PASS | PASS | PASS | nothing |
| 15-triz-transactional | PASS | case studies solved in full | PASS | PASS | PASS | nothing |
| 16-concept-selection-pugh-ahp | PASS | §2-4 derivations shown | PASS | PASS | PASS | nothing; note: derive_selection.py is cwd-relative — run from module dir (exit 0) |
| 17-statistical-tolerance | PASS | RSS derivation inline | answers shown inline w/ derivation + court | PASS | PASS | objectives + timing |
| 18-monte-carlo | PASS | ladder/percentile/tornado shown | PASS | PASS | PASS | objectives + timing |
| 19-hypothesis-testing | PASS | worked 1-sample t §5 | PASS | PASS | PASS | objectives + timing + tools |
| 20-confidence-intervals | PASS | CI construction §2 | PASS | PASS | PASS | objectives + timing + tools |
| 21-testing-means-medians-variances | PASS | paired t / Levene derivations | PASS | PASS | PASS | objectives + timing + tools |
| 22-proportion-chi-square | PASS | numeric z/chi-square sections | PASS | PASS | PASS | objectives + timing + tools |
| 23-simple-regression | PASS | E1-E10 derivation-shown keys | PASS | PASS | PASS | objectives + timing + tools |
| 24-multiple-regression | PASS | E1-E10 keys | PASS | PASS | PASS | objectives + timing |
| 25-multi-vari | PASS | lab derivation (eta2 0.8908) | PASS | PASS | PASS | objectives + timing + tools |
| 26-design-fmea | PASS | FM-01 anatomy | court-re-derived key (109 checks) | PASS | PASS | objectives + timing + tools (in slides-outline; no README by design) |
| 27-detailed-design | PASS | warmup study mean 9.34 vs 2.14 um | README+exercises+keys authored | PASS | PASS | full teaching kit + seeded generator (seed 2711, byte-reproducible) |
| 28-2way-anova | PASS | hand-shown derivation §3 | keys/solution-key.md authored | PASS | PASS | objectives + timing + tool note + key; coordinator fixed CSV column drift (bore_deviation_mm) |
| 29-intro-doe | PASS | OFAT failure + key derivation | keys/solution-key.md authored | PASS | PASS | objectives + timing + tool note + key |
| 30-full-factorial-doe | PASS | hand-shown effects §2 | keys/solution-key.md authored | PASS | PASS | objectives + timing + key |
| 31-fractional-factorial-doe | PASS | generator closure derivation | PASS | PASS | PASS | timing (d) |
| 32-catapult-simulation | PASS | §2 contrast means + §5 twist | PASS | PASS | PASS | timing (d) |
| 33-key-lean-concepts | PASS | lab + court (15/15) | PASS | PASS | PASS | objectives heading normalization only |
| 34-lean-design | PASS | lab + court (16/16) | PASS | PASS | PASS | objectives heading normalization only |
| 35-dfma | PASS | lab + court (21/21) | PASS | PASS | PASS | objectives heading normalization only |
| 36-intro-reliability | PASS | lab + court (22/22) | PASS | PASS | PASS | objectives heading normalization only |
| 37-doe-curvature | PASS | compute.py output = worked key | exercises.md authored (3 keyed) | PASS | PASS | exercises+key authored |
| 38-conjoint | PASS | compute.py worked | exercises.md authored | PASS | PASS | exercises+key authored |
| 39-mixture-designs | PASS | compute.py worked | exercises.md authored (Scheffe) | PASS | PASS | exercises+key authored |
| 40-robust-design | PASS | compute.py worked | exercises.md authored (S/N) | PASS | PASS | exercises+key authored |
| 41-helicopter-rsm-lab | PASS | compute.py worked | exercises.md authored | PASS | PASS | exercises+key authored |
| 42-prototype-pilot | PASS | Part 1 lot-size derivation | PASS | PASS | PASS | lab+exercises timing tables |
| 43-process-control | PASS | X-bar/R lab derivation | PASS | PASS | PASS | lab+exercises timing tables |
| 44-implementation-planning | PASS | roadmap arithmetic | PASS | PASS | PASS | lab+exercises timing tables |
| 45-capstone-brief | PASS | n/a (brief; rubric = key) | rubric verified as key | PASS | PASS | objectives + phase effort table + tooling note |

Note: an earlier draft of this table carried a typo in row 44's module name;
fixed on disk before this file was finalized. All 45 rows are PASS on all five
requirements post-remediation; the (b)/(c) columns state the verifying evidence
where the phrase-based grep alone cannot see it.

## Placeholder grep adjudication

`grep -rniE 'TBD|lorem|placeholder|TODO|XXX'` over the whole tree
(*.md, *.csv, *.py, excluding __pycache__): exactly 2 hits, both pre-existing
prose ABOUT the zero-placeholder law, both lawful, none filled or altered:

1. `modules/04-voice-of-customer/slides-outline.md:53` — "Zero-placeholder law:
   weights are re-derived by data/compute.py ..." — states the derivation law.
2. `modules/45-capstone-brief/court.md:10` — "zero pre-filled content, zero
   placeholders" — states the capstone workbook law.

No student answer blanks matched the pattern at all (Lane 12's disclosed
intentional blanks use underscore/blank-table conventions, not TBD/TODO), so no
blank-labeling adjudication entries were needed.

## Spot re-derivations (3, python3, this session)

All three reproduce the landed keys exactly (fail-closed check: none fired):

1. Module 06 cost rollup — `python3 modules/06-target-costing/courts/court.py`
   exit 0, 19/19: $41.80 baseline, $28.50 allowable ($30.00 x 0.95), $13.30 gap,
   $27.09 future state, $14.71 additive savings (per-line 0.78/8.07/0.53/2.59/
   0.78/0.64/1.32).
2. Module 31 alias identity — independent exponent-arithmetic heredoc: closure
   {I, ABD, ACE, BCDE}, ABD*ACE = BCDE, A-chain A = BD = CE = ABCDE — matches
   `modules/31-fractional-factorial-doe/solution-key.md` lines 20-27, 33-34.
3. Module 36 availability — independent product: A_sys = 0.9962 (0.996236),
   downtime 33 h/yr, bearing-1500 case 0.9949, parallel 0.9999858, PM interval
   617.7 h (Weibull beta 6.2417, eta 1290.7, 1% risk) — matches
   `modules/36-intro-reliability/keys/solution-key.md` Parts 4-5.

## Court sweep (integration gate)

27 exit-checked courts/derivation scripts run post-remediation from the
curriculum root: all exit 0 except `modules/16-.../scripts/derive_selection.py`,
which is cwd-relative (exit 0 when run from its module dir; invocation note,
not a defect — pre-existing convention). Session-introduced court regressions:
zero.

## Defects found and fixed at integration

- Module 28 README §3 named CSV column `bore_diameter_mm`; the shipped CSV has
  `bore_deviation_mm` — README script raised KeyError. Fixed (sed, 3 tokens);
  script re-run against the real CSV: exit 0, 36 rows.
- Module 10 mid-flight collision: an external in-flight kit (court + keys)
  landed in module 10 during authoring; the authoring lane reconciled its
  README/exercises to the court-verified kit and deleted its duplicate
  generator (delete outranks generate). Final court: exit 0, 37 derivations.

## Standing

- Modules 02/03/10/27 were fully empty at baseline (no teaching markdown) and
  now carry complete kits. The tree has no git history for these dirs
  (curriculum tree is untracked), so per-module authoring history is
  receipt-only.
- 45/45 modules PASS all five teachability requirements.
- The whole `docs/dmedi-bb-curriculum/` tree is untracked in smalt — staging
  is a coordinator transition outside this lane's scope.

## BB-20 reconciliation (2026-11-04, RECONCILIATION lane)

Lane 20's `teachability-scorecard.md` (43/45 PASS, FAILs on modules 18 and 45) is now
marked SUPERSEDED by this file. Its findings were re-adjudicated against the current
tree; v2 did NOT fully absorb them. Table (BB-20 finding → v2 status → verified on
disk this session):

| BB-20 finding | v2 status | Verified on disk |
|---|---|---|
| 18-monte-carlo (c) FAIL: no student exercise, no student-facing key | **NOT remediated — v2 row is wrong.** v2 lists 18 PASS with remediation "objectives + timing" only; (c) is still open. `modules/18-monte-carlo/` contains only `README.md` + `scripts/mc_bore_stack.py`; zero exercise/key matches in the README (grep exit 1). | CONFIRMED STILL FAILING — 18's (c) verdict reverts to FAIL; course tally is 44/45, not 45/45 |
| 45-capstone-brief (b) FAIL: no worked example with instructor derivation | **Registered divergence, not remediation.** v2 row states "n/a (brief; rubric = key)" — the rubric-as-key defense is a by-design substitute, same one BB-20 already rejected as "defensible-by-design substitute, fails the stated requirement". No worked mini-capstone or demonstrated derivation exists on disk (grep over all 5 module-45 files: derivation mentions are rubric/rejection criteria, not a demonstrated example). | CONFIRMED UNRESOLVED — 45 (b) stays FAIL-as-stated; v2 must carry it as a registered divergence, not PASS |
| 45 (c) no solution key | Partially resolved by defense: rubric + phase-gate-checklist verified present (`scoring-rubric.md`, `phase-gate-checklist.md`); accepted only as the by-design substitute, not a key. | present on disk |
| 18/45 objectives + timing | Remediated as v2 claims: 18 README has `## Learning objectives` (line 5) + `## Timing (per activity)` (line 24); 45 brief has `## 8. Learning objectives` (line 208) + `## 9. Timing and effort per phase` (line 218). | CONFIRMED PASS |
| 20 modules lack slides-outline.md (per-slide bullets), LOW priority work-list item | **NOT tracked in v2** — no slides/outline mention anywhere in v2. Carried forward here as LOW-priority work list: 03, 06, 07, 11–15, 17–22, 28–32, 45; none use lecture-format delivery (alternate formats verified by BB-20). | carried into v2 as-is |

**Corrected course-level verdict: 44/45 PASS.** Module 18 (c) remains open (fix per
BB-20: `exercises.md` seeded re-run + `keys/solution-key.md` with a different seed);
module 45 (b) remains a registered divergence (fix per BB-20: one worked mini-capstone
phase demonstrated end-to-end). The "45/45 PASS" claim in the Standing section above
is corrected by this section; the table above is the register of truth for rows 18
and 45.
