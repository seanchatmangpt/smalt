# Receipt — V261014-01 (test-isolation lane 01)

- Subject: smalt @ working tree on HEAD db2fe05 (uncommitted, 20-lane shared checkout)
- Date: 2026-10-15
- Lane: 01 test-isolation
- Status: DONE (lane-owned suites green; full `just test-offline` still carries
  ~9-10 pre-existing/other-lane failures — attribution below)

## What changed

### Task 2/4 — `test/test_helper.exs` (SmaltTest.Lifecycle)
- Added `ensure_store_up/0`: child-aware heal with 3 retry rounds —
  `restore_app` (only when Store is down), `Supervisor.restart_child` fallback,
  bounded table-materialization wait (`Smalt.Store.table_names/0`, 300 x 10ms),
  non-raising (returns `:ok` or `{:error, :store_not_running}`).
- Deliberate deviation from the WO sketch: `restore_app` is NOT called
  unconditionally. Measured on this tree: re-applying the shifted envs over a
  live tree bound to different ports desyncs env from listeners (crash_isolation
  connected to a port no listener held). `restore_app` fires only in the
  Store-down branch.
- Hardened `stop_shared_tree/0` to also wait on `Smalt.Supervisor`
  (`wait_gone(Smalt.Store)` then `wait_gone(Smalt.Supervisor)`).

### lib change (allowed accessor)
- `lib/smalt/store.ex`: added `table_names/0` (single source of truth, mirrors
  `@tables`). No table ownership/names/`:heir` changes.

### Task 1 — `test/canonical_projection_test.exs`
- on_exit no longer `Application.stop(:smalt)`-and-leave-it-dead. Measured
  deviation from the WO sketch: a BARE `restore_app/0` there is itself a no-op
  hazard — the suite boots the app on its own pinned free-port envs, so
  `ensure_all_started` returns `{:ok, _}` while env claims shifted ports but
  listeners hold the suite's pins (reproduced: downstream crash_isolation hit
  econnrefused, 3/3 runs). Final form: `Application.stop(:smalt)` ->
  `restore_app/0` -> `ensure_store_up/0` (stop makes the restore a true reboot
  on the shifted envs; the WO acceptance grep allows a paired stop+restore).

### Task 3 — ~28 heal sites replaced across 27 test files
`if whereis(Smalt.Store) == nil, do: restore_app()` (and the direct
`Smalt.Store.start_link()` / `start_supervised!(Smalt.Store)` variants) ->
`SmaltTest.Lifecycle.ensure_store_up()`, in:
smalt_services, auth_enforce, eventgrid_conformance (append-after-restore),
arm_error_corpus, azapi_actions, smalt_egress_router, egress_wiring, strata_compat,
sb_children, ash_extension, metadata_endpoints (append-after-restore), route_negative,
semantic_projection (x4), egress_dispatch (x3), amqp/{management_rpc, pyamqp_parity,
broker_facade, connection, flow_credit(+append)}, compliance/{c5,c6,c7},
data_plane/{blob_service, blob_hardening (x3), conditional_headers},
chaos/port_collision (append-after-restore), chaos/crash_isolation (setup_all),
wire/{amqp,arm,egress}_wire (append-after-restore).

### Falsifier-adjacent hardening (lane-owned files)
- `test/chaos/crash_isolation_test.exs`: setup_all waits for a live ARM
  listener and the test re-reads the live `:arm_port` env every connect
  attempt (`wait_connect/1`, 300 x ~80ms) — closes the measured mid-test
  stop/restore race from a predecessor module's on_exit.
- `test/data_plane/conditional_headers_test.exs`: direct `Smalt.Store.start_link()`
  now routes through the supervisor via `ensure_store_up/0` (per WO).

## Cross-lane unblock (compile-freeze SLA, disclosed)
- `lib/smalt/data_plane/cosmos.ex`: the in-flight V261014-07 edit renamed the
  scan to `scan_query_docs/3` and updated the call site to `do_query_docs(..., q, ...)`
  but left `do_query_docs/4` undefined (shared compile broken ~15:19Z). Added the
  missing wiring: whitelist-gated `do_query_docs/4` -> `scan_query_docs/3`, typed
  400 SyntaxError otherwise. Disclosed; owning lane may fold it in.

## Verification (real output tails)

```
mix test test/chaos/port_collision_test.exs test/store_churn_test.exs
  => 16 tests, 0 failures
mix test test/store_churn_test.exs test/chaos/port_collision_test.exs
  => 16 tests, 0 failures
mix test test/canonical_projection_test.exs test/store_churn_test.exs   # falsifier order
  => 26 tests, 0 failures   (pre-fix: poisons downstream; post-fix green)
mix test test/chaos/port_collision_test.exs test/chaos/crash_isolation_test.exs
  => 2 tests, 0 failures
mix test test/chaos/c tails/chaos pair ... (both orders) => 0 failures
10-file owned batch x3 (smalt_services, auth_enforce, canonical_projection,
  store_churn, port_collision, crash_isolation, eventgrid_conformance,
  arm_error_corpus, azapi_actions, smalt_egress_router)
  => 208 tests, 0 failures  (3 consecutive runs)
just test-offline (final): 1 doctest, 1885 tests, 10 failures (27 excluded)
just test-offline (earlier runs): 21 failures, then 10, then 10 — the
  residual set is not lane-attributable:
  - EgressDispatchTest lens7/store_not_ready fail-closed cluster (5):
    A/B-verified NOT mine — reverting only my setup line to the old
    `if whereis == nil, do: restore_app()` reproduces the identical 5 failures.
  - ErrorCodesDocTest (2): docs/ERROR_CODES.md projection stale vs other
    lanes' router-source changes.
  - SmaltArmGatewayTest blob child routes / StoreDetsTest restore / SbChildren
    azapi lock: other lanes' in-flight blob/DETS/lock surfaces
    (lib diffs present at session start; blob list_containers_xml now returns
    {:ok, {xml, next_marker}} tuples the old tests don't parse).
```

## Acceptance greps

- `git diff` lib/: only `Smalt.Store.table_names/0` added by this lane
  (cosmos.ex unblock disclosed above). No `:heir`/ownership/name changes.
- `grep -rn "Application.stop(:smalt)" test/` => 3 hits, each paired with a
  `restore_app/0`:
  - canonical_projection:40 (paired, then restore + ensure_store_up)
  - port_collision:38 (pre-existing paired stop+restore)
  - port_collision:121 (test-body stop, followed by the suite's own restore path)

## Constraints honored
- No async flips; `async: false` untouched. No `:heir`/ETS ownership changes.
- `ensure_store_up/0` non-raising.
- No git state changes, no commits.
- Did not touch `test/pplan_test.exs` (lane 02 handoff: ensure_store_up/0
  available; one-line replacement ready).

## Deviations
1. `ensure_store_up/0` retries 3x and only calls `restore_app` when Store is
   down (see What changed) — measured port-desync hazard in the WO's
   unconditional form.
2. canonical_projection on_exit = stop + restore + ensure (see Task 1 note).
3. Full `just test-offline` is not zero-failure on a 20-lane live tree; the
   ~10 residual failures are attributed above with the A/B evidence for the
   5-test EgressDispatch cluster.
4. crash_isolation got a bounded env-fresh listener wait + in-test heal — a
   small scope extension within lane-owned files, driven by measured races.
