# i21 — corpus-soak gate (load-condition corpus rounds after i21 fixes)

Standing: PASS
Date: 2026-10-17
Lane: bench-runner verification lane (no edits, no git)
Precondition: waited for `i21-ets-race-fix.md` and `i21-lro-face.md` (poll 90s x20; both landed ~10 min after lane start)

## Command

```
just corpus-soak 3
```

## Gate result: 3/3 rounds, 0 failures

Three round tails (each = `MIX_BUILD_ROOT=_build-soak mix test test/compliance_test.exs`, tail -1):

```
[CORPUS-SOAK] round 1/3
157 tests, 0 failures (16 excluded)
[CORPUS-SOAK] round 2/3
157 tests, 0 failures (16 excluded)
[CORPUS-SOAK] round 3/3
157 tests, 0 failures (16 excluded)
[CORPUS-SOAK] 3 rounds done — any failure line above is a flake witness
```

## Honest witness: two cold-root aborts before the green run

Attempts 1 and 2 aborted in round 1 with `** (Mix) Can't continue due to
errors on dependencies` (exit 1) on a COLD `MIX_BUILD_ROOT=_build-soak`
root. Diagnosis: the fresh root's `mix deps.compile` fails when run while
concurrent lanes hold the shared deps checkout — a single dep (first
witnessed as `sweet_xml` typing-violation output) aborts under contention;
the same root then compiles clean on a solo re-run (`mix deps.compile
sweet_xml` → exit 0, "Generated sweet_xml app"). Round 1 of the gate is a
cold-compile round, which is exactly the contention window. After the root
was warmed solo, all 3 gate rounds passed with identical output.

Classification: contention-class infra face (cold-root dep compile under
concurrent lane load), NOT a corpus/test flake — zero test failures in any
round that reached the test phase. The corpus-soak recipe itself is
sensitive to cold roots under fan-out; consider warming the root or
retrying once on the cold-compile round.

## Falsifier status

The gate's falsifier ("any failure line above is a flake witness") did not
fire for test failures; the two aborts were dependency-compile aborts, not
compliance-test failures (census vs compile-abort distinction per
same-checkout-fanout law 3).
