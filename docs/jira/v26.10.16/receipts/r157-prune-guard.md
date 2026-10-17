# Receipt — R157 (telemetry prune guard)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/telemetry.ex:320` (R157 marker): prune was the last unguarded raise
  path — it held the init-time tid without a read guard; prune is now guarded so
  a deleted table crashes the GenServer cleanly instead of raising mid-dump.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/telemetry_test.exs
14 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/telemetry_test.exs
14 tests, 0 failures
```

Standing: PASS.
