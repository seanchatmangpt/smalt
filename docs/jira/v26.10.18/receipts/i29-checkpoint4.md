# i29 Checkpoint 4 — in-flight lane census at HEAD 086c6aa

- Subject: /Users/sac/smalt @ `086c6aab61c572855c86b5e546953f6b4a523716` (HEAD advanced past checkpoint3's b9b9199)
Context: solo
- Census time: 2026-10-18 23:45 PDT
- Commands: `git status --porcelain` (read-only), `git diff --stat`, `git rev-parse HEAD`, `stat -f '%Sm %N' -t '%H:%M'`

Working tree: 28 dirty paths, +743/-284 (`git diff --stat` summary). No untracked lib/ files.

## Per-lane census

### G1 — KV/azb-20 SDK-gap lib fixes — IN-FLIGHT (hot: edits ≤10 min old) — 7 paths

Evidence: new untracked `test/data_plane/audited_capabilities_test.exs` (mtime 23:44)
imports Router/BlobStorage/Cosmos/KeyVaultActions/EgressRouter — exactly the 5 dirty
lib files. `azb-20-sdk-interop.md` (23:38) registers these surfaces as typed FAIL /
divergence cells (keyvault/secrets/cosmos/arm-resources exit 1; blob container-delete
404-vs-202 divergence), and the `blob.probe.mjs` diff flips the pinned 404 divergence
to 202, matching the `blob_storage.ex` +45 (container-delete 202).

| File | mtime | Diff |
|---|---|---|
| `lib/smalt/arm_gateway/router.ex` | 23:35 | +105 |
| `lib/smalt/data_plane/blob_storage.ex` | 23:35 | +45 |
| `lib/smalt/data_plane/cosmos.ex` | 23:45 | +101 |
| `lib/smalt/data_plane/key_vault_actions.ex` | 23:39 | +53 |
| `lib/smalt/egress_router.ex` | 23:37 | +56 |
| `test/sdk-full/blob.prode` | | |
| `test/sdk-full/blob.probe.mjs` | 23:36 | +7/-4 (404→202 container delete) |
| `test/data_plane/audited_capabilities_test.exs` | 23:44 | NEW (untracked) |

Note: `key_vault_actions.ex` diff carries an explicit UNBLOCK-FIX comment
(23:39): a compile-freeze SLA unblock of a sibling lane's in-flight
`update_key_properties` insertion — feature ownership stays with the G1 lane;
the unblock must be disclosed in both lanes' receipts per the
compile-freeze-disclosure law.

### G2 — Lane C put_restored sweep — QUIESCENT (cold ≥30 min), awaiting commit — 9 paths

Evidence: `i29-leakgate-putrestored.md` (23:20) is the lane's gate receipt;
checkpoint3 partitioned the original 13-file sweep; 4 files landed since
(mcp_test.exs, mcp_wire_test.exs, smalt_arm_gateway_test.exs, +1), 9 remain
dirty, all mtimed 22:53–23:13 — no activity in the last 30 min.

| File | mtime |
|---|---|
| test/amqp/broker_facade_test.exs | 22:54 |
| test/amqp/flow_credit_test.exs | 22:54 |
| test/amqp/frame_codec_test.exs | 23:13 |
| test/amqp/sas_verifier_test.exs | 22:53 |
| test/arm_cors_test.exs | 23:13 |
| test/azsim/sovereign_midnight/sovereign_midnight_test.exs | 22:57 |
| test/lro_test.exs | 23:13 |
| test/smalt_ets_baseline_identity_test.exs | 22:56 |
| test/wire/arm_wire_test.exs | 22:54 |
| test/wire_tier_refusal_sweep_test.exs | 22:55 |

G2 = 10 paths, all cold.

### G3 — shim-court re-anchors — IN-FLIGHT (hot) — 4 paths

Evidence: `i29-shim-courts-fresh.md` (23:30) recorded 12/26 courts FAIL, with
dets_growth and eh_mgmt failing `[FAIL:BEFORE] ... old signature absent` —
exactly the two court scripts being re-anchored (dets_growth diff carries a
`# SHIM-COURT re-anchor 2026-10-18` comment re-pinning the sync_all anchor to
the new bounded-growth sync_table source). disposition_token (STALE_LINE
231→360) and settle_cas (R244_LINE 742→777) are line-number re-anchors, same
class, mtimed 23:43/23:44 — after the receipt, so a fresh re-run receipt is
still owed.

| File | mtime | Change |
|---|---|---|
| scripts/shim_court/dets_growth_court.sh | 23:33 | anchor rewritten to new sync_table source |
| scripts/shim_court/eh_mgmt_court.sh | 23:41 | re-anchor |
| scripts/shim_court/disposition_token_court.sh | 23:44 | STALE_LINE 231→360 |
| scripts/shim_court/settle_cas_court.sh | 23:43 | R244_LINE 742→777 |

### G4 — e2e fixes (s2/s9/s10) — IN-FLIGHT — 5 paths

Evidence: `i29-e2e-recheck.md` (23:43) marks this lane [IN-FLIGHT]:
`i29-e2e-fixes.md` ABSENT + test/e2e/ dirty. Files 23:21–23:28. Recent commit
0780e1e records the lane blocked on a foreign compile freeze; s9 spot check
confirmed the 202-LRO fix direction is correct.

| File | mtime |
|---|---|
| test/e2e/s10_attest_adversary/adversary.py | 23:28 |
| test/e2e/s2_byok/byok.test.mjs | 23:26 |
| test/e2e/s2_byok/run.sh | 23:23 |
| test/e2e/s2_byok/s2_run.patch.py | 23:21 (untracked) |
| test/e2e/i9_lro | |
| test/e2e/s9_lro_chain/lro_chain.test.mjs | 23:23 |

G4 = 5 paths.

### G5 — budget reseed — LANDED-FILE-ONLY (no receipt yet) — 1 path

`docs/jira/v26.10.18/test_budgets.json` mtime 23:30; diff +135 lines reshaped.
`i29-budget-verify.md` (22:32) verified the gate as of an UN-reseeded file;
no `i29-budget-reseed.md` exists yet, so the reseed has no receipt naming it.
Treat as in-flight-unreceipted; `just test-budget` must be re-run post-commit.

### G6 — validate_burn.py standing derivation — LANDED, receipt current — 1 path

`scripts/validate_burn.py` (23:43) ↔ `i29-validator-standing-fix.md` (23:43,
standing ALIVE, self-check fixture, real-data proof both directions). Receipt
postdates/precedes file within the same minute — matching pair, hot (<10 min).

### G7 — burn measurement updates — IN-FLIGHT — 2 paths

`docs/jira/v26.10.16/sdk-results/spc-bands.md` (23:43, n-bump 317→328 /
316→327 — checkpoint3 classified the same diff class as a measurement update,
not a hand-edit of a band) and `.ggen_igniter/receipts/2026-10-19.jsonl`
(23:25, generator reconciliation lines). Named by checkpoint3 under Lane B
(burn). Hot (spc-bands).

## Landed-time estimate summary

Groups with file activity in the last 10 minutes (hot, still editing):
G1 (23:35–23:45), G3 (23:33–23:44), G4 (23:21–23:28, receipt 23:43 confirms
in-flight), G6 (23:43), G7 (23:43). Groups cold ≥20 min (likely done, awaiting
commit): G2 (22:53–23:13). Unreceipted: G5.

## Commit boundary (once all land)

No shared files across groups — commit order is dependency-safe:

1. `feat(data-plane)` — G1: 5 lib files + `blob.probe.mjs` +
   `audited_capabilities_test.exs`. Gate: `mix test
   test/data_plane/audited_capabilities_test.exs` + `just azsim-sdk`
   (FAIL cells must flip to 0; KD register flips via `scripts/kd_flip.py
   --apply`, receipt-gated, never hand-edit).
2. `test(env)` — G2: the 10-file put_restored sweep. Gate: `just leak-court` +
   `just sleep-gate` + `just test-budget` (timings may shift).
3. `test(courts)` — G3: 4 court re-anchors. Gate: `just shim-courts` must go
   26/26 PASS (the 12 FAIL cells in i29-shim-courts-fresh are the pre-fix
   baseline; a fresh aggregate receipt is owed).
4. `test(e2e)` — G4: 5 e2e files + `i29-e2e-fixes.md` landing with it.
5. `chore(budget)` — G5: `test_budgets.json` + fresh `just test-budget` receipt.
6. `fix(burn)` — G6: `scripts/validate_burn.py` (receipt already landed).
7. `chore(burn)` — G7: `spc-bands.md` + `.ggen_igniter` jsonl.

Then wrap sequence: `just court-x2` → `just receipt-index` →
`just docs-dod-check` → commits → `just publish-dry`.

Standing: CENSUS (read-only observation receipt; no gates run in this checkpoint).
