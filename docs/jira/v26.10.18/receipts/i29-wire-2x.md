# i29 — wire tier 2x clean run

Standing: PASS
Context: slice(test/wire --include amqp_wire, run 2x back-to-back, _build-ft-w2x)

Lane: bench-runner (W2x). No edits, no git. Build root `_build-ft-w2x` (removed after runs).

Command (run twice, back to back):

```
MIX_BUILD_ROOT=_build-ft-w2x mix test test/wire --include amqp_wire 2>&1 | tail -2
```

## Pass 1 output

```
Finished in 4.0 seconds (0.00s async, 4.0s sync)
29 tests, 0 failures
```

## Pass 2 output

```
Finished in 3.5 seconds (0.00s async, 3.5s sync)
29 tests, 0 failures
```

Acceptance 2/2 clean: both runs green, 29 tests each, zero failures, zero errors.

Machine: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
