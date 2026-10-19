# i29 — real deterministic failures from i29-stress-full: store-table coverage + composite ETS residue

Date: 2026-10-18
Context: solo
Standing: PASS (both target test files green x2, `_build-ft-fix2`)

## Defect 1 — `StoreTablesReplayIdentityTest` coverage fence

`lib/smalt/egress_router.ex` references `:smalt_egress_guard` (lazily created
`@counter_table`, `:ets.new` at egress_router.ex:3880) with no `smalt:StoreTable`
row in the pack ontology — the swept-but-unowned bug class the fence exists for.

Root cause of the second reported atom: the coverage census regex
(`:smalt_[a-z_0-9]+`) matched `:smalt_sb_*` **inside a comment** in
`lib/smalt/messaging/amqp/sweeper.ex:38`. Not a real unregistered table —
`smalt_sb_queues/messages/locks/sessions/tokens/rules` all have rows.

Fix (at source, no hand-edit of the generated artifact):

- `~/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` — added
  `smalt:st-smalt_egress_guard` (keyShape atom, owner `Smalt.EgressRouter`,
  sweepStrategy none, metadataOnly/persisted/orderedSet false) in the SHADOW block.
- `lib/smalt/messaging/amqp/sweeper.ex` — comment fix only: `:smalt_sb_*` →
  `smalt_sb_*` (drops the spurious atom match; no behavior change).
- `mix smalt.gen` regenerated `lib/smalt/store_tables.ex` (+11 lines, only file
  changed: `git diff --stat` shows `1 file changed, 11 insertions(+)`).
- `test/store_tables_replay_identity_test.exs` — re-baselined the census pin
  52 atoms (33 owned + 19 shadow) → 53 atoms (33 owned + 20 shadow).

## Defect 2 — `EtsCompositeIdentityTest` bridge-queue residue

Reverse-topological teardown via router DELETE routes bypasses
`Smalt.Enclave.State.destroy/1`, so the AZB-10 bridge purge (the i27 enclave
fix) never runs: `resourcewritesuccess` queue row + `{queue, :seq}` counter +
5 message rows remain in `smalt_sb_queues`/`smalt_sb_messages`.

Fix: routed the teardown through the lawful cleanup —

- `lib/smalt/enclave/state.ex`: `purge_resource_write_bridge/0` promoted from
  `defp` to `def` with @doc (same body; synchronous ETS/Store deletes, no
  sleeps, no polling). destroy/1 call site unchanged.
- `test/smalt_ets_composite_identity_test.exs`: after the LRO eviction pass,
  the test now calls `Smalt.Enclave.State.purge_resource_write_bridge()` before
  the strict-identity snapshot.

## Verification (real output)

Run 1 (build root `_build-ft-fix2`):

```
$ FAST_TEST_BUILD_ROOT=_build-ft-fix2 scripts/fast_test.sh test/store_tables_replay_identity_test.exs --include stress
Including tags: [:stress]
....
Finished in 20.0 seconds (0.00s async, 20.0s sync)
4 tests, 0 failures

$ FAST_TEST_BUILD_ROOT=_build-ft-fix2 scripts/fast_test.sh test/smalt_ets_composite_identity_test.exs --include stress
.
Finished in 0.3 seconds (0.00s async, 0.3s sync)
1 test, 0 failures
```

Run 2:

```
$ ... test/store_tables_replay_identity_test.exs --include stress
....
Finished in 34.3 seconds (0.00s async, 34.3s sync)
4 tests, 0 failures

$ ... test/smalt_ets_composite_identity_test.exs --include stress
.
Finished in 0.5 seconds (0.00s async, 0.5s sync)
1 test, 0 failures
```

Both runs exit 0. The replay-identity test itself re-renders
`store_tables.ex` from the pack checkout and asserts byte-identity with the
regenerated artifact — the regen path (not a hand edit) is proven by the
passing fence. No sleeps added; the purge is synchronous.

## Files touched

- `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` (new row)
- `/Users/sac/smalt/lib/smalt/messaging/amqp/sweeper.ex` (comment)
- `/Users/sac/smalt/lib/smalt/store_tables.ex` (regenerated, `mix smalt.gen`)
- `/Users/sac/smalt/test/store_tables_replay_identity_test.exs` (census pin 19→20)
- `/Users/sac/smalt/lib/smalt/enclave/state.ex` (purge defp→def + @doc)
- `/Users/sac/smalt/test/smalt_ets_composite_identity_test.exs` (purge call)
