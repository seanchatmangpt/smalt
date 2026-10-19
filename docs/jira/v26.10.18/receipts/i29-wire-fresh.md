# i29 wire fresh-leg receipt

Standing: PASS (2/2 clean runs)

## Subject

Fresh-build wire tier run, private build root `_build-ft-w3` (deleted after receipt).

## Commands

```
MIX_BUILD_ROOT=_build-ft-w3 mix test test/wire --include amqp_wire 2>&1 | tail -2
```

Run 1 output:

```
Finished in 6.7 seconds (0.00s async, 6.7s sync)
29 tests, 0 failures
```

Run 2 output:

```
Finished in 5.0 seconds (0.00s async, 5.0s sync)
29 tests, 0 failures
```

## Machine

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Notes

- 2/2 runs clean, 0 failures, 0 errors. Acceptance met.
- No edits made, no git operations. Build root `_build-ft-w3` removed post-run.
