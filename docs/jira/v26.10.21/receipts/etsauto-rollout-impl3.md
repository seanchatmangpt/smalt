# Receipt: ETSAUTO rollout (IMPL-3) — flag extended to :smalt_arm_rate + :smalt_rolling_counters

Context: solo

**Standing:** PARTIAL_ALIVE → court 3/3 PASS, adjacent regression 15/15 PASS; rollout landed default-ON, reversible.

Date: 2026-10-21. Repo: /Users/sac/smalt. Lane: IMPL-3 (OTP-29, MIX_BUILD_ROOT=_build-impl3).

## Diff (writer output)

1. `lib/smalt/arm_gateway/router.ex` — `rate_table/0` now gates
   `{:write_concurrency, :auto}` on `Application.get_env(:smalt, :ets_write_concurrency_auto, true)`
   (same flag/shape as the :smalt_cosmos_ru pilot). Heir + ArgumentError rescue untouched.
   Already landed by coordinator tick checkpoint 63a2192.
2. `lib/smalt/telemetry.ex` — `Smalt.Telemetry.RollingCounters.init/1` gates
   `write_concurrency: :auto` on the same flag (was hardcoded `write_concurrency: true`).
   Working tree (pending coordinator commit).
3. `test/internal/ets_auto_court_test.exs` — extended to one leg per table
   (cosmos_ru via real gate→throttle→ru_table/0 request path; arm_rate via real
   `rate_table_for_test/0`; rolling_counters via the supervised GenServer's real
   init/1 with bounded-poll convergence on the write_concurrency observable,
   poll_helper.exs, no fixed sleep).

Counters/keys only. Store CAS tables untouched.

## Court output (actual)

`MIX_BUILD_ROOT=_build-impl3 mix test test/internal/ets_auto_court_test.exs`
(elixir 1.20.4-otp-29, OTP 29 erts-17.1.1, 16 schedulers):

```
[ETSAUTO court] smalt_cosmos_ru, 128k atomic increments x3 rounds (min-of-3 wall, ms)
  write_concurrency=false: 1417 ms
  write_concurrency=:auto: 141 ms
[ETSAUTO court] smalt_arm_rate, 128k atomic increments x3 rounds (min-of-3 wall, ms)
  write_concurrency=false: 1159 ms
  write_concurrency=:auto: 115 ms
[ETSAUTO court] smalt_rolling_counters, 128k atomic increments x3 rounds (min-of-3 wall, ms)
  write_concurrency=false: 3762 ms
  write_concurrency=:auto: 67 ms
Result: 3 passed
```

Exactness leg: 64 tasks x 2000 atomic increments per table per leg, final total
== 128,000 asserted on real table state (Chicago), both legs — zero lost updates.

Adjacent regression (throttle/telemetry surfaces):
`mix test test/internal/eh_throttle_wiring_test.exs test/data_plane/cosmos_ru_throttle_retry_after_test.exs test/adaptive_health_test.exs` → 15 passed, 0 failures.

## In-flight compile-freeze events (disclosure)

- blob_storage.ex / file_share.ex were mid-migration from raw `is_integer/3`
  guards (Elixir cannot compile the 3-arg BIF in guards; Erlang-only) to
  `defguardp int_in/3` by the owning lane; my builds were blocked ~8 min, then
  the owner converged it — no fix applied by this lane.
- lib/smalt/powl2/graph_compat.ex had an invalid single-line `@doc """..."""`
  heredoc (owned by POWLSK2 lane); it converged on the owner's next write —
  no fix applied by this lane.
- No shared file edits by this lane beyond the two creation sites + court file.

## Notes

- `:auto` wins are large (10x–56x min-of-3 wall on 128k atomic increments,
  16 schedulers); OFF leg kept as the reversible baseline via
  `:smalt, :ets_write_concurrency_auto -> false`.
- `init got unexpected {:ETS-TRANSFER, ...}` log lines are the existing
  heir-to-:init transfer messages reaching the RollingCounters/ARM init —
  pre-existing log noise, not introduced here.
