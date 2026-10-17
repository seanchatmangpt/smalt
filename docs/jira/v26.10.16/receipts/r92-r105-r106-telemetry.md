# R92/R105/R106: telemetry resilience

Standing: PARTIAL_ALIVE
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/telemetry.ex` (+42 diff), `test/telemetry_test.exs`

## Claim

Telemetry resilience repairs landed (bump survives post-boot table loss, dump/per_minute
minute-window summing).

## Re-run evidence

```
$ mix test test/telemetry_test.exs
Finished in 0.6 seconds
14 tests, 1 failure
```

Failure: `dump/0 shape: map of tuple-key => positive integer` (:146) —
`GenServer.call(RollingCounters, :dump)` raises `:ets.match_object(:smalt_rolling_counters, _)`
"table identifier does not refer to an existing ETS table". The preceding test
`bump/1 survives post-boot table loss` (:195) deletes the table to prove bump's
log-and-drop resilience, but nothing recreates the named table afterward, so the next
`dump/0` crashes. 39/40 behaviors green; the resilience repair itself (bump surviving table
loss) is the leg that passes.

## Verdict

PARTIAL_ALIVE. Open residual: the table-loss test does not restore the named table, so any
later dump in the same test node crashes. Order-dependent isolation defect, precisely
characterized, left open.
