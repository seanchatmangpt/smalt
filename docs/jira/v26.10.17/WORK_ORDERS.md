# v26.10.17 Work Orders

Window: v26.10.17 · Lane partition: `_LANES.md` · Seams: `RESOLUTIONS.md`
(authored at first seam). Orders land only with embedded real command output.

## WO-1 — W2b generator surgery (I1) — DONE

LANDED on main: 483eee3 (`fix(generator): W2b — smalt.gen task-ification
lands, replaces mix.exs alias chain`), d615661 (`chore(projection): W2b
ggen_igniter manifest + receipt ledger for the 6-artifact sync`), 650a8ff
(`chore(spc): regen spc-bands from spc_gate.py`). No remaining I1 work; this
order is recorded DONE and is the dependency anchor for I3's witnesses.

## WO-2 — court-x2 two-green gate (I20)

Run `just court-x2` until two consecutive green runs; receipt at
`docs/jira/v26.10.17/receipts/` with the judge log embedded. Receipt naming:
**do NOT use `r216`** — that name is taken in the v26.10.16 window
(`v26.10.16/receipts/r216-court-x2-run8-red.md`); pick a fresh, descriptive
name (e.g. `rNNN-court-x2-two-green.md`). The v26.10.16 terminal court-x2
closed typed-RED (environment/contention class, zero mix-test failures) — this
window's close condition is an honest two-green or an honest typed RED, never
a faked pass. All other receipt-gated orders queue behind this gate.

## WO-3 — receipts, GAP flips, KD flips (I2/I3/I4, receipt-gated)

- I2: standing-line receipts for every landed change, real output embedded;
  `receipt_index.py` SUSPECT flag is the standard, not an insult.
- I3: KD witness receipts over the I1 landing and any in-flight `lib/` diffs
  (working tree currently carries `arm_gateway/router.ex`, `auth/bearer.ex`,
  `kd79_blob_apiversion_wire_test.exs`, `kd87_sts_leading_empty_segment_test.exs`).
- I4: GAP token flips in `docs/WIRE_PARITY.md` — receipt-gated only; GAP(name)
  disappears only with a closing receipt.
- **`kd_flip.py --apply` is coordinator-only at wave end**, gated on witness
  receipt mtime > shim mtime. No hand-flipped rows.

## WO-4 — version bump (STRICTLY after WO-2 two-green)

Owner: I20 (freeze lane), serialized, never concurrent with surface lanes.

- `mix.exs:4` `@version` → `"26.10.17"`.
- `workspace/package.json:3` version `26.10.14` → `26.10.17`.
- `semanticEpoch`: regenerate via the Canonical rider projection — NOT
  hand-edited (generated artifact; regen not patch).
- `CHANGELOG.md`: add `## [26.10.17] - 2026-10-17 — UNRELEASED` section.

## WO-5 — NEXT_WINDOW full mint (I19, at wrap)

Replace the `NEXT_WINDOW.md` stub (stale-by-default header) with the full
next-window mint during the wrap sequence, after court-x2 verdict, receipt
index regen, and the fin-sweep artifact regeneration
(`receipt-index`, `bench-report`, `sdk-matrix-md`, `gen-error-codes`).
`just docs-dod-check` must pass before wrap is declared.
