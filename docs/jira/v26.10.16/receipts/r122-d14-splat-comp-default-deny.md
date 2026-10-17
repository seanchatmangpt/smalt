# Receipt — R122 (HEAD/DELETE splat-arm comp default-deny, KD-60)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/egress_router.ex:1454` and `:1484` (markers `D14 (R122, KD-60)`:
  HEAD and DELETE splat arms default-deny blob-level `comp=` operations)
- `test/data_plane/blob_hardening_test.exs:2273` ("D14: unimplemented HEAD
  comps -> typed 400, no metadata served"), `:2290` ("D14: unimplemented
  DELETE comps -> typed 400, blob NOT deleted"), `:2310` (A14: duplicate query
  keys decoded into a LIST)

## Repair

HEAD and DELETE splat arms previously had NO comp gate: an unimplemented
`comp=` on those verbs fell through to metadata/list handling instead of a
typed 400.

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/data_plane/blob_hardening_test.exs
112 tests, 0 failures
```
