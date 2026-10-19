# i29 e2e recheck — s9 spot check (lane: e2e-fix recheck)

Date: 2026-10-18 · Repo: /Users/sac/smalt

Context: solo (shared checkout, 4+ concurrent lanes on shared `_build` lock)

## Gate condition

- `docs/jira/v26.10.18/receipts/i29-e2e-fixes.md`: **ABSENT** (checked on disk).
- `git status --porcelain test/e2e/`: DIRTY → **[IN-FLIGHT]**
  - `M test/e2e/s10_attest_adversary/adversary.py`
  - `M test/e2e/s2_byok/byok.test.mjs`
  - `M test/e2e/s2_byok/run.sh`
  - `M test/e2e/s9_lro_chain/lro_chain.test.mjs`
  - `?? test/e2e/s2_byok/s2_run.patch.py`
- Per directive: receipt absent + dirty ⇒ [IN-FLIGHT], run s9 only as spot check.

## s9 LRO assertion — DID CHANGE (the 202-vs-200 face)

`git diff test/e2e/s9_lro_chain/lro_chain.test.mjs`:

- s9 (6) DELETE storageAccount: `assert.equal(del.status, 200)` →
  **`assert.equal(del.status, 202)`** + asserts `azure-asyncoperation` and
  `location` headers + polls the delete LRO op to terminal `Succeeded`
  (bounded `POLL_BUDGET`, no fixed-sleep coordination beyond the existing
  poll interval constant). Comment pins the substrate behavior to
  `lib/smalt/arm_gateway/router.ex` `async_put_response(conn, 202, op)` and
  `test/lro_test.exs` "storageAccounts DELETE is an ARM LRO — 202 + async headers".
- s9 (2) lock If-Match fallback: `'"s9-placeholder-etag"'` → `"*"`
  (RFC 7232 always-match; 412 negative probe retained).

## Execution

```
bash test/e2e/s9_lro_chain/run.sh   # attempt 1
→ substrate did not open 19443 within 120s; killed by build-dir lock
  contention (holders: PIDs 89266, 95284 — other lanes' mix test)
bash test/e2e/s9_lro_chain/run.sh   # attempt 2, after lock holders exited
→ EXIT=2 (substrate never up)
  Compilation error: lib/smalt/data_plane/key_vault_actions.ex:900:4
  TokenMissingError: missing terminator: end (line 334 `do` unclosed)
```

Attempt 3 blocked: the file is actively mid-edit by another lane
(mtime Oct 18 23:36, held open by PID 60843); shared `_build` lock queued
behind 4 processes (60880, 49569, 58502, 39152). Lane directive forbids
edits, so no unblock fix was applied (compile-freeze SLA belongs to the
editing lane; disclosure per same-checkout-fanout addition 6 not triggered).

## Verdict

- s9 spot check: **BLOCKED (exit 2, substrate never up — foreign compile
  freeze in `lib/smalt/data_plane/key_vault_actions.ex`)**. Not a test
  failure of s9 itself; the changed 202-LRO assertion was NOT executed.
- s2 / s5 / s10: NOT RUN (lane is [IN-FLIGHT], receipt absent).
- Standing: **SUSPECT — retry s9 after the editing lane lands or reverts
  `key_vault_actions.ex`; full 4-scenario re-run only after
  `receipts/i29-e2e-fixes.md` lands.**
