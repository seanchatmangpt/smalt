# Receipt — R125 (error-codes doc drift fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** FAIL WITNESS (fence works; a new drift is live on the tree)
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `test/error_codes_doc_test.exs` + `scripts/gen_error_codes.py` (R125
  surface: `docs/ERROR_CODES.md` must be the byte-identical projection of the
  extraction sources, refusing `?`-status rows).

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/error_codes_doc_test.exs
7 tests, 2 failures
```

Failure 1 (byte-identity fence, firing as designed):

```
1) test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)
   docs/ERROR_CODES.md is stale relative to the sources.
   Regenerate: python3 scripts/gen_error_codes.py
   Generator output:
   gen_error_codes: UNRESOLVED_STATUS in egress_router.ex — a "code" literal has no paired send status within the pairing window. Fix the extraction patterns or the source; do NOT ship a ?-status egress row.
     lib/smalt/egress_router.ex:1767: code "InvalidApiVersion" has no paired send status
     lib/smalt/egress_router.ex:1786: code "InvalidApiVersion" has no paired send status
```

Failure 2 (egress literal-coverage assertion, same root cause).

## Handoff

The fence is non-vacuous — it caught a live drift introduced by the R136
header-strictness repair (new `InvalidApiVersion` literals at
`lib/smalt/egress_router.ex:1767`/`:1786` lack a paired send status). Owner:
egress lane — either pair the send status at both sites or register the
divergence; then `python3 scripts/gen_error_codes.py` regenerates the doc and
the court goes green. Docs lane did NOT hand-edit `docs/ERROR_CODES.md`.
