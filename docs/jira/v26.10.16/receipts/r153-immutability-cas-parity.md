# Receipt — R153 (immutability policy CAS parity)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/data_plane/blob_storage.ex:724` (R153 marker): the immutability
  policy write participates in the same CAS closure as
  set_legal_hold/set_container_metadata.
- `lib/smalt/data_plane/blob_storage.ex:784` (R153 marker): pure policy builder
  for the immutability write, run inside the CAS closure against the
  freshly-read row; pre-R153 semantics preserved otherwise.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/data_plane/blob_hardening_test.exs
112 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/data_plane/blob_hardening_test.exs
112 tests, 0 failures
```

The session-cited 116/0 was on the mid-wave tree; 112 is the current suite
count and it is green. Standing: PASS.
