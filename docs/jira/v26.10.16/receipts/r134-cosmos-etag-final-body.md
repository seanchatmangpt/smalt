# Receipt — R134 (cosmos etag = pure function of final stored body)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/data_plane/cosmos.ex:629` (R134 marker): the etag is a pure function
  of the FINAL stored body — built inside the CAS closure against the row that
  actually lands, not the request-time body.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/data_plane/cosmos_test.exs
123 tests, 0 failures
```
