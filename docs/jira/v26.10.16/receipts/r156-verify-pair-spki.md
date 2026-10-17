# Receipt — R156 (verify_pair = SPKI match, not self-signature)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/tls.ex:227` (TLS-261014-02 / R156 repair marker): pair validation is
  an SPKI match between cert and key, not a self-signature check — a
  whole-but-mismatched pair must be rejected.
- Test: `test/tls_test.exs:691`
  ("CA-chained explicit pair validates (R156: pairing is SPKI match, not
  self-signature)"), minting a real CA:TRUE root + CA-signed leaf at `:658`.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/tls_test.exs
20 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/tls_test.exs
20 tests, 0 failures
```

Standing: PASS.
