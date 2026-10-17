# Receipt — R143 (egress api-version admission gates: AKV SKR + Azure Monitor)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/egress_router.ex:600` and `:1763` (R143 / GAP S8 markers): real AKV
  Secure Key Release requires `?api-version=7.x` on every request; missing
  api-version is now a typed 400 `InvalidApiVersion`.
- `lib/smalt/egress_router.ex:792` and `:1783` (R143 / GAP D8 markers): an
  explicitly-wrong Azure Monitor api-version is rejected typed.
- Test: `test/egress_dispatch_test.exs:328`
  ("R143 S8: SKR release without api-version -> typed 400 InvalidApiVersion").

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/egress_dispatch_test.exs
105 tests, 0 failures
```
