# i21 — EgressDispatchTest setup ETS race fix (r241 repair surface)

Standing: PASS
Context: pair (solo x3 + paired x3 with test/eventgrid_topics_arm_test.exs)
Date: 2026-10-17
Lease: `test/egress_dispatch_test.exs` (setup block only) + `lib/smalt/store.ex` seed_default_subscription/0 (only with disclosure — NOT touched)

## Defect (from r241)

EgressDispatchTest setup calls `Smalt.Store.clear/0` →
`seed_default_subscription/0` (`lib/smalt/store.ex:194`) doing
`:ets.insert(:smalt_subscriptions, ...)`. An async sibling suite
(`test/eventgrid_topics_arm_test.exs`) tears the shared app tree down
(`SmaltTest.Lifecycle.stop_shared_tree/0`, eventgrid:371) to run private
trees; in the window between the setup's `ensure_store_up()` and
`Store.clear/0`, the named ETS tables die with the Store GenServer and the
insert raises
`ArgumentError "table identifier does not refer to an existing ETS table"`
(victims :1474, :975, 2x in attempt 3 + earlier runs).

## Fix (test-side only, per lease preference)

`test/egress_dispatch_test.exs` setup block only:

- `ensure_store_up()` call de-indented (was mis-indented under the comment).
- Added bounded typed retry `resilient_clear/1` (50 retries, 10 ms backoff):
  re-runs `ensure_store_up()` then `Store.clear/0`; rescues only
  `ArgumentError` with the exact dead-table message, re-raises nothing
  silently — a persistent failure past the bound returns
  `{:error, :store_unavailable}` and setup raises loudly
  ("shared Store unavailable after retry bound").

No `lib/` changes. No new test/support helper needed —
`SmaltTest.Lifecycle.ensure_store_up/0` (test_helper.exs:129) already
provides the canonical store-ready wait; the race window was between it and
`clear/0`, which only the test file can close.

## Verification (MIX_BUILD_ROOT=_build-ft-ets, real output)

Solo, 3 consecutive runs:

```
107 tests, 0 failures
107 tests, 0 failures
107 tests, 0 failures
```

Paired with the private-tree-stopper
(`mix test test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs`), 3 consecutive runs:

```
116 tests, 0 failures
116 tests, 0 failures
116 tests, 0 failures
```

`mix compile` green (exit 0) before the runs. ExUnit seed varies per run
(max_cases 32, async), so the paired runs exercise the r241 race window
repeatedly with zero reproductions.

## Replay

```
cd /Users/sac/smalt
MIX_BUILD_ROOT=_build-ft-ets mix test test/egress_dispatch_test.exs
MIX_BUILD_ROOT=_build-ft-ets mix test test/egress_dispatch_test.exs test/eventgrid_topics_arm_test.exs
```
