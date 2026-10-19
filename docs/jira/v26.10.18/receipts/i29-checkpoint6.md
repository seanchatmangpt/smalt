# i29 Checkpoint 6 — in-flight lane census at HEAD d577677

- Subject: /Users/sac/smalt @ `d577677b64cff26b71a76d01f95985ac8579e6e5` (parent `148e440`, the checkpoint5 subject — one coordinator commit landed mid-census)
Context: solo(census; read-only git; no git mutations)
- Census time: 2026-10-19 00:2x PDT (open ~00:20 at HEAD 148e440, close ~00:25 at HEAD d577677)
- Commands: `git status --porcelain` (live, twice), `git log --oneline`, `git rev-parse HEAD`,
  `git diff --stat`, `git diff --cached --stat`, `git show --stat d577677`,
  `git diff 148e440..HEAD --stat -- <paths>`, `stat -f '%Sm' -t '%H:%M:%S'`,
  per-receipt `grep -l` attribution over `docs/jira/v26.10.18/receipts/*.md`

Working tree at close: 20 modified + 3 untracked = 23 dirty paths, +670/-76 vs HEAD
(census opened at 30 dirty paths / +694/-74 vs 148e440 — see mid-census drift note).

## Mid-census drift (two transitions, neither mine)

1. **Commit landed**: `d577677` "fix(budget): budget gate PASS exit 0 — manifest reseeded
   to 2748, private-export law" — exactly 2 files: `test_budgets.json` (+69/-14... stat:
   112 insertions, 14 deletions across both) and new receipt
   `docs/jira/v26.10.18/receipts/i29-budget-final.md` (57 lines). This RESOLVES
   checkpoint5's G4 (budget re-seed): `i29-budget-reseed.md` never existed on disk;
   the landing receipt is `i29-budget-final.md`, committed with the artifact.
2. **Four files reverted-to-HEAD without a commit**:
   `test/support/env.ex`, `test/support/isolation_formatter.ex`,
   `test/canonical_projection_test.exs`, `test/amqp/sas_verifier_test.exs` were dirty at
   census open (mtimes 23:55 / 00:13 / 00:13 / 23:53); at close they are byte-clean vs
   HEAD and `git diff 148e440..HEAD --stat` on those paths is EMPTY — no commit between
   carries them. Edits withdrawn, not landed. One new path appeared instead:
   `test/e2e/s10_attest_adversary/run.sh` (modified). No lane receipt names any of the
   four withdrawn files in i29-*; attribution of the withdrawn edits: UNKNOWN, no longer
   actionable.

## Per-group census (state at close, HEAD d577677)

### (a) azb-20 lib files — 9 paths — RECEIPTED: **NO** [IN-FLIGHT]

Newest azb-20 receipt: `azb-20-sdk-interop.md` mtime **00:04:10**. It registers the SDK
gaps (matrix.json 45 rows) but does NOT claim the lib gap-fix edits landed. Files with
mtime newer than 00:04:10 are post-receipt edits: `cosmos.ex` 00:06:47, `connection.ex`
00:12:24, `queue_storage.ex` 00:19:37. A gap-fix receipt (`i29-azb20-gapfix*.md`) remains
ABSENT (re-confirmed at close).

| File | mtime | Note |
|---|---|---|
| `lib/smalt/arm_gateway/router.ex` | 23:35:06 | +105; async_put_response co-subject with s9 e2e |
| `lib/smalt/data_plane/blob_storage.ex` | 23:52:03 | container-delete 404→202; flips blob.probe pinion |
| `lib/smalt/data_plane/cosmos.ex` | 00:06:47 | POST-receipt edit; also shim-court etag_cas subject |
| `lib/smalt/data_plane/key_vault_actions.ex` | 23:39:13 | ownership: KV/azb-20 lane (azb-20 receipt discloses shim-court-repair UNBLOCK-FIX) |
| `lib/smalt/egress_router.ex` | 00:03:50 | comp_whitelist court subject (repair2 PASS 00:07 covers the court, not the lib edit) |
| `lib/smalt/messaging/amqp/connection.ex` | 00:12:24 | POST-receipt edit |
| `lib/smalt/messaging/amqp/queue_store.ex` | 23:52:13 | shared with renew_mirror court seam |
| `lib/smalt/data_plane/queue_storage.ex` | 00:19:37 | NEW untracked; named only in scoping doc `i29-g1-scoping.md` + `azsim-burn/G1-QUEUE-STORAGE-SCOPING.md` — scoping, not a landing receipt |
| `test/sdk-full/blob.probe.mjs` | 23:36:09 | pinned-divergence flip 404→202 (wire-compat pinion hazard) |

### (b) e2e fixes (s2/s5/s9/s10) — 7 paths — RECEIPTED: **NO** [IN-FLIGHT]

Backing receipt `i29-e2e-fixes.md` ABSENT (re-confirmed at close). Latest edit
`sessions.test.cjs` 00:18:44 — postdates every receipt on disk (newest 00:17:18
`.ggen` jsonl aside, newest lane receipt azb-18-cgroup-soak 00:17). `run.sh` (s10) newly
dirty since checkpoint5.

| File | mtime |
|---|---|
| `test/e2e/s10_attest_adversary/adversary.py` | 23:28:37 |
| `test/e2e/s10_attest_adversary/run.sh` | (newly dirty; see diff --stat) |
| `test/e2e/s2_byok/byok.test.mjs` | 23:50:33 |
| `test/e2e/s2_byok/run.sh` | 23:23:44 |
| `test/e2e/s2_byok/s2_run.patch.py` | NEW untracked |
| `test/e2e/s5_sessions/sessions.test.cjs` | 00:18:44 |
| `test/e2e/s9_lro_chain/lro_chain.test.mjs` | 23:23:24 |

### (c) budget manifest — RESOLVED mid-census

`test_budgets.json` was dirty at open (00:11:34, checkpoint5 G4, receipt absent);
`d577677` landed it WITH `i29-budget-final.md`. Receipted YES as of close. Nothing
further owed by the budget lane.

### (d) env.ex / isolation_formatter.ex — WITHDRAWN, unreceipted

Dirty at open (23:55:08 / 00:13:29), byte-clean at close, carried by NO commit
(`git diff 148e440..HEAD` empty on both). No i29-* receipt names isolation_formatter;
env.ex's last naming receipt (`i29-env-leak-remediation.md` 23:50) predates its 23:55
edit. No lane owes a receipt; the withdrawn content is unrecoverable from git and the
attribution is UNKNOWN by design of the withdrawal.

### (e) canonical_projection_test.exs / sas_verifier_test.exs — WITHDRAWN, unreceipted

Same signature as (d): dirty at open (00:13:31 / 23:53:24), clean at close, no commit
between carries them. `azb-18-cgroup-soak.md` (00:17) mentions canonical_projection_test
only as one entry in a full-dir census listing, not a landing claim. No lane owes a
receipt.

### (f) receipts ready to commit — 2

| Path | Status |
|---|---|
| `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md` | modified (+23, self-backing gate-appendix output; graded commit-ready by checkpoint5, still true) |
| `docs/jira/v26.10.18/receipts/i29-checkpoint6.md` | this receipt |

NOT ready: `docs/jira/v26.10.18/receipts/i29-court-x2-final.md` — untracked and
**0 bytes** (placeholder; mtime Oct 18 23:54). A zero-byte receipt on disk will satisfy
path-existence checks while carrying zero evidence — coordinator should either fill it
from the court-x2 run or delete it until the run exists.

## Residual scratch (unchanged verdict from checkpoint5)

- `.ggen_igniter/receipts/2026-10-19.jsonl` — ggen runtime events, 00:17:18, scratch.
- `docker/burn/compose.cgroup.yml` — receipted by `azb-18-cgroup-soak.md` (00:17,
  env-override verdict); commit-ready with that receipt as backing.
- `docs/jira/v26.10.16/sdk-results/spc-bands.md` — mtime 00:19:57, sample-count refresh
  (n 317→332 / 316→331 class); STILL no receipt names the edit. Unattributed, prior-window
  doc. Unchanged finding from checkpoint5 G5.

## Commit-ready list (receipt-backed only)

1. `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md` (+ `azb-18-cgroup-soak.md`-backed `docker/burn/compose.cgroup.yml` if the coordinator groups them)
2. `docs/jira/v26.10.18/receipts/i29-checkpoint6.md` (this receipt)

Everything in (a) and (b) remains receipt-unbacked and lane-hot: do not integrate until
`i29-azb20-gapfix*` / `i29-e2e-fixes` receipts land, with the blob 404→202 pinion flip
committed only alongside an `azsim-sdk` witness.
