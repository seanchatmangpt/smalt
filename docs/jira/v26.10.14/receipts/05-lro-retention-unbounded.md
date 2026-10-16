# Flip-gate receipt — GAP(lro-retention-unbounded) CLOSED

Lane: 05-arm-lro · Checkout: /Users/sac/smalt (canonical, main) · Date: 2026-10-15 · Consumer: lane 13 (gap-register flip gate)

## Token

`GAP(lro-retention-unbounded)` — C1_ARM_REST register row :85.

## Closure mechanism

Opt-in retention in `Smalt.ArmGateway.LRO.Sweeper.eviction_pass/0` (`lib/smalt/arm_gateway/lro_sweeper.ex`): `Application.get_env(:smalt, :lro_retention_ms, :infinity)` — default `:infinity` preserves the historical accumulate-forever policy (no silent policy change; fence (11) green unchanged) and any non-integer config evicts nothing (fail-closed like `:lro_delay_ms`). When enabled: eviction runs AFTER the flip pass, eligibility = terminal (`status` ≠ `"InProgress"`) AND parsed `endTime` older than the window, oldest-terminal-first (`endTime` ascending, second granularity). **InProgress records are never evicted at any age.** The flip pass never deletes.

## Fences (all green 3x)

- `lro_test (10)` rewritten, eviction face: 500 mints stay queryable under default `:infinity` (count 500); under a 1 s window, a backdated terminal is GONE at raw `Store.get`, an in-window terminal remains, and an InProgress record survives the sweep (flipped, then retained — never evicted).
- `lro_test (11)` same-parent uniqueness pin: green UNCHANGED (default `:infinity`).
- `lro_test (10c)` NEW no-op fence: empty-store and all-terminal sweep = 0 writes.
- `lro_test (10d)` NEW concurrency fence: sweep racing a wire poll → ONE persisted terminal.

## Acceptance output

```
mix test test/lro_test.exs   → 29 tests, 0 failures  × 3 runs (2026-10-15)
mix test test/compliance/c1_arm.exs → 26 tests, 0 failures
```

## Falsifier

Close condition (register row :85): fences asserting eviction (past-window terminal GONE at raw get, in-window remain) plus a fence asserting InProgress is never evicted — all green on the landed code. All landed and green 3x; falsifier did not fire.

## Register standing

C1_ARM_REST register row `GAP(lro-retention-unbounded)`: **CLOSED 2026-10-15 (V261014-05)**. Lane 13 may flip the gap-register accordingly.
