# BK-F6R — EXPL-10 F6 repair: bounded receive in fond runner `run/1`

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-F6R, canonical checkout /Users/sac/smalt, MIX_BUILD_ROOT=_build-bkf6r

## Subject

`lib/smalt/pipeline/smalt_fond_powl_runner.erl` — the repair for EXPL-10
finding F6 (`run/1` receive had no timeout; a contingency fun that never
returns — e.g. `timer:sleep(infinity)` — hung the caller forever, with the
FSM blocked INSIDE the contingency call and unable to reply or stop).

Note: `docs/jira/v26.10.22/receipts/bkfondskep-runner-audit.md` does NOT
exist on disk (checked before the edit); the probe shape used here is the
bounded-Task shape the dispatch named, grounded in EXPL-10's own court
idiom.

## Fix

- `run/1` gains an optional `timeout` opt: `infinity` (default — behavior
  for `start_pipeline/1` owners unchanged) or positive integer ms.
  Anything else refuses typed: `erlang:error({bad_timeout_opt, Val})`.
- On expiry: `demonitor(flush)` then
  `{crash, {fond_receive_timeout, remaining_work/3-tuple}}` where the
  payload is `#{timeout_ms, plan (full spine), note}` — honest that
  per-step completion is unknowable from the caller while the FSM is
  blocked in the contingency fun. Crash-only, no recovery loop.
- Loopback-legality preserved: no change to the FSM itself; reachable
  plans complete as before.

## Court command

```
MIX_BUILD_ROOT=_build-bkf6r mix test test/pipeline/fond_powl_runner_court_test.exs --include fondrunner_skeptic
MIX_BUILD_ROOT=_build-bkf6r mix test test/internal/expl10r_court_test.exs test/internal/expl10r2_court_test.exs
```

### Embedded real court output

```
Including tags: [:fondrunner_skeptic]
Result: 13 passed
```
exit=0 (was 10 tests; +3 new F6 courts).

```
Result: 26 passed
```
exit=0 (expl10r + expl10r2, both untouched, still green).

## Falsifiers — witnessed

1. **Hang-shape probe returns typed within a bounded Task**: new court (e)
   runs `contingency = fn _ -> :timer.sleep(:infinity) end` with
   `timeout: 100`; asserts `{:crash, {fond_receive_timeout, info}}` with
   `info.timeout_ms == 100`, `info.plan == [:prep, :stage, :commit]`,
   elapsed < 5000ms. First run (pre-fix of the probe itself — probe forgot
   to wire the hang fun) produced the honest BEFORE witness: run completed
   `{:ok, merkle b2c63af4...}` — that was the probe's bug, not vacuity.
   With the hang wired, the probe returns typed. The hung FSM is leaked by
   design (blocked in `timer:sleep(infinity)`), bounded by the test node
   lifetime.
2. **Reachable plan still completes**: explicit `timeout: 10_000` run →
   `{:ok, step_count: 3, plan: [:prep,:stage,:commit], merkle 32B}`.
3. **BK-4 fond court 10/10 → 13/13 green** (10 original + 3 new, all pass
   in one run — loopback, seal determinism, fingerprint gate intact).
4. **expl10r court stays green**: 26 passed (expl10r + expl10r2).

## Diff

- `lib/smalt/pipeline/smalt_fond_powl_runner.erl` — bounded receive +
  `timeout/1` + `remaining_work/2` helpers (only behavioral change; FSM
  handlers untouched).
- `test/pipeline/fond_powl_runner_court_test.exs` — new `court (e)`
  describe with 3 tests (hang-shape typed, generous-timeout completion,
  bad-opt fail-closed refusal).
