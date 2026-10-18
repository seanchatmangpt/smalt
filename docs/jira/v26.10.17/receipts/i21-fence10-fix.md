# i21 — Fence 10 PERSISTENT-FLAKE fix (r241 repair surface)

Standing: ALIVE (5x solo green + green under artificial load, real output below)
Context: pair (solo x5 + 2-yes-hog load leg)

Subject: `test/affidavit_wasm_failclosed_test.exs:502` fence 10 — the bogus-path
refusal assertion `assert ms < 100` was a PERSISTENT-FLAKE (r241 court attempt 3
failed both legs, 129ms > bound; solo-green 3/3).

## Diagnosis

The 100ms wall-clock bound conflated scheduler jitter with the regression class
the fence targets. The fence's purpose (comment, lines 489-494) is: the bounded
start retry (3 attempts, 250ms apart, `@start_retry_delay_ms 250` in
`lib/smalt/affidavit/wasm_engine.ex:89-90`) must never leak its sleep onto the
artifact-refusal path. `Process.sleep/1` never returns early, so ANY leaked sleep
makes a refusal take >=250ms provably, while a clean refusal path carries no
sleep. Witnessed clean refusals under parallel load: 129ms — pure scheduler
jitter, provably zero leaked sleeps. Solo refusals are single-digit ms.

## Fix (deterministic, not bound-raising-to-hide)

Bound moved from 100ms to 250ms — the engine's own retry delay, not an arbitrary
number. This makes the assertion exactly "zero leaked retry sleeps":
one leaked sleep => >=250ms => RED (the sleep itself guarantees >=250ms, so the
bound cannot be crossed by jitter on the green side); zero sleeps => clean path
is single-digit ms solo, 129ms witnessed worst-case under load, far under 250.
The regression class the fence was written for is still fenced exactly, and the
harness no longer measures scheduler load. Comment in the test cites the measured
distribution (129ms witnessed, court attempt 3) and why 250ms still fences.

## Verification (real output)

MIX_BUILD_ROOT=_build-ft-f10, cwd /Users/sac/smalt.

Solo, 5 consecutive runs:

```
12 tests, 0 failures
12 tests, 0 failures
12 tests, 0 failures
12 tests, 0 failures
12 tests, 0 failures
```

Under artificial load (2x `yes > /dev/null &` CPU hogs):

```
Finished in 4.9 seconds (0.00s async, 4.9s sync)
12 tests, 0 failures
```

Hogs killed after the run (`pgrep -x yes` empty — verified "hogs killed").

## Disclosures

- Test-side only; no lib/ edit. `# KD-COVERS` not applicable.
- Compile-freeze SLA unblock (disclosed per same-checkout-fanout law 6):
  mid-session, another lane's in-flight mix.exs/mix.lock edit (ex4pm hex-pin
  migration, B1 CLOSED 2026-10-17) left `deps/ash_ex4pm` un-fetched and
  `mix test` aborted with "the dependency is not available". I ran
  `mix deps.get` (additive, deps/ only, no mix.exs/lock edit by this lane) to
  unblock; the two hog-leg failures before that were tree interference, not the
  fix under test. The load run after the unblock is the binding receipt leg.
