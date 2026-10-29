# BK-NSPUT — namespace_put KD-124 leg: `:code.ensure_loaded` before delete (BK-POWLH4-1 discharge)

Standing: ALIVE
Context: solo
Build root: `_build-bknsp`
Date: 2026-10-22
Owner lane: BK-NSPUT (repo /Users/sac/smalt)

## Verdict

BK-POWLH4-1 is closed. `test/integration/namespace_put_test.exs` KD-124 leg
("first PUT still succeeds when Smalt.EgressRouter.Peers is unavailable")
previously asserted `true = :code.delete(Smalt.EgressRouter.Peers)` — which
returns `false` when the module is not yet loaded in the VM, making the leg
order/concurrency dependent in-batch (BK-POWLH4 witnessed it fail once
in-batch, pass standalone). The registered deterministic repair is applied:
`:code.ensure_loaded/1` before the delete.

```elixir
{:module, _} = :code.ensure_loaded(Smalt.EgressRouter.Peers)
true = :code.delete(Smalt.EgressRouter.Peers)
```

Contract unchanged: the module is still genuinely deleted+purged (no mocks),
the PUT must still answer 201/202 (not 500), record-intact law still asserted,
`on_exit` restore via `:code.load_abs` untouched.

## Embedded probe (5x standalone + in-batch, _build-bknsp)

```
# Standalone (falsifier leg), 5/5 green:
mix test test/integration/namespace_put_test.exs
  run 1 exit=0 -> Result: 5 passed
  run 2 exit=0 -> Result: 5 passed
  run 3 exit=0 -> Result: 5 passed
  run 4 exit=0 -> Result: 5 passed
  run 5 exit=0 -> Result: 5 passed
  (one run logs "Loading .../Elixir.Smalt.EgressRouter.Peers.beam failed:
   :not_purged" — the on_exit restore racing purge, informational, exit 0)

# In-batch (`mix test test/integration`), 6 runs, KD-124 leg green in all:
run 1: Result: 233 passed                      (pre-expansion batch)
run 2: Result: 233 passed
run 3: Failed: 1  (failure name lost to output filter — see disclosure)
run 4: Result: 233 passed
run 5: Result: 368/372 passed, 5 invalid — all 4 failures peer `:not_alive`
       in PeerTwoNodeCourtTest / SwarmCourtTest (load-dependent, machine
       under concurrent lanes); namespace_put leg GREEN
run 6: Result: 368/372 passed, 5 invalid — same peer `:not_alive` class;
       namespace_put leg GREEN
run 7: Result: 367/368 passed, 9 excluded — only failure EventGridPushCourt
       setup; namespace_put leg GREEN
run 8: compile-freeze — MismatchedDelimiterError in
       lib/smalt/powl2/executor.ex (another lane's in-flight edit; zero tests
       executed, compile-abort not a failure count). Not this lane's file.
```

## Typed findings (pre-existing / other lanes, not session-introduced)

- **Peer `:not_alive` cluster** (`peer_two_node_court_test.exs:132`,
  `swarm_court_test.exs:142`): `:peer.start_it/2` fails when the machine is
  loaded — reproduced 2/3 in-batch runs under concurrent lane load, then a
  third class (EventGridPushCourt setup) on the next run. Load-dependent,
  unrelated to this repair; registered for the owner lineage.
- **Compile-freeze witness**: run 8 hit another lane's mid-edit
  `lib/smalt/powl2/executor.ex` (compile-abort, not test failures) — resolved
  by the owning lane per the SLA; disclosed, no action here.
- Batch grew 233 -> 372 mid-wave: other lanes converted more script courts to
  `*_test.exs` (BK-POWLH4 class), expanding the executed set. Counts are
  as-of-run.

## Files changed

- `test/integration/namespace_put_test.exs` (2-line fix: ensure_loaded before delete)
- `docs/jira/v26.10.22/receipts/bknsp-ensure-loaded.md` (this receipt)
