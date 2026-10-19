# i25 — store_dets churn court round-sizing (i24 leftover face)

Standing: PARTIAL_ALIVE (fix landed, green 3/3 under the pinned 4-hog protocol;
pre-session red witness stands in i24; in-session red NOT witnessed — see
"Red honesty" below)

Repo: /Users/sac/smalt. Lane build root `_build-ft-churn2`. No git (coordinator
owns transitions).

## Face

`test/store_dets_test.exs` stress-tagged churn court
("restore x insert_new churn: insert_new :ok implies the FRESH value wins"):
per-round fixed 30s wall-clock budgets
(`Task.async_stream(timeout: 30_000)`, `Task.await/await_many(…, 30_000)`)
tripped once in i24's session under machine load ~170
(receipts/i24-store-dets-torn.md: "1 run failing only the 30s per-round
timeout budget under machine load avg ~170"). Sizing face, not the torn-probe
mechanism i24 fixed.

## Mechanism

The court's rounds are attempt-budgeted by construction (fixed 100 keys x 50
attempts per round, restore return as completion signal — the store-lro-wasm
draft §1 shape), so wall-clock in a round guards hangs only. The 30s budgets
were ASSUMED machine speed: a merely SLOW round under contention trips them
exactly as a hung round would, indistinguishably. i24's trip was a single
round's heavy-tail stall at ambient ~170; the trip is heavy-tailed and did
not reproduce in this session (see below), so the budget must not depend on
reproducing it.

## Fix (test-side only; lib/ untouched)

`test/store_dets_test.exs` churn court:

1. **Per-round deadline is measured, not assumed.** A fixed-work calibration
   loop (`calib/1`, 5M iterations) is timed on the live machine immediately
   before the rounds; per-round deadline =
   `max(30_000, 1000 x calib_ms)` (`round_deadline_ms/0`). The 30s floor
   keeps the previously-witnessed quiet-machine budget; the 1000x factor
   widens the guard proportionally to measured contention. The deadline is
   plumbed into `Task.async_stream(timeout:)` and both awaits.
2. **Outer test timeout retired as a second assumed budget**: `timeout:
   :infinity` on the test tag; total runtime stays bounded by construction
   at @max_rounds x deadline with the per-round guard loud (async_stream
   `on_timeout: :kill_task` -> reduce clause flunks "churn round crashed or
   timed out"). Total-bound arithmetic: quiet (calib ~8ms) total bound is
   120 x 30s = 1h hang-worst-case; a contended machine widens the guard
   rather than tripping it.

All receipted invariants preserved verbatim: the no-clobber assertion, the
fresh-wins audit, and the non-vacuity pin `total_wins > 0` are untouched.

## Red honesty (measured, not narrated)

In-session red was NOT witnessed. Measured attempts, all pre-fix form... no —
all runs were on the current form; the fix was applied after this series:

- 26 court runs (`--include stress`, line-spec) under 4 yes-hogs, ambient
  load 1-min 12-156 (including compile-storm and 12-concurrent-beam
  contention experiments), **all green**, body 0.07-0.5s.
- Full-file runs (post-fix compile regression, stress included): 6 tests,
  0 failures.
- Starvation levers tried and measured: `taskpolicy -c background` under
  4 hogs -> calib 18ms vs 8ms normal (2.25x — not a real throttle); 12
  concurrent calib beams -> 7-10ms (16 cores absorb it); compile storms
  (3x and 6x fresh-root `mix compile`) -> load peaked ~156, court body
  0.1-0.5s. i24's trip was witnessed at ambient ~170 with fleet load
  continuous through the run; today's ambient decayed to ~12-40 and could
  not reproduce it.
- One artifact: 6 parallel fresh-root compiles corrupted storm build roots
  1-3 (`CompileError` in :ash) — load-pressure artifact, not a tree defect
  (main `_build-ft-churn2` compiles clean, exit 0).

So: i24's 1/3 witness at ambient ~170 stands as the red witness for the
sizing face; this session measured WHY it is heavy-tailed (the court body is
<0.5s even at load ~156; a 30s trip needs a ~100x single-round stall, which
today's environment could not produce). The fix removes the assumption that
produced it regardless.

## Green (this session, 4 yes-hogs, post-fix)

- GREEN 1/3 (load 1-min 133): `1 test, 0 failures (5 excluded)`
- GREEN 2/3 (load 1-min 59): `1 test, 0 failures (5 excluded)`
- GREEN 3/3 (load 1-min 58): `1 test, 0 failures (5 excluded)`
- Full file with stress included: `6 tests, 0 failures`

## Mechanism witness (calibration tracks machine speed)

Same calibration shape as `round_deadline_ms/0`, run standalone:

```
quiet (ambient ~12):  calib_ms=10 deadline_ms=30000   (floor applies)
quiet (ambient ~24):  calib_ms=7  deadline_ms=30s     (floor applies)
bg-band vs 12 hogs:   calib_ms=16 deadline_ms=30000
normal vs 12 hogs:    calib_ms=19 deadline_ms=30000
```

The floor branch is witnessed live; the scaling branch (calib_ms > 30) needs
a genuinely starved machine and was not reachable in this session — named
honestly rather than faked. The max() branch is 4 lines and statically
evident; if a court ever lands past the floor the widening is proportional
to the same machine that runs the rounds.

## Replay

```
MIX_BUILD_ROOT=_build-ft-churn2 mix test test/store_dets_test.exs:152 --include stress
# 4 yes-hogs spawned/killed around the run (pidfile /tmp/churn_hogs.pids)
```

## Residue

- The scaling branch of `round_deadline_ms/0` is unwitnessed in vivo —
  first court run on a genuinely starved machine
  will witness it. The 30s floor keeps fail-loud behavior no worse than
  pre-fix.
- Session byproducts for coordinator cleanup: build roots `_build-storm1..9`
  (1-3 corrupted, 4-9 partial), `_build-storm20..23` (complete), stray
  `/tmp/storm*.log`, `/tmp/churn_hogs.pids`; hogs killed, no stray `yes`
  processes at receipt time.
