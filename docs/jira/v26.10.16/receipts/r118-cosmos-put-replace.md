# Receipt — R118 (cosmos doc PUT = replace, not merge)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/data_plane/cosmos.ex:534` (repair marker `R118/D17`: replace, not
  merge — the stored doc IS the request body)
- `test/data_plane/cosmos_test.exs:1147` ("R118: PUT omitting a field removes
  it from the stored doc (was: retained by merge)")

## Repair

Cosmos document PUT previously merged the request body into the stored doc, so
an omitted field was retained. Azure semantics are replace: the stored doc is
exactly the request body.

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/telemetry_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs
181 tests, 0 failures
```

Including `test/data_plane/cosmos_test.exs:1147` ("R118: PUT omitting a field
removes it from the stored doc"). An earlier batch run
(`telemetry + cosmos + r133_policy_cas`, 140 tests / 1 failure) had its single
failure in the r133 concurrency probe, not in any cosmos test.
