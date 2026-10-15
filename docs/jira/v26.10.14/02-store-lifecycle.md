# V261014-02 — Store Lifecycle: lens7 kill-window isolation + async killer audit

- **Release:** v26.10.14
- **Lane:** store-lifecycle
- **Base:** uncommitted working tree on db2fe05 (lens7/8/9 hardening +356 lines, uncommitted)
- **Coordinates with:** lane 01 (owns `SmaltTest.Lifecycle.ensure_store_up/0` — not yet in the tree; consume it once landed)

## Problem statement

`test/pplan_test.exs` lens7 (`describe "lens7 half-degraded window"`, ~:2705-2777) is the suite's only **manual** Store kill: `Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` (:2732), which removes the child from supervision entirely (not counted by restart intensity, by design). The restore path is:

- **async, in `on_exit` only** (:2721-2727): `if Process.whereis(Smalt.Store) == nil do Supervisor.restart_child(...)`. This runs in a separate ExUnit process *after* the test reports. If the test process dies mid-window (a `flunk` inside the `noproc/1` assertions, or a `wait_until/2` timeout), the synchronous restart never runs and **`Smalt.Store` stays down process-wide** for every subsequent test. `Smalt.Store` owns all 27 named ETS tables (`lib/smalt/store.ex:11-39`, `init/1` :46-57); named tables die with their owner — every later Store-touching module fails with a different first victim depending on shuffle order.
- **unchecked**: the restart's return value is discarded — `{:error, {:already_started, _}}` / `{:error, :not_found}` pass silently.
- **no table verification**: no `:ets.info/1` sweep after the restart.

Contrast: lens6 (:2544, `Process.exit(pid, :kill)`) is safe — the `:permanent` child restarts via the supervisor. Only the manual `terminate_child` window leaks.

Out of scope (parked per `lib/smalt/pplan/task.ex:33-37`): the DETS durability twin.

## Tasks

### Task 1 — wrap the lens7 kill window in `try/after`

Wrap everything from the `:ok = Supervisor.terminate_child(...)` at :2732 through the post-restart assertions:

```elixir
:ok = Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)
try do
  # existing half-degraded window assertions — unchanged
after
  restore_store!()   # new helper, see below
end
```

`restore_store!/0` (a `def` on the test module — `on_exit` runs in its own process):

1. If `Process.whereis(Smalt.Store) != nil`, return `:ok` (idempotent; the happy path's in-`try` restart at :2767 still asserts `{:ok, _}`).
2. Otherwise restart (or delegate to `SmaltTest.Lifecycle.ensure_store_up/0` once lane 01 lands — preferred):
   - `{:ok, _}` / `{:error, {:already_started, _}}` / `{:error, :already_present}` → proceed;
   - any other error → `flunk("lens7 restore_store!: failed to restart Smalt.Store: #{inspect(result)}")` — never silent.
3. `wait_until(fn -> Process.whereis(Smalt.Store) != nil end)` (reuse the file's `wait_until/2` at :1031).
4. Run the Task-2 table sweep.

Keep the existing `on_exit` (:2721-2727) as belt-and-braces — do not delete it; after Task 1 it is a no-op in practice.

### Task 2 — verify the 27 tables exist post-restart

After the restart + `whereis` wait, sweep:

```elixir
missing =
  Smalt.Store.tables()
  |> Enum.reject(fn t -> :ets.info(t) != :undefined end)
```

(Add `def tables, do: @tables` to `lib/smalt/store.ex` if no accessor exists.) Any `:undefined` → `flunk` with the missing list. Derive the count (`length(Smalt.Store.tables())`), do not hardcode 27.

### Task 3 — handle `{:error, {:already_started, _}}` from `restart_child`

Folded into `restore_store!/0` step 2. Rationale: the `after` clause and the `on_exit` net can race; treating already-running as success keeps the restore idempotent.

### Task 4 — TEST_ISOLATION.md §4 audit gap: kill-restart contract

`docs/TEST_ISOLATION.md` §4 currently audits only `async: true` direct-Store refs and the `Store.clear()` inventory. Add:

- **Kill-restart contract**: any test that takes a supervised child down MUST restore it synchronously in the test process (`try/after` + checked `restart_child` + liveness + state verification) before reporting; `on_exit` restore alone is a defect. Reference this work order / lens7 as canonical.
- **Audit method**: `grep -rn "terminate_child|restart_child|Process.exit(.*:kill)" test/` (current verified hits: only `test/pplan_test.exs` — lens7 :2732/:2767/:2725 and lens6 :2544); record the inventory + re-audit date.

**Dependency / coordination:** lane 01 owns `ensure_store_up/0` (`test/support/` currently contains only `tp_oracle`). `restore_store!/0` should call it for the "make sure it is up" step rather than hand-rolling. If lane 01 has not landed when this lane starts, implement self-contained behind a single seam and switch the call site in a follow-up commit in the same release; do not duplicate the helper permanently. Sequence: land lane 01 first if possible.

## Acceptance criteria

1. `mix test test/pplan_test.exs` green, 3 consecutive runs.
2. **Scratch-run leak proof (not a committed test)**: temporarily inject `flunk("scratch")` immediately after the `terminate_child` at :2732, run the file, confirm (a) the flunk is reported AND (b) `Smalt.Store` is up afterward (`mix run -e 'IO.inspect(Process.whereis(Smalt.Store))'`); revert.
3. Post-restart table sweep passes on the happy path (all tables `:ets.info != :undefined`).
4. `restart_child` returning `{:error, {:already_started, _}}` / `:already_present` does not fail the test.
5. `docs/TEST_ISOLATION.md` §4 carries the kill-restart contract bullet + the grep-verifiable killer inventory with a re-audit date.
6. No committed regression test asserts the scratch-flunk behavior (run receipt only).

## Risks / notes

- Do NOT convert the manual `terminate_child` to a lens6-style supervisor kill — that changes the pinned `{:noproc, _}` contract timing.
- `on_exit` runs in a different process; keep its copy minimal ("is it up? if not, restart") — after Task 1 it should never fire.

## Critical files

- /Users/sac/smalt/test/pplan_test.exs
- /Users/sac/smalt/lib/smalt/store.ex
- /Users/sac/smalt/docs/TEST_ISOLATION.md
