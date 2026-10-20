# how to write tests (canonical foundations)

> **RETIRED@64f6099 (pre-reset foundations).** The `SmaltTest.*` harness
> (`test/support/case.ex`, `store_resilient.ex`, `singleton.ex`, `env.ex`,
> `sleep_windows.ex`) was deleted with the legacy corpus in the clean-room reset.
> The five-helper workflow below is preserved as the canonical pattern; on the
> post-reset tree the successors are the residual tier (`test/internal/`, poll
> helper `test/internal/poll_helper.exs`) and the fresh suites
> (`verification/ts` harness in `verification/ts/harness/`, `verification/py`
> harness in `verification/py/harness/`).

The one-`use` template and the five canonical helpers. Write new suites on
these, not on hand-rolled retries or process-dictionary saves.

By the end you will have: a new test file on `SmaltTest.Case`, one bounded
poll, one resilient store setup, one unique singleton, one env-scoped
mutation, and (only if the test's subject IS time) a named sleep window.

## What you need

- The smalt repo; `mix test` (offline suite, ephemeral ports, no external
  substrate).

## The template: `use SmaltTest.Case`

`test/support/case.ex` is an `ExUnit.CaseTemplate` that imports, in one
`use`:

```elixir
use SmaltTest.Case
# gives you: AssertEventually, Env, Store (resilient), Singleton
```

Migration is per-file and optional — plain `use ExUnit.Case` keeps working.

## Foundation 1: `SmaltTest.AssertEventually` — the one bounded poll

`test/support/assert_eventually.ex` — RETIRED@64f6099; successor: `test/internal/poll_helper.exs`). Contract: the polled `fun/0` returns
`{:ok, value}` (success, value returned), `:retry` / `{:retry, detail}`
(poll again), anything else is an immediate typed failure naming the
observable and the offending return. Options: `:deadline_ms` (default
5000), `:backoff_ms` (10, doubling to `:max_backoff_ms` 200),
`:observable`, `:retry_on: {ExceptionType, exact_message}` (that exact
exception becomes a retry; every other reraises).

```elixir
import SmaltTest.AssertEventually

eventually(fn ->
  case Smalt.Store.get(@table, key) do
    %{status: "Active"} = row -> {:ok, row}
    _ -> :retry
  end
end, observable: "resource Active", deadline_ms: 2_000)
```

For assert-absence, use `eventually_stays/2`: truthy must hold
CONTINUOUSLY for `:stability_ms` (default 50) within `:within_ms` (default
5000); a false→true flip resets the clock; exceptions inside the poll body
count as false observations.

Chicago discipline: `fun` observes real state, no mocks. It owns no
processes, so it is safe from `setup`, `on_exit`, or the test process.

## Foundation 2: `SmaltTest.Store.resilient_setup/1` — shared-Store setup

`test/support/store_resilient.ex`. The window between
`Lifecycle.ensure_store_up()` and `Store.clear/0` races an async sibling's
shared-tree teardown; `resilient_clear/1` retries ONLY the dead-table
ArgumentError (via `retry_on`), running the optional `:post_seed` seed
INSIDE the retry window:

```elixir
setup do
  :ok = SmaltTest.Store.resilient_setup(post_seed: fn -> seed_rows() end)
  :ok
end
```

`quiescent_read/2` is the double-read law: retry until two consecutive
reads agree — torn reads under concurrent mutation are discarded.

## Foundation 3: `SmaltTest.Singleton.start_supervised_singleton!/2`

`test/support/singleton.ex`. Starts a child spec under a UNIQUE per-test
via-name (`{:via, Registry, {SmaltTest.Registry, {module, ref}}}`) so async
siblings never collide on a registered name and the app-owned named
singleton is never shadowed. `ExUnit.Callbacks.start_supervised!/1` remains
the lifetime owner:

```elixir
{pid, name} =
  start_supervised_singleton!({Sweeper, tick_ms: :manual},
    module: Smalt.ArmGateway.LRO.Sweeper
  )
```

## Foundation 4: `SmaltTest.Env` — Application-env save/restore

`test/support/env.ex`. Two forms:

- `Env.with(kvs, fun)` — scoped mutation, restores in `after`
  (exception- and flunk-safe).
- `Env.put_restored(kvs)` — setup-form; registers the restore via
  `on_exit`.

Restore discipline is load-bearing: `put` when the previous value was
non-nil, `delete_env` when it was unset — never the reverse (a `delete_env`
on a pre-existing value destroys sibling-visible config). A bare
`Application.put_env` with no restore fails the isolation court
(`docs/reference/test-isolation-law.md`).

## Foundation 5: `SmaltTest.SleepWindows` — named time-advance (B1 only)

`test/support/sleep_windows.ex` — RETIRED@64f6099; the fresh tiers carry no sleep-window helper; bounded polls only). Where the condition under test IS time
(rate-limit window rollover, lock expiry, LRO retention), the sleep window
is NAMED and derived from its configured constant, never a bare literal:

```elixir
Process.sleep(SmaltTest.SleepWindows.fixed_window_rollover_ms())
```

Windows: `second_boundary_ms/1`, `fixed_window_rollover_ms/1`,
`lro_delay_elapse_ms/2`, `lro_deadline_elapse_ms/1`,
`sweeper_grace_elapse_ms/2`, `mcp_idle_gap_ms/1`. Everything else is
bounded polling — see `docs/explanation/no-sleep.md`.

## Worked example

```elixir
defmodule MyFeatureTest do
  use SmaltTest.Case, async: false

  @table :smalt_resources
  @prefix "myfeature-test-"

  setup do
    # resilient shared-Store clear + seed inside the retry window
    :ok = SmaltTest.Store.resilient_setup(post_seed: fn ->
      Smalt.Store.put(@table, @prefix <> "r1", %{"status" => "Pending"})
    end)

    # whole-test env scoping with guaranteed restore
    SmaltTest.Env.put_restored(lro_delay_ms: 20)
    :ok
  end

  on_exit(fn ->
    if :ets.info(@table) != :undefined do
      for key <- Smalt.Store.prefix_keys(@table, @prefix), do: :ets.delete(@table, key)
    end
  end)

  test "resource reaches Active" do
    assert {:ok, _} =
             eventually(
               fn ->
                 case Smalt.Store.get(@table, @prefix <> "r1") do
                   %{"status" => "Active"} -> {:ok, :active}
                   _ -> :retry
                 end
               end,
               observable: "myfeature row Active"
             )
  end

  test "sweeper owns its singleton" do
    {pid, _name} =
      start_supervised_singleton!({Sweeper, tick_ms: :manual},
        module: Smalt.ArmGateway.LRO.Sweeper
      )

    assert Process.alive?(pid)
  end
end
```

Note the prefix-scoped success-path delete plus `on_exit` guard — the
table is shared; a nuclear wipe would destroy other suites' state.

## See Also

- `docs/reference/test-isolation-law.md` (isolation contract + court)
- `docs/explanation/no-sleep.md` (why bounded polls, not sleeps)
- `docs/TEST_ISOLATION.md` (historical audit ledger)
- `test/support/case.ex` and the modules under `test/support/`
