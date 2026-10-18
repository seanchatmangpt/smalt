# i21 — broker_facade_test: Sweeper-whereis-nil seed fix (i20c face)

Standing: PASS
Context: pair (solo x3 + paired with test/eventgrid_topics_arm_test.exs)

## Lease

`test/amqp/broker_facade_test.exs` (setup/teardown only).

## Defect

Seed replay face (paired with `test/eventgrid_topics_arm_test.exs`):
`GenServer.whereis(Sweeper) == nil` at line 151 — the shared app-level Sweeper
was stopped by another module's private-tree teardown mid-flight, so the
`run_pass/0` test's `:sys.suspend(sweeper_pid)` ran against `nil` and crashed.

## Fix

The test no longer depends on the shared singleton surviving other teardowns.
Before `:sys.suspend`, it boots a fresh ExUnit-managed Sweeper via
`start_supervised!(Sweeper)` when `whereis` returns nil (auto-cleaned by ExUnit);
otherwise it uses the live shared pid.

## Verification (real output, MIX_BUILD_ROOT=_build-ft-bf)

3x solo + 1x paired:

```
$ MIX_BUILD_ROOT=_build-ft-bf mix test test/amqp/broker_facade_test.exs   # run 1
5 tests, 0 failures (1 excluded)

$ MIX_BUILD_ROOT=_build-ft-bf mix test test/amqp/broker_facade_test.exs   # run 2
5 tests, 0 failures (1 excluded)

$ MIX_BUILD_ROOT=_build-ft-bf mix test test/amqp/broker_facade_test.exs   # run 3
5 tests, 0 failures (1 excluded)

$ MIX_BUILD_ROOT=_build-ft-bf mix test test/amqp/broker_facade_test.exs test/eventgrid_topics_arm_test.exs
14 tests, 0 failures (1 excluded)
```

All green: 4/4 runs, the previously-crashing face included.

## Notes

- No git (per lease).
- Lane build root `_build-ft-bf` cleanup was denied by the permission system;
  coordinator should `just lane-clean` or reclaim it at integration.
