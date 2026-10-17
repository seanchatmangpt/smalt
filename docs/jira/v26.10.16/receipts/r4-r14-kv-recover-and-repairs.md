# Receipt — R4 + R14 (Key Vault recover/versioned rows + name-shape repairs)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/data_plane/key_vault_actions.ex:279` — R4/D1 (SHIM-COURT marker):
  recover re-puts the live version rows instead of skipping them
- `lib/smalt/data_plane/key_vault_actions.ex:633` area (test marker "R14
  repairs, lane A4 defects 1-3"): `test/data_plane/key_vault_actions_test.exs`

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/telemetry_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs
181 tests, 0 failures
```
