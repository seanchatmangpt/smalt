# r243 — v26.10.17 terminal receipt

Standing: **PARTIAL_ALIVE** (terminal). The window's release gate (`just court-x2`, WO-2)
closed **honest TYPED-RED** after 3 attempts — **0 two-green in 35 completed gate
invocations** (32 prior across windows + 3 this window; counts as stated in
[r240](r240-court-x2-attempts12-typed-red.md) and
[r241](r241-court-x2-attempt3-typed-red.md), re-stated in FINAL.md §Court inventory).
**No version bump anywhere: version stays 26.10.16** — re-verified on disk 2026-10-17:
`mix.exs:4` reads `@version "26.10.16"`, `workspace/package.json:3` reads `"version": "26.10.14"`.
No TWO-GREEN claim exists in this window's artifacts; standing flips only on a future
real two-green court receipt.

## Head / window identity

- HEAD at this receipt's authoring: **`7b42734`** (read from
  [../FINAL.md](../FINAL.md) §Commit SHAs; window range **`650a8ff..7b42734`**, 4
  first-parent commits). Wrap commits may have landed after `7b42734` — the FINAL.md
  Commit SHAs block updates with further wrap SHAs as they land; this receipt reads
  FINAL.md, it does not run git.
- Chain: `d092caa` (court RED closure lib/ landing) → `b454607` (spc-bands regen) →
  `65926f2` (receipt-index regen) → `7b42734` (harness mechanisms).

## O / O* inventory (what this terminal state is built on)

| Layer | Items |
|---|---|
| O (raw observations) | court-x2 logs `tmp/court-x2-v17-wrap.log`, `tmp/court-x2-v17-wrap2.log`, `tmp/court-x2-v17-wrap3.log` (`COURT_X2_RC=1` at line 86); quiesce warm-up log `tmp/quiesce-a3.log` (1 failure / 2655 tests / 302.5s); quiet-check logs `tmp/quiet-check-a3-1.log` / `tmp/quiet-check-a3-2.log` (load 6.3 and 9.0 < 16); pre/post-court full-suite logs `tmp/mix-test-a3-full.log`, `tmp/mix-test-a3-postcourt.log`; verify-ledger batch files `docs/jira/v26.10.17/verify-ledger/` (w0 × 24 + w1 × 14 = 38 batch files, counted on disk) |
| O* (admitted observations) | r240/r241 receipt chains; WRAP_LEDGER.md; FINAL.md certification (counts re-derived inline at final pass); NEXT_WINDOW.md v26.10.18 mint; verify-ledger actuals: **78 finding verdict entries, 55 unique CONFIRMED findings, 6 PREMISE-ROT (F1, F2, SDK-7, TIL-06, TIL-07, IG-7), 1 CONTENTION (C12)** (per NEXT_WINDOW.md §8; ground truth is the ledger on disk, re-derive at next-window open) |
| Skeptic corrections | r240→r241 fence-10 upgrade: the "zero repeats of a full (test, mode) face between the two court legs" claim is FALSE — fence 10 (WasmEngineFailClosed "restart hammer", `test/affidavit_wasm_failclosed_test.exs:502`) failed in BOTH attempt-3 court legs (wrap3.log lines 68 + 72). Fence 10 upgraded CONTENTION → **PERSISTENT-FLAKE** (repeats under court load, solo-green; needs bound slack or harness de-parallelization, not a warm-up). Correction recorded in the receipt body, not silently rewritten. |
| Not admitted | no two-green; no version bump; WO-4 never executed; the release-receipt mint class was not attempted |

## Gate chain (r240 → r241)

| Attempt | Pre-court precondition | Run 1 | Run 2 | Outcome |
|---|---|---|---|---|
| 1 (r240) | none (post-push) | RED — WasmEngineFailClosed "restart hammer" (`test/affidavit_wasm_failclosed_test.exs:502`) + sdk-smoke watchdog exit 124 | GREEN (0 failures) | RED |
| 2 (r240) | none (overlapped the read-only verify pool's launch) | RED — EgressDispatchTest "batch-list boundary" (`test/egress_dispatch_test.exs:1221`) | GREEN (0 failures) | RED |
| 3 (r241) | `just quiet-check` clear ×2 (load 6.3, then 9.0 < 16) + `just quiesce` warm-up — **warm-up itself FAILED** (1 failure / 2655 tests / 302.5s) | RED — 4 failures, incl. fence 10 | RED — 1 failure, **fence 10 REPEAT** | **TYPED-RED, gate closed** |

Every tripped face is solo-green on the same tree (r241 §Solo verification, all RC=0,
1 test / 0 failures each: `affidavit_wasm_failclosed_test.exs:502`,
`egress_dispatch_test.exs:1474`, `lro_test.exs:543`, `egress_dispatch_test.exs:975`).

## Commands + exits ladder (as executed this window)

- `bash scripts/court_x2.sh` — attempts 1/2: RC=1 each, run 2 green each. Attempt 3: RC=1,
  run 1 = 4 failures, run 2 = 1 failure, both legs `test-offline` exit 2
  (`tmp/court-x2-v17-wrap3.log`, `COURT_X2_RC=1` line 86).
- `just quiet-check` — RC=0 ×2 (attempt-3 preconditions held: load 6.3, then 9.0 < 16).
- `just quiesce` — **RC=2** (warm-up full offline suite failed: 1/2655, 302.5s).
- `just docs-dod-check` — **exit 0** (re-run 2026-10-17, FINAL.md certification).
- `scripts/naming_sweep.sh` — **FAIL: 1 violation / 46 allowed**
  (`RECEIPT_CONTEXT_LAW.md:3` absolute-path violation; parked).
- `python3 gates/test_isolation_leak_gate.py` — `verdict=FAIL-TREE-LEAKS tree=LEAKS
  offenders=56 fixtures_refused=True` (gate mechanics ALIVE, 3/3 non-vacuity fixtures
  refuse; honest nonzero tree verdict; NOT wired into `just court`/`invariant-gates`).
- `MIX_BUILD_ROOT=_build-ft-final mix test test/corpus_test.exs` — exit 0,
  **26 tests, 0 failures** (corpus suite's first green witness this window).
- `mix test test/kd79_blob_apiversion_wire_test.exs test/arm/kd87_sts_leading_empty_segment_test.exs` —
  **6 tests, 0 failures** ([i18-kd-falsifiers.md](i18-kd-falsifiers.md)).
- `python3 scripts/receipt_index.py` — receipts=373 sdk=51 total=424 **suspects=16**
  (re-run inline at certification; supersedes v26.10.16's 322/49/371/16).

## Faces at close (typed)

1. **fence 10 — PERSISTENT-FLAKE**: WasmEngineFailClosedTest "restart hammer under
   parallel load", `test/affidavit_wasm_failclosed_test.exs:502`. Solo-green; repeated in
   BOTH attempt-3 legs; witnessed 129 ms vs a bound that fires at 1.08x budget under
   suite load (BUDGET-1 class: the 110 ms perf budget acts as a load sensor, not a
   regression detector; ~3.3x is the documented revert threshold). Repair surfaces named
   in r241, not landed: (a) bound slack (raised to the ~3.3x discrimination band) or
   (b) harness de-parallelization/serialization of the restart hammer. A warm-up is NOT
   a fix (r241 evidence).
2. **EgressDispatch ETS race — contention-class**: test setup seeds ETS
   `:smalt_subscriptions` via `Smalt.Store.seed_default_subscription/0`
   (`lib/smalt/store.ex:194`) racing another async module's Store teardown ("table
   identifier does not refer to an existing ETS table"); victims
   `test/egress_dispatch_test.exs:1474` and `:975`, both solo-green. Async-module
   isolation, not a product defect.
3. **Lro :543 op-record store miss** (`:error` vs Succeeded, `test/lro_test.exs:543`):
   contention-class, solo-green.

No product defect is asserted beyond the receipts.

## Falsifiers

- **Gate falsifier**: a full two-green `bash scripts/court_x2.sh` on this tree would
  falsify the TYPED-RED close — runnable on demand (`just court-x2`). 0 two-green in 35
  invocations is the standing witness; one clean run falsifies "the gate cannot go green".
- **Fence-10 falsifier**: a court-context (not solo) witness of fence 10 PASS across two
  consecutive `just court` legs would flip it back toward contention; conversely a solo
  RED on a quiet machine would refute the solo-green premise.
- **No-bump falsifier**: any `@version`/`"version"` in `mix.exs:4` /
  `workspace/package.json:3` reading anything other than 26.10.16/26.10.14 falsifies the
  no-version-bump claim (re-verified on disk 2026-10-17: both hold).
- Per-face falsifiers: [i20b-contention-mechanism.md](i20b-contention-mechanism.md);
  ledger findings close per-finding (probe receipt or registrar-minted KD row), never by
  being listed.

## Remaining parks (none closed by being listed here)

1. **Fence-10 PERSISTENT-FLAKE repair** (bound slack / harness serialization) —
   next-window WO-A (NEXT_WINDOW.md §7).
2. **EgressDispatch seed_default_subscription async isolation** (WO-B, NEXT_WINDOW.md §7);
   Lro :543 re-evaluated on the same receipt.
3. **Leak-court wiring** into `just court`/`invariant-gates` (blocked: 122 flagged
   mutations; tree verdict FAIL-TREE-LEAKS, offenders=56) — coordinator-owned.
4. **publish-dry TYPED-BLOCKED (B1)**: ex4pm non-optional path dep refuses hex.build;
   sole publish-gate blocker, not closeable from this tree (v26.10.16 PUBLISH_RECORD).
5. **naming-sweep violation**: 1/46, `RECEIPT_CONTEXT_LAW.md:3` absolute path —
   next-window docs work.
6. **GAP tokens OPEN** (receipt-gated flips only): `GAP(blob-x-ms-date-unvalidated)`,
   `GAP(blob-comp-lease-absent)`, `GAP(kql-datetime-dynamic-types-absent)`,
   `GAP(atlas-search-relationship-get-absent)`,
   `GAP(eventgrid-eg1-schema-absent)` (narrowed: stays OPEN for undeclared topics +
   system-topic-sourced ingest).
7. **c11 typed findings** (v26.10.18 work orders; close conditions in
   [../NEXT_WINDOW.md](../NEXT_WINDOW.md) §1): blobServices/default singleton 404;
   azurerm cosmosdb CheckNameExists unparseable 400/EOF; ARM-vs-blob store split;
   cosmos query-feed no-filter + stale projection (KD-93, OPEN).
8. **KD-77 flip** — OPEN, blocked on a PASS re-witness receipt postdating the KD-77
   shims (`scripts/kd_flip.py --apply`, registrar-owned).
9. **T5 tf_cleanroom** — PENDING-EXECUTION (gated on trusted machine).
10. **SUSPECT triage** — index reads **16 SUSPECT** (373/51/424/16 line above);
    remainder is NEXT_WINDOW work.
11. **A24 findings 3-9 enumeration debt** — NOT-RECOVERABLE-FROM-TREE; finding list
    never persisted (NEXT_WINDOW.md §6).
12. **Receipt context law adoption** — `Context: solo|pair|slice|full` line required in
    every witness receipt next window (RECEIPT_CONTEXT_LAW.md; this receipt's court
    faces carry context via the r241 chain).

## NEXT_WINDOW pointers

- [../NEXT_WINDOW.md](../NEXT_WINDOW.md) — the full v26.10.18 mint: WO-A fence-10
  repair, WO-B EgressDispatch ETS isolation, KD-77 PASS re-witness, c11 typed findings,
  leak-court wiring, SUSPECT triage, court residual repair surfaces.
- Gate carry: the court-x2 gate carries to v26.10.18 with the r240→r241 chain and this
  receipt as the terminal honest witness. Preconditions now mechanical per WRAP_LEDGER:
  `just quiet-check` clear + quiesce warm-up green BEFORE the gate; a warm-up failure is
  itself a stop signal, not a hurdle to push through.

## See Also

[r240](r240-court-x2-attempts12-typed-red.md) ·
[r241](r241-court-x2-attempt3-typed-red.md) ·
[../WRAP_LEDGER.md](../WRAP_LEDGER.md) · [../FINAL.md](../FINAL.md) ·
[../NEXT_WINDOW.md](../NEXT_WINDOW.md) · [../RECEIPTS.md](../RECEIPTS.md)
