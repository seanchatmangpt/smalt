# Receipt — R171 (typed-unreachable clause removal)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/egress_router.ex:1326` (R171 marker): the historical
  `{:error, term, _conn}` clause was typed-unreachable and is removed (the
  comment records the removal at the exact site).

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/egress_dispatch_test.exs
105 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/egress_dispatch_test.exs test/wire/egress_wire_test.exs
115 tests, 0 failures
```

Standing: PASS.
