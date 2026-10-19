# Court-x2 DRY-RUN leg 5 — full `mix test` at HEAD 4ed7ef5

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `4ed7ef5` (HEAD at leg start, meets ≥ 4ed7ef5)
- **Command**: `MIX_BUILD_ROOT=_build-ft-court5 mix test` (cwd /Users/sac/smalt), twice
Context: slice(×2 runs, same build root `_build-ft-court5`)

## Runs

| run | wall (Finished in) | summary |
|---|---|---|
| 1 | 165.6 s (22.4s async, 143.2s sync) | `1 doctest, 7 properties, 2733 tests, 0 failures (99 excluded)` — exit 0 |
| 2 | 171.3 s (21.4s async, 149.8s sync) | `1 doctest, 7 properties, 2733 tests, 0 failures (99 excluded)` — exit 0 |

## Failure classification (strict)

| Class | Observed |
|---|---|
| DetsRecovery rotating (F-class) | 0 |
| EventGrid/egress 503 readiness (F58/F60) | 0 |
| GracefulStop boot (F59) | 0 |
| Topology cross-test (F61) | 0 |
| DrScenarios/AdversarialJoe/CrashIsolation contention | 0 |
| boot-contention (eaddrinuse / invalid / setup_all timeout) | 0 |
| **Non-LOAD** | **0** |

Fully clean leg: both runs exit 0 with zero failures, zero invalids — no
LOAD-roster face reproduced, zero NEW. Compile clean across both runs; the
in-flight working-tree edits (amqp test files, wire tier refusal sweep,
sovereign_midnight, gates) compiled and passed.

## Acceptance

**ACCEPTED — fully green, zero NEW.** Both runs 0 failures of 2733, no
invalid tokens, exit 0 both. No edits, no git ops, no `_build` deletion
(`_build-ft-court5` preserved for replay).

## Standing

PASS (slice ×2; both runs fully green of 2733 with zero failures and zero
invalids — cleanest dry-run leg of the series; court-x2 real gate cleared to
proceed).
