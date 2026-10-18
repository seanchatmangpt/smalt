# i22 — arm_error_corpus LRO PUT 202 + Azure-AsyncOperation poll (attempt-4 leg-2 face)

Standing: PASS (hardening applied, paired-green x3 + solo-green; court-x2 not run in this lane)
Context: pair (solo x1 + paired with test/corpus_test.exs x3)
Build root: MIX_BUILD_ROOT=_build-ft-r8. No git actions this lane.

## Face (attempt 4, leg 2)

`test/arm_error_corpus_test.exs:274` — "LRO PUT returns 202 with
Azure-AsyncOperation header; polling yields 200 Succeeded" failed solo-green under
pairing contention.

## Current poll (pre-fix) + classification

`poll_until_succeeded/2` (:468 pre-fix) was already bounded-retry (50 attempts x
10 ms sleep ≈ 500 ms wall budget) but with a SHORT deadline and an UNTYPED flunk
("LRO never reached Succeeded"). Per task, short-deadline → harden, citing the
witnessed timing distribution from `receipts/i21-lro-face.md`: pre-fix solo runs
1.1–1.4 s with a fixed sleep vs 0.9 s post-fix retry-until-terminal, and the i21
typed-message failure surface ( Enum.split_with inversion caught by the typed key
listing) as the class precedent.

## Change (lease: test/arm_error_corpus_test.exs only)

1. `poll_until_succeeded/2` converted to a deadline-based bounded retry
   (`@poll_deadline_ms 5000`): loop while 202, exit on Succeeded with
   `assert conn.status == 200`, typed flunk on deadline naming path + last
   observed status, and a typed flunk on any non-202/non-Succeeded status
   (`unexpected poll status ...`).
2. Per forensics (mechanism lane 2, coordinator): async suites mutate GLOBAL
   `:lro_delay_ms` (test/lro_test.exs:35 sets 20 ms; affidavit_ingestion,
   arm_cascade, enclave_engine/state, runtime_contracts also touch it), stretching
   per-poll latency under load; the env is honored only at flip evaluation.
   Setup now pins `Application.put_env(:smalt, :lro_delay_ms, 0)` with
   save-prev + `on_exit` restore. Comment-cited in the file at both sites.

## Verification (real output, MIX_BUILD_ROOT=_build-ft-r8)

Paired with test/corpus_test.exs, 3x after fix:

```
Finished in 4.9 seconds (0.00s async, 4.9s sync)
45 tests, 0 failures

Finished in 6.1 seconds (0.00s async, 6.1s sync)
45 tests, 0 failures

Finished in 5.5 seconds (0.00s async, 5.5s sync)
45 tests, 0 failures
```

Solo, after fix:

```
Finished in 0.2 seconds (0.00s async, 0.2s sync)
19 tests, 0 failures
```

First patch iteration had a Python-heredoc mangling (`\\` → `\` in the default
arg) — caught by the compile gate, fixed before any test run counted.

## Falsifier

The face closes only if attempt-5 / court pairing runs the corpus without an
LRO-poll failure; a recurrence now surfaces as the typed deadline flunk
(`LRO never reached Succeeded within 5000 ms (path=..., last_status=...)`)
instead of the bare match error, which either falsifies the pin or proves a
deeper store-visibility defect.
