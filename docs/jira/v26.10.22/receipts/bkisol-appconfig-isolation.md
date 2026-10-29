# Receipt: BK-ISOL — appconfig_events_test isolation fix (F8 class)

- **Date**: 2026-10-22
- **Lane**: BK-ISOL, repo /Users/sac/smalt (canonical checkout, MIX_BUILD_ROOT=_build-bkisol)
- **Standing**: ALIVE
- **Context**: solo
- **Closes**: the "Pre-existing, not session-introduced" item in
  `docs/jira/v26.10.22/receipts/bk7b-warnings-sweep.md` (appconfig_events_test
  5-fail with `{:already_started, _}` ONLY when run combined with the
  integration dir; passes solo).

## Root cause

`Smalt.AppConfigEventsTest` setup did:

```elixir
start_supervised!(AppConfigEvents)
AppConfigEvents.reset()
```

`Smalt.DataPlane.AppConfigEvents` is a globally-named GenServer
(`name: __MODULE__`) with a **lazy-start** client API (`server/0` calls
`start_link` when `whereis` is nil). In a combined
`mix test test/integration test/pipeline` run, a sibling sync test that PUTs a
KV key (`test/integration/kv404_typed_error_test.exs:28` PUTs `/kv/...`) hits
`Smalt.Egress.AppConfigRoutes.emit_kv_event/1` (lib/smalt/egress/AppConfigRoutes.ex:367)
→ `AppConfigEvents.emit/4` → `server/0` → `start_link/1` **linked to the
calling test process**. When that test exits normally, the link's exit signal
is `:normal` and non-fatal, so the registry survives the test, registered
under the global name **outside any supervisor** (a link-survivor leak). The
next `Smalt.AppConfigEventsTest` setup then fails `{:already_started, _}` on
every remaining test.

This is the FLAKE_LEDGER F8 class: a globally-named process started outside
setup ownership, colliding across test modules. Not a sleep/timing issue —
pure ownership, fully deterministic given the file pair.

## Fix (structural, setup-owned name)

`test/integration/appconfig_events_test.exs` setup now re-owns the global
name instead of assuming it is free:

```elixir
case Process.whereis(AppConfigEvents) do
  nil -> :ok
  pid -> GenServer.stop(pid)   # synchronous stop of any link-survivor
end
start_supervised!(AppConfigEvents)
AppConfigEvents.reset()
```

`GenServer.stop/1` is synchronous — the leaked instance is dead before
`start_supervised!` runs; the registry is then supervision-owned and dies
with each test. No sleeps, no test-order dependence.

## Evidence: three-way run (embedded output)

Pre-fix baseline (combined `test/integration test/pipeline`), real output:

```
     Reason: bad child specification, got: {:already_started, #PID<0.3231.0>}
     (5 failures, all Smalt.AppConfigEventsTest, setup at
      test/integration/appconfig_events_test.exs:9)
Failed: 5 tests
```

Full pre-fix log: /tmp/bkisol_run1.log (Result: 234/239, Failed: 5 — all five
Smalt.AppConfigEventsTest already_started).

Post-fix:

**Run 1 — solo** `MIX_BUILD_ROOT=_build-bkisol mix test test/integration/appconfig_events_test.exs`

```
.....
Finished in 0.3 seconds (0.00s async, 0.2s sync)
Result: 5 passed
```

**Run 2 — combined forward** `MIX_BUILD_ROOT=_build-bkisol mix test test/integration test/pipeline`

```
Result: 239 passed
```

**Run 3 — combined reverse order** `MIX_BUILD_ROOT=_build-bkisol mix test test/pipeline test/integration`

```
Result: 239 passed
```

Order-independence falsifier: passes. Note the two-file invocation
(`mix test test/integration/appconfig_events_test.exs test/pipeline`, either
order) was green even pre-fix (15 passed) — the collision needs the full
integration directory (kv404 test in the run) to leak the registry first;
that is the invocation class bk7b actually disclosed.

## Not done (typed)

- lib-side hardening of the lazy `server/0` start (unlink or start under a
  permanent supervisor) is lib authority, not this lane's; the test-side
  re-ownership fully closes the test isolation defect. Logged here as the
  upstream residue.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-bkisol mix test test/integration/appconfig_events_test.exs
MIX_BUILD_ROOT=_build-bkisol mix test test/integration test/pipeline
MIX_BUILD_ROOT=_build-bkisol mix test test/pipeline test/integration
```
