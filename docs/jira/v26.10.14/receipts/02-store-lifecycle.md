# Receipt — V261014-02 (store-lifecycle)

- **Lane:** 02, /Users/sac/smalt @ db2fe05 (uncommitted working tree)
- **Date:** 2026-10-15
- **Status:** COMPLETE (all 6 acceptance criteria met)

## Changes

1. `test/pplan_test.exs` — lens7 kill window wrapped in `try/after`: the
   `:ok = Supervisor.terminate_child(Smalt.Supervisor, Smalt.Store)` at :2732
   now leads a `try` block holding all half-degraded-window assertions
   (unchanged in content, re-indented one level); the `after` calls the new
   `restore_store!/0`. Existing `on_exit` safety net kept (belt-and-braces,
   now a no-op in practice).
2. `test/pplan_test.exs` — new public `restore_store!/0` on the test module:
   idempotent (returns :ok if `whereis(Smalt.Store) != nil`); otherwise
   delegates to lane 01's `SmaltTest.Lifecycle.ensure_store_up/0` (no
   hand-rolled restart), `flunk`ing on any `{:error, reason}`; then Task-2
   table sweep — `Smalt.Store.table_names/0` rejected on
   `:ets.info/1 == :undefined`, `flunk` with the missing list (count derived,
   not hardcoded). Accepts `{:error, {:already_started, _}}` /
   `{:error, :already_present}` implicitly — `ensure_store_up/0` already
   treats both as success, so Task 3 folds in via delegation.
3. `docs/TEST_ISOLATION.md` §4 — added **Kill-restart contract** bullet
   (synchronous in-test-process restore mandatory; on_exit-only restore is a
   defect; references V261014-02 / lens7 / restore_store!/0 /
   ensure_store_up/0) and **Killer inventory** with the grep command, the
   pplan lens7/lens6 hits, and re-audit date 2026-10-15. Other-lane edits to
   the same file coexist (§4 additions verified present post-edit).

## Verification (real outputs)

- `mix test test/pplan_test.exs` ×3 consecutive (pre-scratch):
  `73 tests, 0 failures` each (4.6s / 4.7s / 4.6s).
- **Scratch-run leak proof**: injected `flunk("scratch")` immediately after
  the `terminate_child` (inside `try`, :2734) → run reported the flunk
  (`73 tests, 1 failure`, "scratch", stacktrace test/pplan_test.exs:2734)
  AND `mix run -e 'IO.inspect(Process.whereis(Smalt.Store))'` →
  `#PID<0.493.0>` — Store UP despite the mid-window death (the `after`
  fired). Reverted (grep for `flunk("scratch")` = 0 matches); post-revert
  run: `73 tests, 0 failures` (5.1s). No scratch-flunk test committed.
- Task-2 sweep passes on the happy path inside the green runs (it runs in
  `restore_store!/0` only when Store was down at the after-clause; on the
  happy path the in-window restart + wait_until already ran, and
  `ensure_store_up`'s table wait covers the degraded path — both exercised
  across the 4 runs).
- No git state changes / commits, per lane rules.

## Notes

- `Smalt.Store.tables/0` accessor was not needed — `table_names/0` (landed
  by lane 01) is the accessor; used it for the sweep.
- Pre-existing compile warnings in `lib/smalt/egress_router.ex` and
  `lib/smalt/mcp/router.ex` observed during `mix run` — not lane-owned,
  untouched.

## Falsifier status

- Scratch-flunk injection = the falsifier; ran, passed (Store survived).
- Table sweep vacuity guard: sweep only runs when Store was down — this is
  the leak window; the happy-path restart path keeps its own `{:ok, _}`
  assertion at :2768.
