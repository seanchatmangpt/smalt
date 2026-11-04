# Course Completion Receipt — DMEDI BB Curriculum (GAP-5, v2)

**Standing: ALIVE (v2)** — every count below re-measured on disk 2026-11-04 by the
RECONCILIATION lane. Subject: `/Users/sac/smalt/docs/dmedi-bb-curriculum/`.
Supersedes the v1 receipt (written mid-wave while build lanes were still
running: 14/45 COMPLETE, 21/45 courts, 6 open drift items).

## 0. Why v2

v1 was written while build lanes were still running. The v1 open items were
closed by later lanes: G1 (modules 01–03 kits), GAP-4 (45/45 remediation),
H5 (script defects), H6 (manifest consolidation), BB-18 (registry seal),
BB-19 (coherence re-audit 4/4 PASS), BB-20 (teachability 43/45, then 45/45
post-remediation per scorecard-v2). This receipt is the current state.

## 1. Verification outputs (executed this session)

- **Registry seal**: `python3 datasets/manifest_verify.py` →
  **61 PASS, 0 SKIP, 0 FAIL, exit 0** (re-run this session).
- **Executable courts**: 22 `court.py` files found under `modules/`
  (`find . -name court.py | wc -l` → 22). Ran every one:
  **22/22 exit 0, zero failures.** Modules with executable courts:
  01, 02, 03, 05, 06, 07, 08, 09, 10, 19, 33, 34, 35, 36, 37, 38, 39, 40,
  41, 42, 43, 44.
- **Bundle completeness (strict per EF-B)**: EF-B's exact bundle definition
  is not recoverable from the tree (no EF-B artifact on disk), so this lane
  operationalized it as {teaching artifact, exercises/lab/workshop, solution
  key, executable court.py, data CSV} and reports both counts honestly:
  - **Strict (all 5, executable court required): 9/45**.
  - **Functional (teaching + exercises + key; court may be key-script or
    embedded-key form): 23/45**.
  - Note: GAP-4's five-requirement teachability audit (scorecard-v2) judged
    **45/45 PASS** on (a) objectives / (b) worked example / (c) keyed
    exercise / (d) timing / (e) tool note — the teachability bundle is
    complete; the strict court+data bundle is not, and 22 executable courts
    over 45 modules remains the honest coverage number.
- **Registry bundle rows**: 23/45 modules carry a bundle row in the
  consolidated `datasets/MANIFEST.md` "Module bundles" section (H6).
- **Teachability correction (RECONCILIATION, 2026-11-04)**: the R4 lane
  re-verified module 18 and 45 on disk and found GAP-4's 45/45 claim
  **overstated**: module 18 has NO student exercise/key (README-only tree:
  README.md + scripts/mc_bore_stack.py), module 45's worked derivation is a
  registered divergence (rubric-as-key), not a fix. **Corrected verdict:
  44/45** — see the reconciliation table at the bottom of
  `teachability-scorecard-v2.md` (the register of truth for rows 18/45).
  Claims in this receipt saying 45/45 reflect GAP-4's original claim and are
  superseded by the 44/45 correction except where they describe what GAP-4
  itself reported.
  **CLOSURE (2026-11-04, post-R4)**: module 18's (c) finding is now closed —
  `modules/18-monte-carlo/exercises.md` (E1-E8) + `keys/solution-key.md`
  landed, key re-derived at seed 20261105 (registered in `datasets/MANIFEST.md`
  simulation-only seeds; manifest_verify 61 PASS exit 0; the script's default
  run at seed 20261104 is byte-identical to the registered teaching output).
  Evidence: `modules/18-monte-carlo/keys/solution-key.md`. The 44/45
  correction above stands as history; with 18 (c) closed the corrected
  teachability verdict is **45/45** (module 45 (b) remains the registered
  divergence) → superseded by §5 item 7 (45/45 zero divergences).
- **Untracked evidence**: `git status --porcelain docs/dmedi-bb-curriculum`
  → 2 entries: ` M teachability-scorecard-v2.md` (tracked, modified) and
  `?? docs/dmedi-bb-curriculum/` (the rest of the tree, untracked).
  Staging/commit is coordinator-owned.

## 2. Gap-closure timeline (what closed when)

| When | Lane | What closed |
|---|---|---|
| mid-wave | G1 | Modules 01–03 full teaching kits (README/exercises/keys/courts; courts 17/20/29 checks, all exit 0 — re-run this session) |
| 2026-11-04 | BB-18 | Registry seal: 20 → 61 registered CSVs; verifier 61 PASS / 0 SKIP / 0 FAIL |
| 2026-11-04 | GAP-4 | 45/45 teachability remediation; scorecard-v2 45/45 PASS all five requirements; fixed module-28 CSV column drift (bore_deviation_mm) |
| 2026-11-04 | H5 | All script defects fixed; all 22 court.py now exit 0 (this session's sweep confirms) |
| 2026-11-04 | H6 | Manifest consolidation: root MANIFEST.md (3 lines) → datasets/MANIFEST.md (255 lines); module-bundle index + migrated court re-run commands |
| 2026-11-04 | BB-19 | Coherence re-audit: Audits 1–4 return 4/4 PASS (see §3); drift rows D1–D9 all closed (status column added to coherence-court.md this session) |
| 2026-11-04 | BB-20 | Teachability 43/45 on the pre-remediation tree; the 2 fails (18, 45) superseded by GAP-4's scorecard-v2 45/45 |

## 3. BB-19 reconciliation (coherence-court.md)

Added a status column to `coherence-court.md`'s drift table: **D1–D9 all
CLOSED**, each with closer-lane names and the disk evidence this lane
re-checked:

- D1: no "Module 27 (one-way ANOVA)" pointer remains in module 28 README — closed by GAP-4 (M28 kit rework).
- D2/D3: modules 02/03 now carry full kits + exit-0 courts — closed by G1 (Lane 01).
- D4: M04 slides now derive spine CTQ-1 from K-01 mapping — closed by Lane 02 / GAP-4.
- D5/D6: decision-tree.md now routes two-way ANOVA (M28) and the regression F-test (M23/24) — closed by Lane 09 scope during the GAP-4 wave.
- D7: registry rows state the post-adjudication generators; pre-adjudication generator text appears only in CORRECTED notes — closed by Lane 04 / H6.
- D8: bundle index consolidated into datasets/MANIFEST.md — closed by H6 (23/45 rows; residual per-row ownership is lane-owned, see §5).
- D8b: M12 lab now names the planted 18–20 shift as the cause of the 19–20 UCL breach — closed by Lane 05/Lane 04 reconciliation during GAP-4.
- D8c: no "pending Lane 19 adjudication" text remains in module 42 — closed by Lane 16 / H5.
- D9: M05 honest-flag now reads RESOLVED with the adjudicated pair — closed by Lane 02 / GAP-4.

BB-19's bottom line ("Audits 2–4 FAIL on D1–D9") is superseded: the re-audit
returned 4/4 PASS after these rows closed.

## 4. BB-20 reconciliation (teachability-scorecard.md)

`teachability-scorecard.md` (v1, 43/45 CONDITIONAL PASS; fails on modules 18
and 45) now carries a supersession note: **superseded by GAP-4's
teachability-scorecard-v2.md, 45/45 PASS** (modules 18 and 45 remediated in
that wave; the v1 file notes Lane 20's file "never landed" per scorecard-v2's
method note — the v1 on disk is the post-hoc landed copy).

## 5. Remaining open items (each with owner)

1. **45 − 22 = 23 modules without executable courts** — owner: coordinator
   (batch court-authoring re-dispatch, or register the key-script form as the
   court of record per the registry's Court column, which already names
   `derive_keys.py`-style courts for several modules).
2. **Strict bundle 9/45** — same owner; same remediation path (executable
   court + data CSV per module).
3. **13 datasets with UNSTATED provenance** — owner: named per row in the
   registry seal (modules 01/02/03/27 lanes, Lane 14). Unchanged from v1.
4. **22/45 modules lack a registry bundle row** — owner: owning lanes
   (registry is lane-owned rows; D8's consolidation closed the index, not
   every row).
5. **`__pycache__`/`.pyc` bytecode on the tree** — owner: coordinator
   (cleanup transition before integration commit).
6. **Untracked evidence** — the whole curriculum tree is untracked in smalt
   except `teachability-scorecard-v2.md` (tracked, modified). Owner:
   coordinator. Present-locally-but-untracked fails every fresh checkout.
7. **Module 45 (b) worked-derivation divergence** — ~~OPEN~~ **CLOSED
   (2026-11-04, module-45 lane)**: `modules/45-capstone-brief/worked-example-measure.md`
   landed with executed derivations (%GRR 13.97/ndc 9; Cpk 0.72 at sigma_within
   7.407 um); registered divergence cleared; 45/45 with zero registered
   divergences. Appended here per closure law — history kept, not rewritten.

## 6. 429-casualty history

Per v1 (§7), unchanged and still honest: no receipt in `receipts/` records a
429 death; this lane has no direct observation of a 429 kill. What is
directly observed: heavy mid-flight churn during the GAP-1..4 waves (files
landing 11:38–12:05), two courts red-then-green (modules 08, 37), one CSV
deleted mid-poll (62→61), one lane-dropped manifest rewrite recovered by
Lane 02, and scorecard-v2's statement that Lane 20's scorecard "never landed"
— a casualty-shaped absence whose cause (429 or dispatch order) is not
recorded on disk. Any 429 history lives in coordinator session context, not
in the tree.

## 7. EXIT CODE

Open items in §5 all carry named owners, but the completeness/court-coverage
gaps are real and re-measured: **EXIT CODE: 0** (honest-fail on strict
completeness, exit-0 on ownership accountability — same grammar as v1).

Subject tree: 45 modules; 61/61 registered datasets PASS; 22/22 executable
courts exit 0; D1–D9 closed; teachability 44/45 as of the 2026-11-04 R4
reconciliation (module 18 exercise/key still open at that time, module 45
divergence registered) — **superseded to 45/45** by the post-R4 closure of
module 18 (c): exercises.md + keys/solution-key.md re-derived at seed
20261105, evidence `modules/18-monte-carlo/keys/solution-key.md`; the 44/45
line above is kept as the history of the correction.
