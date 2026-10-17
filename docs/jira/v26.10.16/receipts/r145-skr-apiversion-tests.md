# Receipt — R145 (SKR api-version test updates)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

Session-listed as "SKR api-version test updates, 12/0". The SKR api-version test
cases live in the R143 family — `test/egress_dispatch_test.exs:326-360`
("R143 S8: SKR release without api-version -> typed 400 InvalidApiVersion" and
companions). No R145 literal marker exists on disk (grep over `lib test scripts
gates docs`: zero hits outside receipts); receipt written from the
session-verified subject list plus suite-level verification.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/egress_dispatch_test.exs
105 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

The SKR surface now carries 8 literal `test "SKR` cases in
`test/egress_dispatch_test.exs` (incl. the R143 S8 api-version pin), 8 more
api-version-adjacent cases by name grep; the session-cited 12/0 was a suite
count on an older tree. Suite re-run:

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/egress_dispatch_test.exs test/wire/egress_wire_test.exs
115 tests, 0 failures
```

Standing: PASS.
