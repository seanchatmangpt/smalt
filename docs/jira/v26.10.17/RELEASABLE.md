# RELEASABLE — v26.10.17 go/no-go gate checklist

Standing: **NOT RELEASABLE** (operator go/no-go page; prepared 2026-10-17,
readings re-derived on this tree — re-run the commands before acting on any row).
Declaring RELEASABLE requires every row GREEN and the version bumped (WO-4).

As-of 2026-10-17 (post repair-wave re-derivation): gate 3 flipped **GREEN 4/4**
(B1 CLOSED), gate 4 re-witnessed GREEN, gates 1/2/5 unchanged in kind —
overall still NOT RELEASABLE pending gate 1 two-green only.

| # | Gate | Command | Current standing | What flips it |
|---|---|---|---|---|
| 1 | court-x2 two-green | `just court-x2` | **RED — TYPED-RED terminal** (r240→r241; attempt 3 of 3, `tmp/court-x2-v17-wrap3.log` `COURT_X2_RC=1`; 35 completed invocations, 0 two-green). Faces at close: fence 10 `test/affidavit_wasm_failclosed_test.exs:502` **PERSISTENT-FLAKE** (repeats under court load, solo-green); EgressDispatch ETS `:smalt_subscriptions` teardown race (:1474/:975); Lro :543 op-record miss — all contention-class, all solo-green. **Attempt 4 queued post-repair-wave**; r241's named repair surfaces have since LANDED: i21-fence10-fix, i21-ets-race-fix, i21-lro-face, i21-brokerfacade-sweeper, i21-blob-budget, i21-churn-budget, i21-leak-court-delta (all under receipts/, 2026-10-17). Preconditions pending: fresh `just quiet-check` GREEN (currently RED, row 5) + `just quiesce` warm-up GREEN, then the gate. | Real two-green receipt (both legs 0 failures). Preconditions mechanical: `just quiet-check` clear + `just quiesce` warm-up GREEN before the gate — a warm-up failure is a stop signal, not a hurdle (r241). |
| 2 | WO-4 version bump | edit `mix.exs` `@version` + `workspace/package.json` | **BLOCKED on gate 1** — never executed. `mix.exs:4` = `"26.10.16"`, `workspace/package.json:3` = `"26.10.14"` (re-read 2026-10-17 post repair-wave). | Strictly gated on gate 1 two-green receipt. Bump both files, then re-verify no-bump falsifier clears (FINAL.md falsifier block). See WO4-RUNBOOK.md. |
| 3 | publish-dry | `just publish-dry` | **GREEN 4/4** — B1 CLOSED. Witness: [r244](receipts/r244-publish-record.md) (2026-10-17): gate1 hex.build PASS (package checksum `88210b01…`), gate2 inner-tar keys PASS (0 matches), gate3 leak grep PASS (0 hits), gate4 error-codes PASS. Enabled by ex4pm 26.10.8 published to hex; smalt `mix.exs` flipped hex-only `{:ex4pm, "~> 26.10.8"}` (override dropped); mix.lock resolves ex4pm 26.10.8 from `:hexpm`, checksum `d507fd16…`. PUBLISH_RECORD.md B1 addendum applied. | — (closed; re-run after any packaging/deps change) |
| 3a | — B1 ex4pm dep | `mix hex.build` | **CLOSED** — was REFUSED (ex4pm path dep, typed HEX_BUILD_REFUSED); now hex-only dep, hex.build exit 0 per r244. | — |
| 3b | — B2 packaged-file prod compile | — | **FIXED** (lane G2 guard, re-run evidence in PUBLISH_RECORD). | — |
| 3c | — B4 checksum | — | **FIXED** (package built + checksum on record, r244). | — |
| 3d | — B5/B6 naming | — | **ADVISORY** ("ARM-style" prose; no mechanical hex gate). | — |
| 4 | docs-dod-check | `just docs-dod-check` | **GREEN — exit 0** (re-run on this tree 2026-10-17 post repair-wave; 54/54 paths OK, every receipt path named in docs exists on disk). | Stays green by regeneration discipline; re-run after any docs/receipt edit. |
| 5 | quiet-check | `just quiet-check` | **RED right now** (re-run 2026-10-17): stray beam pid 17834 cwd `the ex4pm sibling checkout (deps/rdf)` (not this checkout) + concurrent beam suite + load 11.6/13.8 above threshold — transient machine-state faces, not a tree defect. Prior green witnesses: attempt 3 preconditions, load 6.3 / 9.0 < 16 (r241). | Clear the foreign beam (port_sweep or kill its owner), wait for load < threshold, no concurrent suites; re-run GREEN. This is a precondition gate for #1, not a release gate by itself. |

## Notes

- Terminal window state is honest TYPED-RED (r243 terminal receipt; WRAP_LEDGER.md).
  No TWO-GREEN claim exists in this window's artifacts; the RELEASABLE declaration
  is receipt-gated on a future real two-green court.
- Naming-sweep reads 1 violation / 46 allowed (`RECEIPT_CONTEXT_LAW.md:3` absolute
  path) — advisory, parked to next window; not a RELEASABLE row per the gate list.
- No git operations performed preparing this page.

## See Also

[r240](receipts/r240-court-x2-attempts12-typed-red.md) ·
[r241](receipts/r241-court-x2-attempt3-typed-red.md) ·
[r243](receipts/r243-terminal-receipt.md) ·
[r244](receipts/r244-publish-record.md) · [WRAP_LEDGER.md](WRAP_LEDGER.md) ·
[FINAL.md](FINAL.md) · [NEXT_WINDOW.md](NEXT_WINDOW.md) ·
[../v26.10.16/PUBLISH_RECORD.md](../v26.10.16/PUBLISH_RECORD.md)
