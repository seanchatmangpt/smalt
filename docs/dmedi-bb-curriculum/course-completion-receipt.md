# Course Completion Receipt — DMEDI BB Curriculum (GAP-5)

Standing: **ALIVE** — every count below was re-measured on the quiescent tree
(2026-11-04, ~12:25) by this lane, not recalled from earlier reads. Subject:
`/Users/sac/smalt/docs/dmedi-bb-curriculum/`.

## 0. Poll-wait outcome

Polled ~28 min (120 s interval, 35 min cap inside a 60 min budget) for
`teachability-scorecard-v2.md` and GAP-1/2/3/4 outputs. **The scorecard never
appeared.** Fail-closed: proceeded on the tree AS IT IS. The tree was not
static during the wait — CSV count moved 56 → 62 → 61 and the module-08,
module-27, module-44 artifacts landed mid-poll; all counts below are from the
post-quiescence state.

## 1. Registry seal (datasets/MANIFEST.md)

- CSVs on disk: **61** (`find . -name '*.csv'` from the curriculum root).
- Registered before seal: **20** (verified green pre-seal:
  `python3 datasets/manifest_verify.py` → 20 PASS, 0 SKIP, 0 FAIL, exit 0).
- **Sealing correction: 41 CSVs were on disk but unregistered** — fail-closed
  condition confirmed and repaired by appending, for each: a full sha256 line
  to the manifest checksum block and a provenance row to the new
  "Registry seal (GAP-5, 2026-11-04)" section of
  `datasets/MANIFEST.md` (path, sha256-12, rows, seed/generator or explicit
  `UNSTATED on disk` + named owner).
- Post-seal verifier: **61 PASS, 0 SKIP, 0 FAIL, exit 0** (re-run after write,
  on disk).
- Shared-dataset byte-identity: all 61 hashes unique except **three
  byte-identical pairs**: `data/regression-simple.csv` ≡
  `modules/23-simple-regression/data/regression-simple.csv`;
  `data/regression-multi.csv` ≡ `modules/24-multiple-regression/data/regression-multi.csv`;
  `data/multivari-bore.csv` ≡ `modules/25-multi-vari/data/multivari-bore.csv`.

## 2. Module completeness vs 45/45

Executable courts (exit-checked, run by this lane this session):

```
for c in $(find modules -name 'court*.py'); do python3 "$c"; done
```

**21/45 modules have exit-checked courts, all 21 green (exit 0)** on the final
tree: 01, 02, 05, 06, 07, 08, 09, 10, 19, 33, 34, 35, 36, 37, 38, 39, 40, 41,
42, 43, 44. Two of these were RED on an earlier mid-flight read (module 08:
"no_bore_outside_spec: derived False, key claims True"; module 37: TypeError
in court) and were repaired by their owning lanes before quiescence — the
final state is green for both.

Completeness tiers (all flags re-checked on the final tree):

- Teaching artifact (README.md or slides-outline.md): **45/45**
  (module 45's teaching artifact is capstone-brief.md).
- Solution-key artifact (solution-key.md / key.md / keys/ with key content):
  **42/45** — missing in **17-statistical-tolerance** and
  **18-monte-carlo** (README + scripts only; Lane 08's receipt lists no key
  files beyond READMEs), and **45-capstone-brief** (capstone docs + court.md,
  no key).
- Exit-0 executable court: **21/45** (list above). 24 modules carry only
  markdown courts (court.md) or none — not exit-checked, so not counted green.

**Verdict: NOT 45/45 complete.** Every incomplete module, named, with missing
artifacts + owner:

| Module | Missing | Owner |
|---|---|---|
| 17-statistical-tolerance | solution key, executable court | Lane 08 / coordinator re-dispatch |
| 18-monte-carlo | solution key, executable court | Lane 08 / coordinator re-dispatch |
| 45-capstone-brief | solution key, executable court | coordinator / capstone lane |
| 03-charter-mgpp-risk-comms | executable court (key exists; no court.py) | module 03 lane / coord |
| 04, 13, 16, 20-22, 26-32 | key + court.md exist; no court.py | coordinator |
| 11-msa, 12-process-capability | key scripts exit 0; no court.py | Lane 05 / coord |
| 14, 15 | executable court (derive_keys.py exists; no court.py) | Lane 06 / coordinator |

## 3. Datasets registered

**61/61** post-seal (20 pre-existing + 41 sealing corrections; verifier
61 PASS / 0 SKIP / 0 FAIL, exit 0). Provenance quality: 48 carry a stated
seed or deterministic-generator statement; **13 carry `UNSTATED on disk`**
(modules 01/02/03/27 CSVs + authored Lane 14 tables) — each named in the seal
table with its owning module/lane as the responsible supplier.

## 4. Keys re-derived (cumulative, by source)

- This lane's final court sweep: **21 courts exit 0**, printing derivation
  counts where the court states them: M01 17 checks, M02 20, M08 3 dataset-regens
  + 24 numeric, M09 1 + 16, M10 3 + 37, M33 15, M34 16, M35 21, M36 22,
  M37–M41 "0 failures" (full derivation suites), M42 (lot-size, capability,
  stability, Ra, scrap binomial, generator determinism), M43 (limits, sigma-hat/PCR,
  p-chart, day-1 signal, wrong-constants mutation), M44 (roadmap arithmetic,
  7/7 checklist, 20 slots, cross-module replays). Plus module 05 QFD court and
  modules 06/07 courts (19/19, 21/21 per root MANIFEST).
- Lane 05 receipt: 3 key scripts exit 0 (gage R&R %GRR 13.97/ndc 9; attribute
  kappas; capability Cpk 0.7200 spine court).
- Lane 08 receipt: generator exit 0 + independent stdlib-only court
  re-derivation (P0.13/P50/P99.87, Cpk 1.588, tornado, allocation WC 24.000).
- Lane 14 receipt: 4 courts, **74 derivations** (15+16+21+22) all match key.
- Court-caught authoring defects (receipted by Lane 14): takt 1.86→1.85,
  breakeven 0.86→1.86 d, after-count 16→17, availability 0.9999856→0.9999858.

## 5. Courts green

**21/21 executed courts exit 0** (final tree). Court coverage gap (no
executable court in 24 modules) is the module-completeness open item in §2,
not a red court.

## 6. Drift-table items: closed vs open

CLOSED (evidence on disk):

1. **Spine pinned-sigma contradiction** (Lane 05 finding: sigma 4.17 um vs
   pinned Cpk 0.72) — ADJUDICATED to sigma 7.407 um; RUNNING-CASE carries the
   adjudication note; stale artifacts regenerated post-adjudication
   (BB-04r/BB-07r/BB-10r-2 rows in the manifest) and module 08's court (red
   pre-adjudication on my first run) is green on the final tree.
2. **xbar-r-subgroups shift drift** (Lane 05 observed a mid-flight shift at
   subgroups 19–20) — CLOSED as intentional: seed 42011 plants a +0.015 mm
   shift in subgroups 18–20, declared in Module 10 README and the manifest row.
3. **Manifest row loss in concurrent rewrite** — CLOSED: Lane 02 recovered the
   dropped rows with a CORRECTED note; my seal preserved all rows.

OPEN (each with named owner):

1. **Modules 17/18 missing keys+courts** — owner: Lane 08 / coordinator.
2. **Module 45 missing key+court** — owner: coordinator / capstone lane.
3. **24 modules without executable courts** — owner: coordinator
   (batch court-authoring re-dispatch).
4. **13 datasets with UNSTATED provenance** — owner: named per row in the
   registry seal (modules 01/02/03/27 lanes, Lane 14).
5. **teachability-scorecard-v2.md never produced** — owner: GAP-1..4 lanes /
   coordinator.
6. **Python bytecode artifacts committed to the tree** (`__pycache__`,
   `.pyc`) — owner: coordinator (cleanup transition before integration commit).

## 7. 429-casualty history

Not recorded on disk: no receipt in `receipts/` (lane-05, lane-08, lane-14)
records a 429 death, and this lane has no direct observation of any lane
dying with status 429. What this lane observed directly: heavy mid-flight
churn while GAP-1..4 lanes were landing (files landed at 11:38–12:05), two
courts red-then-green (modules 08, 37), one CSV deleted mid-poll (62→61), and
one lane-dropped manifest rewrite recovered by Lane 02. Any 429 history lives
in coordinator session context, not in the tree.

## 8. UNTRACKED-EVIDENCE note (verbatim)

`?? docs/dmedi-bb-curriculum/` — in smalt git status, the entire curriculum
directory is untracked. Staging and commit are coordinator-owned; GAP-5 made
no git transitions.

## 9. EXIT CODE

Every open item in §6 carries a named owner, so per the GAP-5 exit condition:

**EXIT CODE: 0**

(Not 45/45 complete and not fully court-covered — those are owned open items,
not ownerless ones. The receipt is honest-fail on completeness, exit-0 on
ownership accountability.)
