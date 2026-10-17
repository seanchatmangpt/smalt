# Receipt — R5 (blob create-under-hold + atom-conversion safety)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/data_plane/blob_storage.ex:157` — R5/A1: create-under-hold
  (Azure parity: a legal hold set at create time is honored)
- `lib/smalt/data_plane/blob_storage.ex:523` — SHIM-COURT R5:
  `String.to_existing_atom/1` conversion is fence-guarded (ArgumentError on
  unknown atoms instead of an untyped crash)

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/data_plane/blob_hardening_test.exs
112 tests, 0 failures
```
