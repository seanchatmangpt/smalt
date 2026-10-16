# Flip-gate receipt — GAP(lro-lazy-terminality) CLOSED

Lane: 05-arm-lro · Checkout: /Users/sac/smalt (canonical, main) · Date: 2026-10-15 · Consumer: lane 13 (gap-register flip gate)

## Token

`GAP(lro-lazy-terminality)` — C1_ARM_REST row 5, register row :84 (exactly ONE row remains; stale pre-lens-9 twin deleted this landing).

## Closure mechanism

`Smalt.ArmGateway.LRO.Sweeper` (NEW `lib/smalt/arm_gateway/lro_sweeper.ex`), child of `Smalt.Supervisor` (one additive line in `lib/smalt/application.ex`, disclosed), tick `:lro_sweep_interval_ms` (default 30_000). Flip pass walks `Store.keys(:smalt_operations)` and drives every InProgress record past `startedAtMs+delayMs` — and every malformed record — through the PUBLIC `Smalt.ArmGateway.LRO.evaluate/2` / `fail_closed/2` (promoted from `defp` in `lib/smalt/arm_gateway/lro.ex`; `get_op/1` clause bodies unchanged). Swept and polled records converge to the identical persisted terminal because both paths call the same function. The sweep never deletes.

## Fences (all green 3x)

- `lro_test (10)` rewritten: 500 mints, ZERO polls, one `sweep_now/0`, raw `Store.get` → all 500 Succeeded at rest.
- `lro_test (10b)` NEW at-rest zero-poll fence: pre-sweep raw read InProgress → post-sweep raw read Succeeded, `startedAtMs`/`delayMs` deleted.
- `lro_test (12)` wire-stickiness and `(13)` incomplete-record Failed flip: UNCHANGED and green.
- `lro_test (10d)`: sweep racing a wire poll converges to ONE persisted terminal, byte-identical body across a second pass.
- `(10c)` no-op fence: empty/all-terminal sweep = 0 writes (count + `endTime` stability).

## Acceptance output

```
mix test test/lro_test.exs   → 29 tests, 0 failures  × 3 runs (2026-10-15)
mix test test/compliance/c1_arm.exs → 26 tests, 0 failures
```

## Falsifier

Register falsifier (C1 work-order block): a record past `startedAtMs+delayMs+sweep_interval`, never polled, still InProgress at raw `Store.get` after a sweep pass → NOT closed. Did NOT fire: fence (10b) pins the exact opposite (InProgress → Succeeded at raw read with zero polls).

## Register standing

C1_ARM_REST register row `GAP(lro-lazy-terminality)`: **CLOSED 2026-10-15 (V261014-05)**. Lane 13 may flip the gap-register accordingly.
