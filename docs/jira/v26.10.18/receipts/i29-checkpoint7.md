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
