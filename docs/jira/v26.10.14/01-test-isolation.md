# V261014-01 — Test isolation: repair the broken shared-Store heal path

- **Release:** v26.10.14
- **Lane:** test-isolation
- **Base:** uncommitted working tree on HEAD db2fe05
- **Status:** ready-for-work

## Objective

Eliminate the full-suite "shifting failures" flake class. The root cause is not
nondeterminism in production code — it is that the test suite's shared-repair
idiom is a no-op in exactly the situation it exists for:

1. `test/canonical_projection_test.exs:34-36` calls `Application.stop(:smalt)`
   in `on_exit` and **never restores**. Every module that runs after it in the
   same run observes a stopped app — failures appear to "shift" with module run order.
2. The ~20 conditional heal sites of the form
   `if Process.whereis(Smalt.Store) == nil, do: SmaltTest.Lifecycle.restore_app()`
   are ineffective after a `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)`:
   the app is still *started*, so `restore_app` (`test/test_helper.exs:96-103`)
   reduces to `Application.ensure_all_started/1` → `{:ok, _}` no-op, while
   `Smalt.Store` stays down (the `terminate_child` path used by
   `test/pplan_test.exs` lens7, ~line 2732, is manual and not counted against
   the supervisor's restart intensity, so nothing restarts it).
3. `stop_shared_tree` (`test/test_helper.exs:64-78`) waits only on
   `Smalt.Store` going away, not on `Smalt.Supervisor`/Bandit listeners — a
   TOCTOU lets the next module race a half-dead listener.
4. `test/chaos/crash_isolation_test.exs:19-24` and `test/smalt_services_test.exs:18`
   repair only conditionally — their guards check the wrong predicate (see 2).

Fix: one child-aware shared helper, `SmaltTest.Lifecycle.ensure_store_up/0`,
plus mechanical replacement of the broken heal sites.

## Files owned (this lane)

| File | Scope |
|---|---|
| `test/canonical_projection_test.exs` | replace `Application.stop(:smalt)` on_exit with `restore_app/0` (task 1) |
| `test/test_helper.exs` (`SmaltTest.Lifecycle`) | add `ensure_store_up/0`; harden `stop_shared_tree/0` (tasks 2, 4) |
| ~20 heal sites (list below) | replace `whereis`-guarded `restore_app()` calls with `ensure_store_up/0` (task 3) |

**NOT owned by this lane:** `test/pplan_test.exs` in-test bodies (lane 02).
This lane owns only the shared helper lane 02 will call.

## Tasks

### Task 1 — canonical_projection: restore, don't stop

`test/canonical_projection_test.exs:34-36`:

```elixir
on_exit(fn ->
  Application.stop(:smalt)
end)
```

becomes:

```elixir
on_exit(fn ->
  SmaltTest.Lifecycle.restore_app()
end)
```

`restore_app/0` re-applies the run's shifted envs (`@shifted`), which is the
documented shared posture (docs/TEST_ISOLATION.md section 2).

### Task 2 — add `SmaltTest.Lifecycle.ensure_store_up/0` (child-aware)

```elixir
@doc """
Child-aware guarantee that the shared Store GenServer is up under the shared
supervision tree, with all Store ETS tables materialized.

Unlike `restore_app/0` (a no-op when :smalt is *started* but Store was
Supervisor.terminate_child'd), this:
  1. ensure_all_started(:smalt) — covers the fully-stopped case;
  2. if Process.whereis(Smalt.Store) is still nil, restarts the child
     (ignore {:error, :already_present} / {:error, {:already_started, _}} —
     both are success for our purposes);
  3. waits (bounded, ~3s) until :ets.info/1 != :undefined for ALL Store
     tables, so callers never see the half-initialized window.
Idempotent and non-raising: returns :ok, or {:error, :store_not_running}
on a hopeless tree (never raises — safe from on_exit).
"""
def ensure_store_up do
  _ = restore_app()
  case Process.whereis(Smalt.Store) do
    nil -> restart_store_child()
    _pid -> wait_store_tables()
  end
end
```

- Table list read from `Smalt.Store`'s `@tables` (27 tables,
  `lib/smalt/store.ex:11-39`). Prefer adding a public `Smalt.Store.table_names/0`
  (single source of truth); otherwise duplicate the atom list in Lifecycle with
  a comment pinning it to `store.ex`. Do NOT change table ownership, names,
  or `:heir` (constraint).
- Wait loop polls `:ets.info(table) != :undefined` for every table plus
  `Process.whereis(Smalt.Store) != nil`, 10ms sleeps, ~300 iterations
  (matching `wait_gone/2`'s existing bound).
- Any `{:error, _}` from `restart_child` falls through to the table-wait,
  then re-checks `whereis`; on expiry return `{:error, :store_not_running}`.

### Task 3 — replace the ~20 broken heal sites

Every site matching `if <whereis on Smalt.Store>, do: SmaltTest.Lifecycle.restore_app()`
becomes `SmaltTest.Lifecycle.ensure_store_up()`. Sweep seed
(`grep -rn "whereis(Smalt.Store)" test/`):

- `test/smalt_services_test.exs:18`
- `test/auth_enforce_test.exs:21-22`
- `test/eventgrid_conformance_test.exs:58`
- `test/arm_error_corpus_test.exs:370`
- `test/azapi_actions_test.exs:437`
- `test/smalt_egress_router_test.exs:20`
- `test/egress_wiring_test.exs:254`
- `test/strata_compat_test.exs:302`
- `test/sb_children_test.exs:331-332`
- `test/ash_extension_test.exs:415`
- `test/metadata_endpoints_test.exs:76`
- `test/route_negative_test.exs:566`
- `test/semantic_projection_test.exs:9, 417, 462, 546`
- `test/egress_dispatch_test.exs:14-15, 840, 2079`
- `test/amqp/management_rpc_test.exs:279`
- `test/amqp/pyamqp_parity_test.exs:69`
- `test/amqp/broker_facade_test.exs:116`
- `test/amqp/connection_test.exs:31`
- `test/compliance/c6_oauth.exs:19-20`
- `test/compliance/c5_servicebus.exs:329`
- `test/compliance/c7_events.exs:35`
- `test/data_plane/blob_service_test.exs:38`
- `test/data_plane/blob_hardening_test.exs:11, 401, 1771`
- `test/data_plane/conditional_headers_test.exs:8` (uses
  `Smalt.Store.start_link()` directly — route through the supervisor instead)
- `test/chaos/port_collision_test.exs:44`
- `test/chaos/crash_isolation_test.exs:19-24` (currently checks
  `Smalt.Supervisor` only — unconditional `ensure_store_up/0` heals the
  Store-down-but-Supervisor-up entry state too)
- Full-tree restore points (`test/wire/*_wire_test.exs` on_exit,
  `test/amqp/flow_credit_test.exs:74-80`): keep `restore_app()`, append
  `ensure_store_up()` after it.

Mechanical rule: `restore_app()` whose *purpose* is "make Store usable for my
next assertion" (setup/test-body guards) → `ensure_store_up()`. `restore_app()`
whose purpose is "put the shared tree back for downstream modules" (on_exit) →
keep, optionally follow with `ensure_store_up()`.

### Task 4 — `stop_shared_tree/0` waits on the whole tree

`test/test_helper.exs:64-78` tail becomes:

```elixir
wait_gone(Smalt.Store)
wait_gone(Smalt.Supervisor)
```

Do not lengthen the `Supervisor.stop/3` timeout; only the wait tail changes.

### Task 5 — lens7 coordination (helper handoff only)

This lane does NOT edit `test/pplan_test.exs`. Deliverable to lane 02:
`SmaltTest.Lifecycle.ensure_store_up/0` is available for lens7's in-test
restore and its `on_exit` safety net (one-line replacement:
`SmaltTest.Lifecycle.ensure_store_up()`).

## Acceptance criteria

```bash
mix test test/chaos/port_collision_test.exs test/store_churn_test.exs
mix test test/store_churn_test.exs test/chaos/port_collision_test.exs
just test-offline   # x3, 0 failures each
```

- `git diff` shows no `lib/` changes except the optional
  `Smalt.Store.table_names/0` accessor.
- `grep -rn "Application.stop(:smalt)" test/` returns 0 hits without a paired
  `restore_app/0`.

## Constraints

- `async: false` semantics unchanged; no test flipped to `async: true`.
- No `:heir` or ETS table-ownership changes.
- `ensure_store_up/0` non-raising (on_exit-safe).

## Falsifier

A run whose module order places `CanonicalProjectionTest` BEFORE
`StoreChurnTest` must still pass:

```bash
mix test test/canonical_projection_test.exs test/store_churn_test.exs
```

On the pre-fix tree this fails (the stop-without-restore on_exit poisons every
downstream module). Confirm this order explicitly before declaring done.
