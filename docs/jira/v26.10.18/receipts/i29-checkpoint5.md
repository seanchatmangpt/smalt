# i29 Checkpoint 5 — in-flight lane census at HEAD 0351252

- Subject: /Users/sac/smalt @ `0351252cfa0cbd71481d994c248cf61d83341630` (HEAD advanced past checkpoint4's 086c6aa — coordinator committed 3 receipts 23:5x)
- Context: solo(census; read-only git; no git mutations)
- Census time: 2026-10-19 00:0x PDT (after coordinator commits at 23:5x)
- Commands: `git status --porcelain` (full), `git diff --stat`, `git rev-parse HEAD`, `stat -f '%Sm %N' -t '%H:%M'`, per-file `git diff` reads

Working tree: 30 dirty paths (27 modified + 3 untracked), +774/-116 vs HEAD.

## Per-group census

### G1 — azb-20 SDK-gap lib fixes + audited-capabilities test — 8 paths — RECEIPTED: **NO** [IN-FLIGHT]

Backing receipt check: `i29-azb20-gapfix*.md` absent; `azb-20-sdk-interop.md` (23:38)
registers the gaps but predates the fix edits (cosmos.ex mtime 23:49, audited test
23:52). No gap-fix receipt newer than 23:38 on disk.

| File | mtime | Diff |
|---|---|---|
| `lib/smalt/arm_gateway/router.ex` | 23:35 | +105 |
| `lib/smalt/data_plane/blob_storage.ex` | 23:35 | +45 (container-delete 404→202) |
| `lib/smalt/data_plane/cosmos.ex` | 23:49 | +101 |
| `lib/smalt/data_plane/key_vault_actions.ex` | 23:39 | +53 |
| `lib/smalt/egress_router.ex` | 23:37 | +56 |
| `lib/smalt/messaging/amqp/queue_store.ex` | | (renew_mirror co-subject; see G3) |
| `test/data_plane/audited_capabilities_test.exs` | 23:52 | NEW (untracked) |
| `test/sdk-full/blob.probe.mjs` | 23:36 | +7/-4 (pinned divergence 404→202) |

Note: `queue_store.ex` is shared with G3's renew_mirror court (co-subject) — attribute
per RESOLUTIONS.md seam, not unilaterally.

### G2 — e2e s2/s5/s9/s10 fixes — 6 paths — RECEIPTED: **NO** [IN-FLIGHT]

Backing receipt: `i29-e2e-fixes.md` **ABSENT** on disk (re-confirmed 00:0x; the 23:43
`i29-e2e-recheck.md` also recorded it absent and ran an s9-only spot check). Latest
edit 23:48 (sessions.test.cjs) — lane still hot.

| File | mtime |
|---|---|
| `test/e2e/s10_attest_adversary/adversary.py` | |
| `test/e2e/s2_byok/byok.test.mjs` | |
| `test/e2e/s2_byok/run.sh` | |
| `test/e2e/s2_byok/s2_run.patch.py` | NEW (untracked) |
| `test/e2e/s5_sessions/sessions.test.cjs` | 23:48 |
| `test/e2e/s9_lro_chain/lro_chain.test.mjs` | |

Content verified: s9 flips DELETE 200→202 + async-header asserts + LRO poll (matches
`arm_gateway/router.ex` async_put_response in G1); s2_run.patch.py documents the
MIX_ENV=test / anonymous-mode premise fix.

### G3 — shim-court repair — 10 paths — RECEIPTED: **NO** [IN-FLIGHT]

Backing receipt: `i29-shim-court-repair.md` **ABSENT** on disk. `i29-shim-court-verify.md`
(23:51) ran the 12 courts individually: 9 PASS, 3 genuine AFTER-leg failures
(comp_whitelist on landed `egress_router.ex`, etag_cas on landed `cosmos.ex`,
tombstone_grace on landed `sweeper.ex`) — the repair lane is landing fixes for exactly
these (cosmos.ex 23:49, egress_router 23:37 hot). 10 dirty files:

`comp_whitelist_court.sh`, `comp_whitelist_witness.exs`, `dets_growth_court.sh`,
`disposition_token_court.sh`, `eh_mgmt_court.sh`, `orphan_token_court.sh`,
`renew_mirror_court.sh`, `settle_cas_court.sh`, `tombstone_grace_court.sh`,
`wire_norm_shim.py`.

### G4 — budget manifest + gate recipe — 2 paths — RECEIPTED: **NO** [IN-FLIGHT]

Backing receipt: `i29-budget-reseed.md` **ABSENT** (re-confirmed; `i29-budget-verify.md`
22:31 recorded the gate FAIL 772 unmanifested / 61 stale pre-re-seed).

- `docs/jira/v26.10.18/test_budgets.json` (23:51, +47/-9): re-seed additions.
- `justfile.d/28-test-budget.just` (23:47): PID-suffixed export isolation rework.
  **CAUTION**: current on-disk tail reads `tmp/test-budget-export.$$.sh}">` — the file
  appears truncated mid-write / syntactically suspect. Owner should re-verify before
  commit; `just` will fail to parse a broken recipe file and freeze all lanes
  (compile-freeze SLA applies to justfile.d per fanout law 5).

### G5 — everything else — 3 paths

| File | Receipted | Note |
|---|---|---|
| `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md` | self | HOLD #2/#3 appendices (gate re-evaluations, no execution). Backing = the appendices' own embedded docker ps output. **Commit-ready.** |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` | NO | n 317→332 / 316→331 sample-count refresh, mtime 23:53, no receipt newer than checkpoint4 names it. Unattributed edit to a prior-window doc. |
| `.ggen_igniter/receipts/2026-10-19.jsonl` | scratch | ggen RECONCILIATION_STARTED events, 23:25, `commands:[]`. Ggen runtime log; not lane output. |
| `scripts/court23.sh` | NO | untracked; AZB-23 quiet-window gate executor, pre-positioned, header says NOT auto-run. No receipt names it as landed. |

## Commit-ready (receipt-backed only)

1. `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md`
2. `docs/jira/v26.10.18/receipts/i29-checkpoint5.md` (this receipt)

Nothing in G1–G4 is receipt-backed yet: all four lanes are IN-FLIGHT (receipt absent +
hot edits), matching the checkpoint4 verdict for G1/G2 and extending it to G3/G4.

## Hazards for the coordinator

- **`justfile.d/28-test-budget.just` truncation** (G4): a syntactically broken imported
  module freezes every `just` invocation tree-wide. If the owner doesn't land within the
  SLA, minimal unblock = restore the two recipes from `git show HEAD:justfile.d/28-test-budget.just`.
- **Shared-file overlaps**: `egress_router.ex`/`cosmos.ex` appear in both G1 (gap fixes)
  and G3 (shim-court AFTER legs) — attribute the overlap explicitly in both lanes'
  receipts (compile-freeze dual-naming law).
- G1 blob 404→202 flips a pinned wire-compat pinion (`blob.probe.mjs`); commit only with
  the azb-20 gap-fix receipt + `just azsim-sdk` witness on record.
