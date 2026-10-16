# Receipt — V261014-18 (lane 18): Mutation Courts

- **Date:** 2026-10-15
- **Lane:** 18 of 20, canonical checkout `/Users/sac/smalt`
- **Work order:** `docs/jira/v26.10.14/18-mutation-courts.md`
- **Owned files (only these touched):**
  - `test/wire_tier_refusal_sweep_test.exs` (NEW)
  - `test/egress_dispatch_test.exs` (engine-kill court describe appended; nothing else changed in the file)
  - `docs/BENCHMARKS.md` (receipt rows + one-shot stamps appended)
  - this receipt

## What landed

1. **Wire-tier refusal sweep** (`test/wire_tier_refusal_sweep_test.exs`, 3 tests):
   - enumerates `Smalt.Registry.admitted_resource_types()` dynamically (tripwire `>= 30`; 38 at run time) — zero hardcoded counts/names;
   - boots real Store + Bandit ARM router on an ephemeral port; real HTTP over raw `:gen_tcp`;
   - per-type ARM path resolution from the type's segment shape (generic 3-segment route / child routes / parented-child chains created with conforming payloads via the real router) — no copied table;
   - malformed payload = lens-2 conforming generator inverted (drop a required top-level property); asserts per type `400 InvalidResourceShape` + target `AshGraphLaw.Enforcement`, never 422, never 2xx;
   - conforming contrast row (`Microsoft.Compute/disks`): PUT -> 201, GET -> 200 (vacuity guard);
   - `content-type: application/json` required on every probe (measured: without it Plug leaves `body_params` empty and the location minCount fires on a CONFORMING payload — parents refused at setup).

2. **Engine-kill court** (new describe in `test/egress_dispatch_test.exs`):
   - BEFORE: real `:gen_tcp` GET /dbs -> 200 on the loaded `Smalt.DataPlane.Cosmos` engine;
   - KILL: beam file renamed + `:code.purge` + `:code.delete`; `refute Code.ensure_loaded?/1`;
   - same request -> 503 + `RouteNotReady`; `assert == 503` and `refute status in [200, 201]` (the law stated in the failure message);
   - RESTORE: beam renamed back + `Code.ensure_loaded/1` -> 200 (non-vacuity);
   - isolation: kill against an isolated child tree (private Store + Bandit, ephemeral port) booted in-test; module + beam restored in-test AND in `on_exit` (detached-state discipline of the :1523 class — no shuffled sibling inherits a purged engine or a stopped shared tree).

## Verification (real output)

- `mix test test/wire_tier_refusal_sweep_test.exs` -> **3 tests, 0 failures** (2026-10-15 15:28 PT).
- `mix test test/egress_dispatch_test.exs --only engine_kill_court` -> **1 test, 0 failures (86 excluded)** (2026-10-15 15:33 PT).
- `mix test test/egress_dispatch_test.exs test/wire_tier_refusal_sweep_test.exs` -> 90 tests, 5 failures — ALL FIVE PRE-EXISTING: re-run with the court excluded
  (`mix test test/egress_dispatch_test.exs --exclude engine_kill_court`) shows the same **86 tests, 5 failures**, so the failures are order-dependent collateral
  in the pre-existing suite (the cross-file shared-Store/ETS contention class already documented in DEV_LOOP refresh 6), NOT session-introduced. The five:
  typed engine errors at exact status (:1390), lens7 ledger/event/blob (:1618), lens7 cosmos read (:1556), lens7 key vault (:1577), cosmos store_not_ready (:1498).
- No `lib/` file modified. No git state changes. One file-ownership slip is disclosed: a mid-Edit truncation of `test/egress_dispatch_test.exs`'s tail was
  repaired in the immediately following edit; the final on-disk tail matches the pre-lane content byte-for-byte in the untouched region (verified by re-read).

## Found defects (filed, NOT patched — lib/ out of scope)

- **V261014-18-D1** — `Microsoft.Network/networkSecurityGroups`: NsgShape has no required paths and `sh:closed false`, so the GraphLaw validator admits ANY
  payload; a malformed NSG PUT is **admitted 201** on the wire. Surfaced by the sweep as exactly the work order's Gap-1 failure class ("a type slipping
  through with 422/500/202 is invisible to both layers" — here: 2xx). Pinned in-test via a dynamically-derived shapeless set (asserted positively, never
  silently skipped); tightening the shape flips the row to the 400-law.
- **V261014-18-D2** — `Microsoft.Network/privateDnsZones/virtualNetworkLinks`: admitted Registry type with NO ARM PUT route; azurerm-form path falls through
  to the catch-all, answering `404 RouteNotFound` before the shape gate runs. The type is unreachable, its shape never enforced on the wire. Fix shape:
  a `handle_child_put/5` child route, same pattern as the vault-keys route.

## First-run disclosures

- Engine-kill court first run FAILED on its own refute: purge+delete alone is not a kill — `Code.ensure_loaded?/1` reloads from the on-disk beam. Court
  corrected to hide the beam (Purview-test mechanics); no lib/ change; disclosed in `docs/BENCHMARKS.md`.
- Sweep setup first run FAILED: parent-chain conforming PUTs refused 400 because probes lacked `content-type: application/json` (Plug left `body_params`
  empty; the location minCount fired on conforming payloads). Fixed in the test only; disclosed here.

## §3.3 probe-protocol decision (documentation)

DEFER full-court upgrade of the six probes; stamped as dated one-shot receipts in `docs/BENCHMARKS.md`
("one-shot — not full-court protocol"; none labeled "court"). Full-court upgrade = bounded follow-up V261014-18a if pursued.

## Benign noise

Spark DSL warnings in test output are expected refusals from `ash_extension` `generated_verify.ex`, deliberately exercised by
`test/ash_extension_test.exs` (`compile_refused`). Not filed, not silenced.

## Standing

- Sweep: NON-VACUOUS (contrast row admitted 2xx while 36/38 types refuse per law; 2 defect rows asserted explicitly).
- Engine-kill court: NON-VACUOUS (BEFORE 200 / KILL 503 RouteNotReady / RESTORE 200).
- Both acceptance tests green under plain `mix test <file>` invocation; the combined-file run's 5 failures are pre-existing order-dependent collateral
  (verified by exclusion run), not caused by this lane.
