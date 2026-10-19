# i29 Checkpoint 7 — census at HEAD 2e0b9b2

- Subject: /Users/sac/smalt @ `2e0b9b2` (parent `83d3052`; coordinator landed TWO commits mid-census: `83d3052` budget-final2 and `2e0b9b2` azb-20 verification)
- Context: solo(census; read-only git; no git mutations)
- Census time: 2026-10-19 ~00:30-00:40 PDT
- Commands: `git status --porcelain` (fresh, mid-census), `git log --oneline -5`,
  `git diff --stat`, `git log -1 -- <paths>`, `git ls-files docs/jira/v26.10.18/burn/`,
  `stat -f '%Sm'` mtime sweep, per-receipt `grep -l` attribution, `wc -c` on candidate
  receipts, full read of `i29-budget-reseed.md` / `i29-budget-final2.md` /
  `i29-static-gates-pregate2.md` / `i29-stress-pregate.md` / `i29-azb20-verify.md` /
  the azb-18-cgroup-soak addendum diff.

## Mid-census drift (two coordinator commits, neither mine)

- `83d3052` docs(receipts): budget final2 — landed `i29-budget-final2.md` (gate PASS
  0/0/0 + 4 flake faces classified) plus, previously, `i29-budget-reseed.md` and
  `i29-static-gates-pregate2.md` (commit-check via `git log -1 -- <paths>`: all three
  carried by 83d3052/2e0b9b2 ancestry).
- `2e0b9b2` docs(receipts): azb-20 verification — landed `i29-azb20-verify.md`
  (PARTIAL_ALIVE: cosmos bulk partition-key cell CLOSED on a 20-probe witness, 500 tests
  0 failures on the gap-fix tree; 4 cells root-caused to plane mounting, still OPEN).
  The receipt explicitly states the gap-fix landing receipt (`azb-20-gap*` /
  `i29-azb20-fix`) has NOT landed — the lib diffs remain lane-hot.

## Working tree at close: 24 modified + 5 untracked, +1055/-98 vs HEAD

## Per-group census

### (a) COMMIT-READY — receipt-backed NOW (5 paths)

| Path | Backing receipt (all landed) |
|---|---|
| `docs/jira/v26.10.18/receipts/azb-18-cgroup-soak.md` (M, +81) | self-backing addendum: AZB-18 container leg EXECUTED for real, verdict RED (data 2740 tests/44 fail, identity ~45 fail under 2g; control/integration OOM at mem=1g and 2g; gate STANDING_REFUSED over 4 dirty rows; STAGED→ALIVE flip NOT earned). Backs `docker/burn/compose.cgroup.yml` (committed 99f3264). |
| `docs/jira/v26.10.18/receipts/i29-stress-pregate.md` (untracked, 2461 B) | self: stress pre-gate PASS — run 2 warm `mix test --include stress` 2778 tests, 0 failures, exit 0; prior deterministic StoreTables/EtsComposite faces GONE; cold run 1's 7 failures uncaptured/LOAD-class noise. |
| `docs/jira/v26.10.18/test_budgets.json` (M, +2/-1) | `i29-budget-reseed.md` (ADOPTED, 2748/0/0 gate PASS, fixtures refuse) + `i29-budget-final2.md`. Diff = one tier flip (FuzzTest multi-frame lens-3 default→stress, max_ms 10727), consistent with the stress-lane classification the landed receipts describe. |
| ~~`i29-court-x2-final.md`~~ | **EXCLUDED: 0 bytes** (placeholder, mtime Oct 18 23:54). A zero-byte receipt satisfies path-existence checks while carrying zero evidence. Fill from the court-x2 run or delete before wrap. |

Group (a) commit-ready: 4 paths + this receipt.

### (b) Lane-hot — EXCLUDE (receipt unlanded / still-active lanes)

- **azb-20 lib diffs (8 paths)**: `lib/smalt/arm_gateway/router.ex`,
  `blob_storage.ex`, `cosmos.ex`, `key_vault_actions.ex`, `egress_router.ex`,
  `connection.ex`, `queue_store.ex`, `store_tables.ex` + `test/sdk-full/blob.probe.mjs`
  (pinion-flip subject, commits only with an `azsim-sdk` witness per checkpoint6 law).
  `i29-azb20-verify.md` verifies but does NOT land them; gap-fix receipt absent.
- **G1 queue_storage**: `lib/smalt/data_plane/queue_storage.ex`,
  `test/data_plane/queue_storage_test.exs` — scoping receipt only
  (`i29-g1-scoping.md`), no landing receipt.
- **e2e s2/s5/s9/s10 (7 paths incl. untracked `s2_run.patch.py`)**: backing receipt
  `i29-e2e-fixes.md` still ABSENT; `sessions.test.cjs` 00:18:44 postdates every receipt.
- **Re-dirtied support/test files (4 paths, mtime 00:25:26)**:
  `test/support/env.ex`, `test/support/isolation_formatter.ex` — re-dirtied AFTER
  checkpoint6 recorded their first edit as withdrawn; no receipt names the new edits
  (grep over the four newest receipts: rc=1). Attribution UNKNOWN, lane-hot, exclude.
- `test/amqp/sas_verifier_test.exs`, `test/canonical_projection_test.exs` — same
  signature, no landing receipt names them as landed work.

### (c) Unattributed / scratch — EXCLUDE

- `docs/jira/v26.10.16/sdk-results/spc-bands.md` (M, 00:27:25) — still no receipt names
  the edit (prior-window doc; checkpoint5 G5 finding unchanged). mtime is now NEWER than
  `i29-azb20-verify.md` — refresh continued after the last landing.
- `.ggen_igniter/manifest.json`, `.ggen_igniter/receipts/2026-10-19.jsonl` — ggen
  runtime scratch (00:23:49 / 00:23:55). Prior checkpoints' verdict unchanged.

### (d) Already clean — confirmed tracked & committed

- `docker/burn/compose.cgroup.yml` (99f3264), `scripts/naming_sweep.sh` (ef073c1),
  all 5 `docs/jira/v26.10.18/burn/cgroup-*.jsonl` run receipts (tracked, clean).
- Receipts committed mid-census: `i29-budget-reseed.md`, `i29-static-gates-pregate2.md`,
  `i29-budget-final2.md` (83d3052), `i29-azb20-verify.md` (2e0b9b2).

## Commit-ready `git add` line for the coordinator

```
git add docs/jira/v26.10.18/receipts/azb-18-cgroup-soak.md \
        docs/jira/v26.10.18/receipts/i29-stress-pregate.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint7.md \
        docs/jira/v26.10.18/test_budgets.json
```

(4 files + this receipt. Everything in (b)/(c) stays on the tree for its owning lane.)

## Falsifiers

- `git status --porcelain` after the coordinator's `git add` of group (a) must show
  exactly the (b)/(c) residue: 20 M + 4 ?? (incl. the 0-byte court-x2-final placeholder).
- `just docs-dod-check` must stay green with this receipt on disk (every receipt path
  named here exists — verified by `wc -c` at census time).

---

## Addendum 2026-10-19 00:40 PDT — census refresh at HEAD 5075e89

- Subject: /Users/sac/smalt @ `5075e89` (parent `4d6d8af`, which landed group (a) of the
  base census: azb-18-cgroup-soak.md, i29-stress-pregate.md, i29-checkpoint7.md,
  test_budgets.json; 5075e89 regen'd the receipt index)
- Context: solo(census; read-only git; no git mutations)
- Commands: `git status --porcelain` (fresh), `git diff --stat` (+1199/-122, 25 files),
  `git log -1 -- <paths>`, `stat -f '%Sm %z'` mtime sweep, `grep -l` attribution over
  `docs/jira/v26.10.18/receipts/*.md`, `wc -c` on the court-x2-final placeholder,
  fresh re-verification `MIX_BUILD_ROOT=_build-ft-g1c mix compile && mix test
  test/data_plane/queue_storage_test.exs` on the current tree.

### Mid-census landing (00:37, after the base census): `i29-g1-land.md`

**Landed mid-census — absent at 00:36, on disk 00:37:00 (7051 B), ALIVE, Context: pair.**
This resolves the base census's G1 blocker ("scoping receipt only, no landing receipt"):

- Backs `lib/smalt/data_plane/queue_storage.ex` (577-line engine, tuple contract),
  `test/data_plane/queue_storage_test.exs` (11 engine tests), `test/wire/
  egress_wire_test.exs` (+159, 4 wire pins), `test/store_tables_replay_identity_test.exs`
  (fence re-baseline 33→35 rows).
- Names `lib/smalt/egress_router.ex` (queue plug arm BEFORE the blob splat, azb-20
  hunks verified intact) and `lib/smalt/store_tables.ex` (+22 lines via `mix smalt.gen`
  from 2 new StoreTable individuals in the ggen-marketplace pack — cross-repo edit
  disclosed in the receipt).
- Verification embedded: engine 11/0 x2, wire 26/0 x2, regression sweep 482/0 and
  4/0. Independent re-witness this census (00:38, current tree incl. the 00:34 lib
  edit that postdates i29-g1-test-verify.md): `mix compile` exit 0, `11 tests,
  0 failures` on `_build-ft-g1c` (build root deleted after).
- `i29-g1-test-verify.md` (00:30, untracked) is the earlier independent verify lane's
  receipt; the 00:34 land-lane fix-forward edits postdate it, superseded by
  i29-g1-land.md + the re-witness above. Include both receipts.

### Commit-ready set for the next coordinator commit

> **SUPERSEDED 2026-10-19 00:5x: the coordinator landed mid-census faster than this
> census wrote.** G1 committed as `73dc1a2`, e2e harness fixes as `fafcbb7`, sweep as
> `8b4f74f`, index regen as `5dbcb42` — every `git add` line below is already
> committed; do not re-add. Current truth is the later addendum in this same file
> (kept as a historical snapshot of the tree at 00:40) plus the correction below.

**G1 group — INCLUDE (receipt i29-g1-land.md ALIVE; green x2 + re-witnessed).**

```
git add lib/smalt/data_plane/queue_storage.ex \
        test/data_plane/queue_storage_test.exs \
        test/wire/egress_wire_test.exs \
        test/store_tables_replay_identity_test.exs \
        lib/smalt/egress_router.ex \
        lib/smalt/store_tables.ex \
        docs/jira/v26.10.18/receipts/i29-g1-land.md \
        docs/jira/v26.10.18/receipts/i29-g1-test-verify.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint7.md
```

**Seam disclosure (coordinator decision point):** `egress_router.ex` and
`store_tables.ex` are dirty with BOTH lanes' hunks — G1's (receipted, ALIVE) and
azb-20's (gap-fix receipt still absent per i29-azb20-verify.md). Committing the G1
group necessarily lands the azb-20 hunks in those two files; i29-g1-land.md §2
witnesses the azb-20 hunks intact. Excluding the two shared files instead would
commit the fence re-baseline test against a 33-row `store_tables.ex` and break the
replay-identity fence on the committed tree — the atomic G1 group above is the
coherent unit. `lib/smalt/arm_gateway/router.ex`, `blob_storage.ex`, `cosmos.ex`,
`key_vault_actions.ex`, `connection.ex`, `queue_store.ex`, `test/sdk-full/blob.probe.mjs`
remain azb-20-lane-hot: EXCLUDE (checkpoint6 law: blob.probe.mjs commits only with an
`azsim-sdk` witness; azb-20 gap-fix landing receipt still absent).

**EXCLUDE — receipt absent (e2e lane):** `test/e2e/s2_byok/*` (incl. untracked
`s2_run.patch.py`), `s5_sessions/sessions.test.cjs`, `s9_lro_chain/lro_chain.test.mjs`,
`s10_attest_adversary/*`. `i29-e2e-fixes.md` still does not exist (checked twice:
00:36, 00:40); `s10 run.sh` re-dirtied 00:34:19, after every receipt.

**EXCLUDE — re-dirtied post-commit, unattributed:** `docs/jira/v26.10.18/test_budgets.json`
(mtime 00:32:44; committed in 4d6d8af at 00:31, re-dirtied after; new diff adds max_ms
entries + raises stress maxes — reseed-regen shaped, but no receipt after 00:31 names
it; grep rc=1 over the newest receipts).

**EXCLUDE — unattributed/scratch (unchanged from base census):**
`docs/jira/v26.10.16/sdk-results/spc-bands.md` (mtime now 00:34:44, still newer than
every receipt), `.ggen_igniter/manifest.json`, `.ggen_igniter/receipts/2026-10-19.jsonl`.

**Receipt-backed but already committed (test-support lane):** `test/support/env.ex`,
`test/support/isolation_formatter.ex`, `test/amqp/sas_verifier_test.exs`,
`test/canonical_projection_test.exs` — now attributed to the LANDED
`i29-true-leak-repair.md` (00:35, committed; measured 6→0 counted-leak repair naming
all four files). The files remain dirty on the tree though the receipt is in: they
belong in the commit-ready set.

```
git add test/support/env.ex \
        test/support/isolation_formatter.ex \
        test/amqp/sas_verifier_test.exs \
        test/canonical_projection_test.exs
```

**Still broken:** `i29-court-x2-final.md` remains 0 bytes (checked 00:40). Fill from
the court-x2 run or delete before wrap — a zero-byte receipt passes path-existence
checks while carrying zero evidence.

### Full addendum commit-ready block (one shot)

```
git add lib/smalt/data_plane/queue_storage.ex \
        test/data_plane/queue_storage_test.exs \
        test/wire/egress_wire_test.exs \
        test/store_tables_replay_identity_test.exs \
        lib/smalt/egress_router.ex \
        lib/smalt/store_tables.ex \
        test/support/env.ex \
        test/support/isolation_formatter.ex \
        test/amqp/sas_verifier_test.exs \
        test/canonical_projection_test.exs \
        docs/jira/v26.10.18/receipts/i29-g1-land.md \
        docs/jira/v26.10.18/receipts/i29-g1-test-verify.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint7.md
```

### Falsifiers (addendum)

- Post-add `git status --porcelain` residue must be exactly: the 6 azb-20 lib/probe
  paths, the 7 e2e paths, `test_budgets.json`, `spc-bands.md`, 2 `.ggen_igniter`
  paths, and the 0-byte `i29-court-x2-final.md` — 17 paths, nothing else.
- `just docs-dod-check` green with this addendum on disk.
- `just test-budget` is expected to REFUSE until the 00:32:44 `test_budgets.json`
  re-dirty is either receipted and committed or reverted by its owner — that is the
  gate working, not a regression.

---

# Addendum 2 — re-census at HEAD 73dc1a2 (2026-10-19 ~00:40-00:47 PDT; Context: solo)

- Subject: /Users/sac/smalt @ `73dc1a2` (G1 queue storage landed mid-census). Prior
  addendum's tree is stale: coordinator landed `3360a9b` (corpus re-soak),
  `0ec0c50`/`5b23ad8` (settle lane), `73dc1a2` (G1) during the re-census window.
- Method: two `git status --porcelain` + `stat` mtime samples ~180 s apart (lane-edit
  movement check); `git log --oneline -5`; `git log -1 --name-only`; `git ls-files`;
  `git diff` reads; head/full reads of new receipts.

## Mid-census drift

- `4d6d8af` landed prior addendum's group (a): `azb-18-cgroup-soak.md`,
  `i29-stress-pregate.md`, `test_budgets.json` (tier-flip version), and this receipt.
- `73dc1a2` landed G1: `lib/smalt/data_plane/queue_storage.ex`,
  `test/data_plane/queue_storage_test.exs`, `egress_router.ex`, `store_tables.ex`,
  `egress_wire_test.exs` + receipts `i29-g1-land.md` / `i29-g1-test-verify.md`.
  `s2_run.patch.py` untracked scratch deleted by its lane.
- Re-dirtied after landing: `test_budgets.json` (+80/-lines: new/raised `max_ms` for
  EnclaveDoctor / WasmEngine fences / AtomBridge stress — budget-lane reseed shape,
  same pattern as `i29-budget-reseed`), no NEW receipt names this reseed.

## Fresh census: 16 M + 2 untracked, +741/-93

### (a) COMMIT-READY — receipt-backed NOW (7 paths)

| Path | Backing receipt |
|---|---|
| `docs/jira/v26.10.18/receipts/i29-e2e-fixes.md` (??, 7030 B) | self-backing, ALIVE: s2/s5/s9/s10 all exit 0 ×2, embedded run logs; 7 KV-corpus harness defects fixed test-side (KD-15 handshake, api-version pin, base64url), emulator untouched. |
| `test/e2e/s2_byok/byok.test.mjs`, `test/e2e/s2_byok/run.sh` | i29-e2e-fixes.md (defect 1: MIX_ENV + KD-15 handshake + api-version 7.x + WORM-409 tolerance) |
| `test/e2e/s5_sessions/sessions.test.cjs` | i29-e2e-fixes.md |
| `test/e2e/s9_lro_chain/lro_chain.test.mjs` | i29-e2e-fixes.md (defect 2: 202 LRO assertion fix) |
| `test/e2e/s10_attest_adversary/adversary.py`, `test/e2e/s10_attest_adversary/run.sh` | i29-e2e-fixes.md (defect 1 items 3-5: valid release policies, base64url) |
| `docs/jira/v26.10.18/receipts/i29-checkpoint7.md` (this file, addendum) | self-census receipt |

### (b) Lane-hot — EXCLUDE

- **azb-20 lib residue (6 paths)**: `arm_gateway/router.ex`, `blob_storage.ex`,
  `cosmos.ex`, `key_vault_actions.ex`, `connection.ex`, `queue_store.ex` +
  `test/sdk-full/blob.probe.mjs` — landing receipt still ABSENT (`i29-azb20-verify.md`
  verifies, does not land; checkpoint6 `azsim-sdk` witness law still binds blob.probe).
  All mtimes >6 min old, zero movement in the 180 s observation window — stalled but
  unlanded, stay with the azb-20 lane.
- `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md` (M, +73) — ACTIVELY EDITED
  (mtime moved to 00:37:30, newest file on tree, mid-observation). AZB-23
  quiet-machine transition doc, self-styled TYPED_RECOMMENDATION; wait for the lane to
  declare it complete.
- `test_budgets.json` re-dirty (+80 reseed) — budget-lane reseed shape but the naming
  receipt has not landed; exclude until the budget lane receipts it.

### (c) Unattributed — EXCLUDE

- `docs/jira/v26.10.16/sdk-results/spc-bands.md` (M, mtime moved 00:34:08→00:34:44
  DURING the observation window — only path with measured mtime movement) — prior-window
  doc, still no v26.10.18 receipt names the edit; checkpoint5 finding unchanged.
- `.ggen_igniter/manifest.json`, `.ggen_igniter/receipts/2026-10-19.jsonl` — ggen
  runtime scratch, prior verdict unchanged.

## Commit-ready `git add` for the coordinator

```
git add docs/jira/v26.10.18/receipts/i29-e2e-fixes.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint7.md \
        test/e2e/s2_byok/byok.test.mjs \
        test/e2e/s2_byok/run.sh \
        test/e2e/s5_sessions/sessions.test.cjs \
        test/e2e/s9_lro_chain/lro_chain.test.mjs \
        test/e2e/s10_attest_adversary/adversary.py \
        test/e2e/s10_attest_adversary/run.sh
```

(8 paths. Everything else stays on the tree for its owning lane: azb-20 lib residue,
colima runbook lane, budget reseed, spc-bands editor, ggen scratch.)

## Falsifiers

- After coordinator `git add` of group (a) (8 paths incl. this receipt's addendum):
  `git status --porcelain` residue must be exactly 11 M + 0 ?? — 6 azb-20 lib +
  blob.probe.mjs + colima runbook + test_budgets.json + spc-bands.md + 2 ggen scratch.
- `just docs-dod-check` must stay green with `i29-e2e-fixes.md` on disk (its run-log
  paths point at /tmp, no repo-relative receipt deps).

---

# Addendum 3 — re-census at HEAD 5dbcb42 (2026-10-19 ~00:45-00:55 PDT; Context: solo)

- Subject: /Users/sac/smalt @ `5dbcb42` (coordinator landed `fafcbb7` e2e fixes incl.
  this receipt + `5dbcb42` sweep: e2e-receipt clobber disclosure, spc-bands,
  test_budgets.json reseed, and the receipt-index regen of all three windows'
  RECEIPTS.md/INDEX.md — sanctioned regen, not hand-edited).
- Method: `just receipt-index` (sanctioned regen, run 3x — receipts landed between
  runs, final tally stable), `git status --porcelain` (3 samples), `git log -1 -- <path>`,
  `git show --stat`, `git diff`, `stat -f '%Sm'` mtime sweep.

## receipt-index regen + flag counts (final run)

- Regenerated: `RECEIPTS.md` + `receipts/INDEX.md` for v26.10.14 / v26.10.16 /
  v26.10.17 / v26.10.18 (coordinator committed them in `5dbcb42`).
- **NO-CONTEXT: 0** in all four windows (per-window grep -c = 0; d8fd6c3's Context
  normalization held).
- **SUSPECT: 18** total — all in prior windows (v26.10.14: 15, v26.10.16: 1
  `spc-bands.md`, v26.10.17: 2) plus none new in v26.10.18 beyond the two already
  tracked (`i29-court-x2-final.md` 0-byte placeholder standing UNKNOWN,
  `i29-docker-reclaim.md` standing UNKNOWN — both carried from prior checkpoints,
  unchanged verdict). SUSPECT = no embedded command output; standing, not an insult.

## Fresh census at 5dbcb42: 6 M + 0 untracked

### (a) COMMIT-READY — receipt-backed NOW (nothing new; all of Addendum 2's group (a)
landed via `fafcbb7`/`5dbcb42`)

- No new commit-ready paths. The two e2e `receipt.json` churn files below are
  run-artifact timestamp/latency refreshes, not work products.

### (b) Lane-hot / unattributed — EXCLUDE (6 paths)

| Path | Diff | Attribution |
|---|---|---|
| `lib/smalt/arm_gateway/router.ex` (+105) | NEW: RG PATCH (tags merge), RG resources list, locations list endpoints | azb-20 lane; landing receipt still ABSENT (`i29-azb20-verify.md` verifies, does not land). mtime Oct 18 23:35 — stalled. |
| `lib/smalt/data_plane/blob_storage.ex` (+45) | `delete_container/3` | azb-20 lane, same status |
| `lib/smalt/data_plane/cosmos.ex` (+101) | `bulk_operations/4`, `do_get_doc_direct/4` | azb-20 lane, same status |
| `lib/smalt/data_plane/key_vault_actions.ex` (+53) | `update_key_properties/3` | azb-20 lane, same status |
| `test/e2e/s4_oauth_negatives/receipt.json` | run-artifact refresh (finishedAt → 2026-10-19T07:40Z, exp 3600s→3599s note) | e2e lane run residue; commit with next e2e run receipt or revert |
| `test/e2e/s6_checkpoints/receipt.json` | producer_us 8274→6638 | same class |

## Commit-ready `git add` for the coordinator

Nothing new to add from this sweep — Addendum 2's 8-path group (a) landed in
`fafcbb7`+`5dbcb42`. This addendum itself joins the next receipts commit:

```
git add docs/jira/v26.10.18/receipts/i29-checkpoint7.md
```

Residue (6 paths) stays on the tree: 4 azb-20 lib + 2 e2e receipt.json churn.

## Falsifiers

- After the coordinator commits this addendum: `git status --porcelain` residue must
  be exactly 5 M + 0 ?? (4 azb-20 lib + at most the e2e receipt.json files unless the
  e2e lane commits or reverts them first).
- `just docs-dod-check` must stay green with this addendum on disk.

---

## Addendum (census lane, 2026-10-19 00:5x PDT) — correction at HEAD 5dbcb42

- Context: solo(census; read-only git; no git mutations)
- Commands: `git status --porcelain` (fresh, after 5dbcb42), `git diff` /
  `git diff --stat` on each dirty path, head reads of the two new untracked receipts.

### Fresh tree: 10 M + 2 untracked

The 6-M census above predates two receipts landing on disk and the index regen churn.

| Path | Status | Verdict |
|---|---|---|
| `docs/jira/v26.10.18/receipts/i29-e2e-final.md` (??) | e2e full re-verify: 7/7 scenarios exit 0, 53/53 assertions, embedded per-scenario output; Context: slice | **INCLUDE** (self-backing, ALIVE) |
| `docs/jira/v26.10.18/receipts/i29-push-readiness4.md` (??) | read-only push-readiness audit of `1eb89df..8b4f74f` (68 commits): secret-grep clean, 3/4 legs green, publish-dry gate 4 FAIL blocks READY; PARTIAL_ALIVE | **INCLUDE** (audit receipt; its findings are the open residue) |
| `docs/jira/v26.10.14/RECEIPTS.md`, `receipts/INDEX.md`, `docs/jira/v26.10.16/RECEIPTS.md`, `receipts/INDEX.md` (4 M) | generated artifacts, stale vs the new receipts on disk | **REGENERATE then commit**: `just receipt-index`, do not hand-edit |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` (M) | still unattributed by any v26.10.18 receipt (checkpoint5 finding unchanged) | **EXCLUDE** |
| `lib/smalt/arm_gateway/router.ex`, `blob_storage.ex`, `cosmos.ex`, `key_vault_actions.ex` (4 M) | azb-20 lib residue, landing receipt still ABSENT | **EXCLUDE** (lane-hot) |
| `test/e2e/s4_oauth_negatives/receipt.json`, `test/e2e/s6_checkpoints/receipt.json` (2 M) | `git diff` is EMPTY on both — content-identical, stat-dirty only (run-artifact touch). Refresh the index or ignore; nothing to commit | **NO-OP** |

### Commit-ready `git add` (current)

```
just receipt-index
git add docs/jira/v26.10.18/receipts/i29-e2e-final.md \
        docs/jira/v26.10.18/receipts/i29-push-readiness4.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint7.md \
        docs/jira/v26.10.14/RECEIPTS.md docs/jira/v26.10.14/receipts/INDEX.md \
        docs/jira/v26.10.16/RECEIPTS.md docs/jira/v26.10.16/receipts/INDEX.md
```

### Falsifiers

- After that add + commit: residue must be exactly 4 azb-20 lib paths + `spc-bands.md`
  (5 M + 0 ??), unless the e2e lane refreshes the receipt.json files first.
- `just docs-dod-check` green with this addendum on disk (verified: OK across
  v26.10.17/v26.10.16 receipts and README at census time).
