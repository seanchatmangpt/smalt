# Course Completion Receipt — DMEDI BB Curriculum (GAP-5, v3)

**Standing: ALIVE** — every count below re-measured live on disk 2026-11-04 by the
IMPLEMENT lane (single session, single tree). Subject:
`/Users/sac/smalt/docs/dmedi-bb-curriculum/`. Supersedes v2 (which was written
from the authoring waves' own claims and carried their mid-wave counts: 22
courts, strict bundle 9/45, registry 61 rows).

## 0. Why v3

v2's counts were measured before the final authoring waves (D54/D55) landed
and went stale within the session: the executable-court count moved 22 → 38
(thin court.py wrappers for 16/23/24/25/26/27, then the D54/D55 court wave),
the strict bundle moved 9/45 → 28/45, the registry moved 61 → 111 rows
(dataset rows + module bundles), and the bundle index moved 23/45 → 45/45.
This receipt re-measures everything live and carries only numbers executed in
this session's transcript.

## 1. Live verification outputs (executed this session, 2026-11-04)

| Check | Command | Result |
|---|---|---|
| Modules | `ls modules \| wc -l` | **45** |
| exercises.md coverage | `find modules -name exercises.md \| wc -l` | **45** |
| Executable courts | `find modules -name court.py \| wc -l` | **38** |
| Court runs | every `court.py` executed | **38/38 exit 0** (per-court exits in the transcript; mutation courts flip exit 1 under mutation and restore byte-exact, as required) |
| Court-less modules | census | **7**: 04, 11, 13, 14, 15, 18, 29 |
| Keys census | `find modules -type d -name keys` + `solution-key.md` | 30 `keys/` dirs, 40 top-level `solution-key.md` files; **45/45 modules carry a key artifact** |
| UNSTATED provenance | `grep -rn UNSTATED modules` | **0 matches** |
| Bundle rows | `awk '/## Module bundles/,0' datasets/MANIFEST.md \| grep -c '^| [0-9]'` | **45/45 modules registered** |
| Registry rows (total) | `grep -c '^| ' datasets/MANIFEST.md` | 111 table rows |
| `__pycache__` | `find . -name __pycache__ \| wc -l` | **0** |
| Registry seal (at Step-A measurement) | `python3 datasets/manifest_verify.py` | 60 PASS, 0 SKIP, 1 FAIL, exit 1 — see §1a |
| Registry seal (FINAL gate, pre-commit) | `python3 datasets/manifest_verify.py` re-run after the rename wave landed (dd713577) | **61 PASS, 0 SKIP, 0 FAIL, exit 0** |
| Teachability | `teachability-scorecard-v2.md` closure table | **45/45 PASS, zero registered divergences** (18 (c) closed: exercises E1-E8 + key re-derived seed 20261105; 45 (b) closed: `worked-example-measure.md`, %GRR 13.97 / ndc 9 / Cpk 0.72 re-executed exit 0) |
| Git state | `git status --porcelain docs/dmedi-bb-curriculum` | 11 modified tracked files — all in-flight column-rename wave-2 edits (m27/31/37/40 data+compute+courts+keys); zero untracked files |

### 1a. Registry seal — transient FAIL during measurement, green at the final gate

Step A measured `manifest_verify.py` → 60 PASS / **1 FAIL**:
`modules/27-detailed-design/data/thermal-warmup-study.csv` (recorded
`72e8b261…`, on-disk `81061026…`). The FAIL traces to the **uncommitted
in-flight column-rename wave** (`bore_dev_um` → `bore_deviation_um`): m27's
`gen_verification_dataset.py` was edited (header rename) and the CSV
regenerated before the registry row was re-sealed. Evidence this is not a
landed-state defect: the recorded hash `72e8b261…` equals `git show
HEAD:…/thermal-warmup-study.csv` sha256 exactly (executed this session), so
the seal is green at HEAD (f840a8a2) and red only against the working tree.
**CLOSED before this receipt's commit**: the rename wave landed as dd713577
(column law wave 2, re-sealed) while this receipt was being written; the
final pre-commit `manifest_verify.py` re-run returned **61 PASS / 0 FAIL,
exit 0**. This lane owns only this receipt file and did not touch the
in-flight files.

## 2. Consolidated wave timeline (seven rows, history kept not rewritten)

| When | Lane | What closed |
|---|---|---|
| 2026-11-04 | G1 | Modules 01–03 full teaching kits (courts 17/20/29 checks, re-run exit 0 this session) |
| 2026-11-04 | BB-18 | Registry seal: 20 → 61 registered CSVs; verifier all-PASS exit 0 at that wave's close |
| 2026-11-04 | GAP-4 | 45/45 teachability remediation; scorecard-v2 authored; M28 column drift fixed |
| 2026-11-04 | H5 | All script defects fixed; court sweep green at that wave's count (22) |
| 2026-11-04 | H6 | Manifest consolidation: root MANIFEST.md → datasets/MANIFEST.md; bundle index 23/45 rows |
| 2026-11-04 | BB-19 / BB-20 | Coherence re-audit 4/4 PASS (D1–D9 closed); teachability 43/45 → superseded by scorecard-v2 |
| 2026-11-04 | D54 / D55 | aaf6b18b (45/45 exercises) + e027dbaf re-seal + thin-court wrappers; courts 22 → 38; strict bundle 9/45 → 28/45; bundle rows 23/45 → 45/45 |

## 3. Teachability (carried, not re-derived)

`teachability-scorecard-v2.md` is the register of truth for the five-
requirement audit. Its closure table records: **45/45 PASS, zero registered
divergences** at modules 18 and 45 (both closure notes carry executed
evidence). History pointer, kept per closure law: **44/45 → 45/45** (R4
reconciliation found 18 (c) open and 45 (b) a registered divergence; both
closed post-R4; the 44/45 correction stands as history in scorecard-v2 §Reconciliation).

## 4. v2 supersessions

v2's open items, resolved by later waves (verified this session):

- 22/23 modules without executable courts → **7 court-less** (§1).
- Strict bundle 9/45 → **28/45** (§1).
- 13 UNSTATED datasets → **0 UNSTATED matches** (§1).
- 22/45 modules lacking a bundle row → **45/45 rows** (§1).
- `__pycache__` on tree → **0** (§1).
- Untracked evidence → tree fully tracked at HEAD f840a8a2; the only
  working-tree entries are the 11 in-flight rename-wave files (§1a).

## 5. True residuals (owners named)

1. **Strict bundle 28/45** — 17 modules missing at least one of
   {exercises/lab, key, executable court, data CSV} (census in §1; the 7
   court-less modules are 04, 11, 13, 14, 15, 18, 29). Owner: coordinator
   (court-authoring re-dispatch or register the key-script court of record).
2. **In-flight working-tree edits** — 11 rename-wave files were in flight at
   Step A; they landed as dd713577 before this receipt's commit (§1a). No
   untracked files; working tree clean at commit time.

## 6. 429-casualty history

Unchanged from v2 (§6), still honest: no receipt in `receipts/` records a
429 death; heavy mid-flight churn was observed during the GAP waves. Carried
verbatim; no new observation this session.

## 7. EXIT CODE

Re-derived from §1: **EXIT 0**. The one red gate observed at Step A
(manifest_verify 1 FAIL, §1a) was working-tree-transient — the recorded hash
equaled the HEAD blob hash (executed evidence in §1a) — and the rename wave's
re-seal landed (dd713577) before this receipt's commit; the FINAL pre-commit
gate returned **61 PASS / 0 SKIP / 0 FAIL, exit 0**. The residual list is
exactly §5 (strict bundle 28/45, registered).

**Subject tree (landed, HEAD f840a8a2)**: 45 modules; 45/45 exercises.md;
38/38 executable courts exit 0; 45/45 bundle rows; 0 UNSTATED; 0
`__pycache__`; teachability 45/45 zero divergences; strict bundle 28/45
(§5.1 registered residual). History pointer kept: **44/45 → 45/45** (see §3).
