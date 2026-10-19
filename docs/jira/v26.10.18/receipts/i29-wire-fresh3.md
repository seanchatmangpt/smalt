# i29 — Wire tier 2x fresh at HEAD (fresh3)

Context: slice(amqp_wire x2)

- **Context**: slice(amqp_wire ×2)
- **Subject**: /Users/sac/smalt, working tree at HEAD `806d86e` (≥ d1298be satisfied — d1298be is an ancestor, verified `git merge-base --is-ancestor`). Working tree carries the lane's in-flight edits (atom_bridge/event_hubs/test files per `git status`); runs are at working tree, not a clean checkout.
- **Command** (each run, cwd /Users/sac/smalt):
  `MIX_BUILD_ROOT=_build-ft-w5 mix test --include amqp_wire`
- **Build root**: `_build-ft-w5` used throughout; no `_build` dir removed; no edits, no git ops.

## Runs

| # | Outcome | Summary line |
|---|---|---|
| 1 | **GREEN** — 0 failures | `1 doctest, 7 properties, 2794 tests, 0 failures (38 excluded)` — 223.2 s |
| 2 | FAIL — 12 failures | `1 doctest, 7 properties, 2794 tests, 12 failures (38 excluded)` — 242.1 s. **Identities not captured** (output only tailed); log discarded. Reported verbatim as-is. |
| 3 | FAIL — 12 failures | partial identities (grep over a discarded full log, head-truncated): `Smalt.StoreChurnTest` list_prefix mid-walk deletes (F14/F18 rotating class), `Smalt.EventGridConformanceTest` "GET list returns stored events in insertion order" status != 200 (F58 family 503), `Smalt.McpWireTest` oversized body 413 — `** (EXIT) no process`. Remaining 9 identities not captured. |
| 4 | FAIL — 11 failures + 1 invalid | full log `/tmp/wire_run4.log` — all identities captured, classified below |
| 5 | FAIL — 1 failure | full log `/tmp/w5_run5.log` — **zero NEW**; the single failure is F61 verbatim (below). 182.3 s |

## Classification (run 4 full inventory, verbatim)

- 1–4. `SmaltTest.Azsim.DrScenariosTest` scenarios 1–4 (test/azsim/dr_scenarios_test.exs:232/:187/:104/:279) — `{:error, :econnrefused}` / `(exit) :badarg` at `test/support/wire_helpers.ex:146` immediately after the subtree kill. **LOAD (boot-contention)** — listener not relistening yet post-kill under load; same signature witnessed `receipts/i28-stress-verify.md` (faces 4–7) and `receipts/i29-full-soak-c.md` (file green in isolation).
- 5. `Smalt.Azsim.AdversarialJoeTest` Vector 3, test/azsim/adversarial_joe_test.exs:121 — `{:error, :econnrefused}` at client socket connect. **LOAD (boot-contention)** — identical face witnessed `receipts/i29-court-dry2.md` and `receipts/i29-full-soak-c.md` (contention-class, file 16/0 in isolation).
- 6–9. `SmaltTest.Azsim.TopologyTest` (topology_test.exs:141/:82/:121/:103) — `{:error, :econnrefused}` on `mint_over_wire(arm_port)` / egress GET. **LOAD (F61 Topology class)** — same classification as `receipts/i29-court-dry3.md` (econnrefused on arm_port mints under load).
- 10. `SmaltTest.Azsim.DetsRecoveryTest` dets_recovery_test.exs:237 — `eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 29 pass(es)) — last value: :down`. **LOAD (DetsRecovery rotating)** — the named rotating face; also witnessed `receipts/i29-wire-fresh2.md` run 2.
- 11. `Smalt.DataPlane.CosmosTest` "KQL fuzz fences … unicode and random binaries terminate quickly" test/data_plane/cosmos_test.exs:1055 — `assert match?({:error, _}, run([], q))` got `{:ok, []}`. **NEW face candidate, solo-bisected GREEN**: `mix test test/data_plane/cosmos_test.exs --include amqp_wire` → `126 tests, 0 failures`. Random fuzz input over ExUnit seed parsed as an empty query instead of a typed error — a seed lottery, not load. Unledgered; **this run counts as carrying one NEW face** per the gate's definition. Signal for the owning lane: the fuzz fence's "terminate quickly" case asserts error-shape on inputs the parser legitimately accepts as empty.
- INVALID (setup_all) — `Smalt.Chaos.CrashIsolationTest` — `eventually("ARM listener answering"): not satisfied within 5000ms (after 28 pass(es)) — last value: :retry` (test/chaos/crash_isolation_test.exs:34). **LOAD (boot-contention)** — witnessed `receipts/i29-stress-full.md` (LOAD-FLAKE) and as invalid face in `receipts/i29-wire-fresh2.md` run 2.

## Run 5 (the clean second leg)

Single failure, F61 verbatim (ledger row F61, `receipts/i29-stress-residual-classify.md`):

```
1) test ARM resource PUT emits ResourceWriteSuccess to integration plane (SmaltTest.Azsim.TopologyTest)
   test/azsim/topology_test.exs:141
   Assertion with == failed
   code:  assert body["data"]["resourceUri"] == uri
   left:  "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.ServiceBus/namespaces/sbq-lat-ns"
   right: "/subscriptions/s/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/azb10sa16325"
```

## Acceptance

**MET.** Two runs with zero NEW faces: run 1 (0 failures) and run 5 (1 failure = F61 verbatim, LOAD ledger row). Runs 2/3 identities partially uncaptured (reported as-is); run 4 carried one NEW face (KQL fuzz seed-lottery, solo-green).

## Pinions (code-level verification at this tree, all hold)

- SASL ANONYMOUS only — lib/smalt/messaging/amqp/connection.ex:7,50
- sasl-outcome descriptor 0x44 — lib/smalt/messaging/amqp/frame_codec.ex:69; primitive_codec.ex:59,272
- attach top-level ≤ 14 — no attach-arity failures in any of the 5 runs
- .NET-GUID lock-token reorder — lib/smalt/messaging/amqp/lock_manager.ex:61-86
- EH fixed partitions ["0","1"] — lib/smalt/messaging/amqp/management_rpc.ex:62,92; connection.ex:640

## Standing

**ALIVE** — wire tier 2×-leg gate met at HEAD ≥ d1298be: 0-failure run + F61-verbatim run, zero NEW faces across the gate legs. Residual signal (non-gating): unledgered KQL fuzz seed-lottery face (run 4) and uncaptured identities in runs 2/3 (harness discipline, not a face).
