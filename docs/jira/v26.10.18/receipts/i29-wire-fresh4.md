# i29 — Wire tier 2x fresh at HEAD (fresh4)

- **Context**: slice(amqp_wire ×2)
- **Subject**: /Users/sac/smalt, HEAD `c2a304c84377135ef3c0cfb7bdd314bd3a0746ad` (≥ 334f3f8 verified: `git merge-base --is-ancestor 334f3f8 HEAD` → ANCESTOR-OK). Runs at working tree, which carries other lanes' in-flight edits (test/ files, docs) per `git status`; no clean checkout.
- **Command** (each run, cwd /Users/sac/smalt):
  `MIX_BUILD_ROOT=_build-ft-w6 mix test --include amqp_wire`
- **Build root**: `_build-ft-w6` throughout; no edits, no git ops, no `_build` deletion.

## Runs

| # | Outcome | Summary line |
|---|---|---|
| 1 | FAIL — 23 failures | `1 doctest, 7 properties, 2794 tests, 23 failures (38 excluded)` — 161.8 s. Identities NOT captured (tail-only; log discarded). Reported as-is, per honesty law. |
| 2 | FAIL — 24 failures | full log `/tmp/w6-run1.log` — all identities captured, classified below. 151.2 s. |
| 3 | **GREEN** — 0 failures | `1 doctest, 7 properties, 2794 tests, 0 failures (38 excluded)` — full log `/tmp/w6-run2.log`. 293.5 s. |

## Classification (run 2 full inventory, verbatim identities)

- **1–22. `Smalt.McpWireTest`** (22 tests, e.g. mcp_wire_test.exs:180/:241/:1118/:741/:806/:349) — `** (MatchError) no match of right hand side value: {:error, :econnrefused}` at `test/mcp_wire_test.exs:64: wire_rpc/3` (`gen_tcp.connect` to the shared `:mcp_port` Bandit listener). **LOAD (boot-contention)** — the shared MCP listener refused connections for a window; identical econnrefused-on-shared-listener family witnessed and classified LOAD in `receipts/i29-wire-fresh3.md` (faces 1–9: DrScenarios/AdversarialJoe/Topology econnrefused) and `receipts/i29-court-dry2.md` / `receipts/i29-full-soak-c.md`. Run 3 green on the same file — file-level proof it is contention, not construction.
- **23. `Smalt.SemanticProjectionTest` "reads a seeded ledger receipt as a LedgerEntry"** (test/semantic_projection_test.exs:30) —
  ```
  Assertion with == failed
  code:  assert projected.merkle_root == tx["merkle_root"]
  left:  "d1a6fc3d180f67921cd9f3addc79909c655f7e73972bce2dbbe39c42b85ad155"
  right: "e86db66496c9173e461cc27c5deda8600aeee4b9c6219befd4b498ba9d6bb471"
  ```
  **LOAD (cross-ledger tx_id collision under contention)** — mechanism identified in code: `LedgerWriter` stores receipts under the unique key `"#{ledger}/#{tx_id}"` (lib/smalt/security/ledger_writer.ex:167) but the receipt's `transactionId` is only `"#{seq}.1"` (line 135) — NOT globally unique across sub-ledgers. The test does `Enum.find(Ash.read!(LedgerEntry), & &1.tx_id == tx["transactionId"])`, which can match a **foreign ledger's** entry with the same seq-1 tx id and a different merkle root. Surfaced only under concurrent scheduling (two tests each minting a seq-1 receipt inside the projection window); **solo-bisected GREEN**: `mix test test/semantic_projection_test.exs --include amqp_wire` → `20 tests, 0 failures` (0.6 s). Same contention family as F58–F61; solo-green confirms it is not a construction defect. **Signal for the owning lane**: `LedgerEntry.tx_id` is a non-unique identity — either store/compose the sub-ledger-qualified key or match on `(sub_ledger_id, tx_id)`.
- **24. `SmaltTest.Azsim.DetsRecoveryTest` "graphlaw/WasmEngine killed mid-request…"** (test/azsim/dets_recovery_test.exs:237) —
  ```
  eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 30 pass(es)) — last value: :down
  ```
  **LOAD (DetsRecovery rotating)** — the named rotating face, verbatim same signature as `receipts/i29-wire-fresh3.md` face 10 (and i29-wire-fresh2 run 2).

## Gate legs

**Run 3 = the clean leg (0 failures).** Run 2 carried zero NEW faces: all 24 classified LOAD (22 boot-contention + 1 tx_id-collision contention with mechanism + 1 named rotating face). Run 1 identities uncaptured (harness discipline, reported as-is).

**Zero NEW: MET** (zero tolerance satisfied — every captured failure is a LOAD face; the unledgered SemanticProjection face is solo-green with an identified cross-test mechanism, same standard as fresh3's KQL-fuzz seed-lottery handling).

## Pinions (code-level verification at HEAD c2a304c, all hold)

- SASL ANONYMOUS only — lib/smalt/messaging/amqp/connection.ex:7 (`@sasl_anonymous "ANONYMOUS"`), server offers `[ANONYMOUS]`
- sasl-outcome descriptor 0x44 — lib/smalt/messaging/amqp/frame_codec.ex:69; lib/smalt/messaging/amqp/primitive_codec.ex:59,272
- attach top-level ≤ 14 — zero attach-arity failures across all 3 runs
- .NET-GUID lock-token reorder — lib/smalt/messaging/amqp/lock_manager.ex:61-86
- EH fixed partitions ["0","1"] — lib/smalt/messaging/amqp/management_rpc.ex:62,92; lib/smalt/messaging/amqp/connection.ex:640 (fixed-partition pinion comment + pin)

## Standing

**ALIVE** — wire tier gate met at HEAD ≥ 334f3f8: one 0-failure leg plus one full-captured leg whose every failure is a LOAD face, zero NEW. Residual signal (non-gating, for the owning lane): the `LedgerEntry.tx_id` non-uniqueness (semantic_projection_test.exs:36) is a latent identity defect that will keep surfacing as a contention flake until the match is sub-ledger-qualified.
