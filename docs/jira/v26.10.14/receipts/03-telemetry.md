# Receipt — V261014-03 (telemetry)

Lane: 03-telemetry · Checkout: /Users/sac/smalt (canonical, main) · Date: 2026-10-15

## Files touched (owned only)

- `lib/smalt/telemetry.ex` — C1 (dump/0 sums across minute windows via `reduce:` + `Map.update`), C2 (removed dead `handle_call({:bump, _key, _minute})`), C3 (honest `dump/0` @doc listing all three key shapes + failure-law moduledoc section)
- `test/telemetry_test.exs` — C5 (new test "dump/0 sums the same key across minute windows", seeds ETS rows for now-1 and now, asserts delta == 7 over pre-seed baseline)
- `test/admission_projection_test.exs` — C4 (`telemetry_total/2` filter made total: `{{[:smalt, ^event], _meta}, _n} -> true` + catch-all `_ -> false`)

## Acceptance output (tails)

```
mix test test/telemetry_test.exs test/admission_projection_test.exs
............................
Finished in 0.2 seconds (0.00s async, 0.2s sync)
28 tests, 0 failures
```

Shuffles: seeds 1/7/99 and default — all `28 tests, 0 failures`.

```
grep -rn '{:bump,' lib test  →  only lib/smalt/data_plane/sentinel.ex:154
(forensic_log({:bump, dcr, stream, seq}) — local Sentinel log tuple, NOT a
RollingCounters GenServer message; no caller of the dead {:bump, key, minute}
call remains)
```

## Falsifier (WO-mandated)

Temporarily reverted C1 to the overwrite comprehension →
`test "dump/0 sums the same key across minute windows"` FAILED (12 tests, 1 failure),
proving it probes the cross-window sum path. C1 restored; final run green (28/0).

## Deviations

1. **WO C4 snippet was itself defective.** The work order's proposed filter
   `{[:smalt, ^event], _n} -> true` never matches: enumerating the dump map
   yields `{key, count}` = `{{[:smalt, ^event], _meta}, _n}` — one level of
   tuple nesting deeper. The WO snippet returns 0 for every event (silent
   zero-total, verified by direct reproduction: `before=0 after=0 delta=0`).
   Fixed to `{{[:smalt, ^event], _meta}, _n} -> true` with the same catch-all.
   The witnessed FunctionClauseError fix (catch-all) is preserved.
2. First draft of the C5 test had wrong delta math (baseline computed after
   seeding); corrected to baseline-before-seed. Caught and fixed in-session.
3. Two transient shared-compile breaks by other lanes (egress_router.ex,
   amqp/management_rpc.ex) — waited per compile-freeze SLA, no action by this
   lane; both cleared.

## Non-goals honored

Bandit key shapes unchanged; no failure-behavior changes (F4 doc-only).
