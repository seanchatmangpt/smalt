# Receipt — R50 + R54 + R67 + R99 + R111 (egress fences batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files (shared-suite bundle)

- `lib/smalt/egress_router.ex:404`/`:1745`/`:2361` — R50: blob_error-style
  stamping (request-id + version) on 503/other planes, CaseClauseError
  admitted through the ledger
- `test/smalt_egress_router_test.exs:61` + `test/kv_tls_test.exs:163` +
  `test/wire/egress_wire_test.exs:247` — R54: per-request authorization
  header (SHIM-COURT-compatible presence check)
- `lib/smalt/egress_router.ex:2118`/`:2231`/`:2255` — R67: LF-only line-ending
  normalization for hand-rolled curl batch heads and sub-request heads
- `lib/smalt/egress_router.ex:1793`/`:1956` — R99: reserved other-plane
  namespaces never reach the blob splat (D70 worst class)
- `lib/smalt/egress_router.ex:475`/`:591`/`:667` + `test/egress_dispatch_test.exs:2232`
  — R111: release_policy stays public; /keys left the parse-exempt probe set

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/egress_dispatch_test.exs test/data_plane/kql_test.exs test/smalt_services_test.exs
131 tests, 0 failures

$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/lock_manager_test.exs test/amqp/pyamqp_parity_test.exs test/amqp/connection_test.exs test/store_dets_test.exs test/amqp/fuzz_test.exs test/smalt_egress_router_test.exs test/kv_tls_test.exs
71 tests, 0 failures (16 excluded)
```

Exception: the R54 wire-leg file `test/wire/egress_wire_test.exs` currently
carries one deterministic failure — the R10 PATCH wire regression (see
`r10-cosmos-patch-admission-gates.md`); its other 9 tests pass.
