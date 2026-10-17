# Receipt — R124 + R126 + R136 (egress comp envelopes, sentinel quote-aware parse, header strictness)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files (shared-suite bundle, r64-r66-r70-r91 pattern)

- `lib/smalt/egress_router.ex:1894`/`:2664`/`:2687` — R124: the blob and
  container `?/2` predicates were byte-identical (deduplicated) and the
  comp-error envelope message convention is uniform across both comp arms
- `lib/smalt/data_plane/sentinel.ex:281`/`:321`/`:350` — R126: pipe/keyword
  scanning runs on the quote-stripped text so pipes/keywords inside string
  literals are invisible to the detector (three quote-style exploits closed)
- `lib/smalt/egress_router.ex:1847` — R136: `x-ms-version` validation was
  presence-only; empty value and duplicates are now refused

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/egress_dispatch_test.exs test/data_plane/kql_test.exs test/smalt_services_test.exs
131 tests, 0 failures
```

Note: egress_dispatch had stood at 113/115 (two open defects, r55/r85/r87 and
r111 reconcile rows, W3/W4 receipts). The W5/W6 repairs cleared them — this
run is 0-failure across the combined 131-test batch.

Drift warning carried by `r125-error-codes-doc.md`: R136's new
`InvalidApiVersion` literals in `lib/smalt/egress_router.ex:1767`/`:1786` have
no paired send status, so `gen_error_codes.py` refuses and
`docs/ERROR_CODES.md` is stale — owned by the egress lane, not the docs lane.
