# Receipt — V261014-05 (ARM LRO sweeper + :lro_retention)

Lane: 05-arm-lro · Checkout: /Users/sac/smalt (canonical, main) · Date: 2026-10-15 · Decision-gate option (a) — LANDED

## Files touched

- `lib/smalt/arm_gateway/lro.ex` — `evaluate/2` + `fail_closed/2` promoted from `defp` to public `def` with full @doc ("sweeper and lazy path MUST call the same function so they cannot diverge"); moduledoc updated (the "no timer process" sentence now names the sweeper); `get_op/1` clause bodies UNCHANGED.
- `lib/smalt/arm_gateway/lro_sweeper.ex` — NEW: `Smalt.ArmGateway.LRO.Sweeper` (pattern-matched on `Smalt.Amqp.Sweeper`): `start_link/1`, `sweep_now/0`, `flip_pass/0` (Store.keys → InProgress records past `startedAtMs+delayMs` driven through the SHARED public `evaluate/2`; malformed shapes route to its fail-closed clause), `eviction_pass/0` (opt-in `:lro_retention_ms`, default `:infinity`; terminal-only, InProgress NEVER evicted, oldest-terminal-first, second-granularity parsed `endTime`), tick loop `Process.send_after`, interval `:lro_sweep_interval_ms` (default 30_000); fail-closed crash contract like Amqp.Sweeper.
- `lib/smalt/application.ex` — ONE additive child `Smalt.ArmGateway.LRO.Sweeper` under `Smalt.Supervisor`, :one_for_one, with lane disclosure comment (file shared this wave; other lanes' listener wiring untouched).
- `test/lro_test.exs` — (10) rewritten: 500 mints, ZERO polls, one `sweep_now/0` pass, raw `Store.get` all 500 Succeeded at rest, count 500 under default `:infinity`; eviction face in the same fence (backdated terminal GONE at raw get under a 1 s window, in-window terminal remains, InProgress→flipped-then-retained, never evicted); NEW (10b) at-rest zero-poll fence (pre-sweep raw read still InProgress → post-sweep raw read Succeeded, scheduling fields gone); NEW (10c) no-op fence (empty store + all-terminal store: count + `endTime` stability); NEW (10d) sweep-vs-poll concurrency fence (converges to ONE persisted terminal, byte-identical across a second pass); (11)–(22) untouched.
- `docs/compliance/C1_ARM_REST.md` — deleted duplicate `GAP(lro-lazy-terminality)` row (stale pre-lens-9 twin of :84); both GAP rows flipped CLOSED 2026-10-15 (V261014-05); work-order block re-marked **IMPLEMENTED v26.10.14, V261014-05**. Exactly ONE `GAP(lro-lazy-terminality)` row remains (grep = 1).
- `docs/RELEASE_NOTES_v26.10.14.md` + `CHANGELOG.md` — one feature line/bullet each (sweeper + opt-in `:lro_retention_ms`); only my line added.

## Acceptance output

```
mix test test/lro_test.exs   → 29 tests, 0 failures   (run 1)
mix test test/lro_test.exs   → 29 tests, 0 failures   (run 2)
mix test test/lro_test.exs   → 29 tests, 0 failures   (run 3)
mix test test/compliance/c1_arm.exs → 26 tests, 0 failures
```

The 29 = 26 prior + (10) rewritten + (10b)+(10c)+(10d) new. At-rest zero-poll, no-op, and concurrency fences all present and green in every run.

## Disclosures

- `lib/smalt/application.ex` is shared this wave — my change is the single additive child line + disclosure comment. No other lane's lines touched.
- Compile-freeze SLA event: `blob_storage.ex`, `cosmos.ex`, `management_rpc.ex`, `blob_service.ex` were each transiently broken by OTHER lanes mid-wave; I applied NO fixes (each owner landed their own repair within the SLA window; verified by recompile). No edits outside my owned file set.
- `lib/smalt/arm_gateway/router.ex` (lane 20) NOT edited. Note: router.ex currently carries a pre-existing duplicate-clause WARNING (`check_lock_precondition/2` :915/:966) — lane 20's surface, untouched.

## Falsifier status

Register falsifier (C1:119-121): a record past `startedAtMs+delayMs+sweep_interval`, never polled, reading InProgress at raw `Store.get` after a sweep pass → NOT closed. Fenced green by (10b): pre-sweep raw read InProgress, `sweep_now/0`, post-sweep raw read Succeeded with scheduling fields deleted. Falsifier did not fire.

## Standing

C1 rows: both GAP tokens CLOSED; standing remains PARTIAL_ALIVE (1 PARTIAL row 5b). Sweep/retention landed, fenced, 3x green.
