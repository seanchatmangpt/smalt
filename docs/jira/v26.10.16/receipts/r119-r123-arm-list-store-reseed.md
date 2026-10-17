# Receipt — R119 + R123 (ARM subscription-wide list; store reseed + TLS call-site reduction)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files (r64-r66-r70-r91 bundling pattern: shared suite, one receipt)

- `lib/smalt/arm_gateway/router.ex` — R119: subscription-wide resource LIST
  across resource groups (KD-54 marker at
  `test/smalt_arm_gateway_test.exs:699`)
- `lib/smalt/store.ex:187` + `lib/smalt/application.ex:162` — R123:
  `Store.clear/0` reseeds the default subscription (boot-state invariant,
  internal consistency, no KD row); `arm_tls_opts/0` collapses cert resolution
  to the single call site `Smalt.TLS.bandit_opts/2` (R90/D52 reconciliation)

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/smalt_arm_gateway_test.exs test/w5r15_repro_test.exs test/tls_test.exs
46 tests, 0 failures
```

Run note: the first attempt aborted with `== Compilation error in file
lib/smalt/data_plane/cosmos.ex ==` (a concurrent lane's in-flight edit,
compile-freeze SLA); the re-run ~90s later compiled clean and passed.
