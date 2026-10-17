# Court-x2 wrap run 12 — RED (shifting-failure)

- Standing: **RED — gate FAIL, no two-green** (both runs `COURT_X2_RC=1`)
- Lane: Terminal court tail (T1), 2026-10-16
- Subject: `tmp/court-x2-wrap-run12.log` (runs 12.1 19:19→19:22, 12.2 19:22→19:26)
- No fixes applied (per lane contract: typed defect list only)

## Signature

`1 doctest, 7 properties, 2428 tests, 1 failure` in BOTH runs, but on
**different tests** — the shifting-failure / flake alarm fired; failure-set
diff non-empty. This is not the run-8 port-contention class (substrate
booted clean both runs) and not a deterministic regression.

## Typed defect list

1. **Class: semantic-projection flake family (known set, Lens FLAKE_SOLO
   family — same family as the pinned `Lens7FieldPolicyTest:545`
   FLAKE_SOLO from run 7; this instance is `Lens6StructuralTest:463`)**
   — run 12.1 only, absent run 12.2:
   `test a Store row with a non-map properties projects provisioning_state
   nil, never crashes (Smalt.Semantic.StoreRead.Lens6StructuralTest)`
   (`test/semantic_projection_test.exs:463`). Store-read ordering /
   residue-shape flake, did not reproduce in run 2 of the same gate.

2. **Class: affidavit/wasm-admission class (adjacent to known set —
   seal-suite/wasm_engine family from run 7, r215-affidavit-seal-court
   surface)** — run 12.2 only, absent run 12.1:
   `test 1: admission returns 352-byte CTRT with magic CTRT
   (Smalt.AffidavitWasmTest)` (`test/smalt_affidavit_wasm_test.exs:57`).
   Same substrate family as the run-7 SealTest x4 signal (wasm_engine
   churn-hardening). Fired once here; per the run-9 receipt's graduation
   rule, a second occurrence graduates it from flake-candidate to defect —
   this is occurrence #2 across the window (run 7 SealTest x4 family,
   run 12.2 AffidavitWasm) — flagging for the wasm-admission lane.

## Verdict

RED, terminal for this poll window. Rerun court-x2 once the tree is quiet
before any two-green receipt. Watch `AffidavitWasmTest` — one more hit and
it is a defect, not a flake.
