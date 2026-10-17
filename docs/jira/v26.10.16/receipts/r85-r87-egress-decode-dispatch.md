# R85/R87: egress source/target decode + dispatch tests

Standing: PARTIAL_ALIVE
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/egress_router.ex`, `test/egress_dispatch_test.exs`

## Claim

Source/target decode repairs + dispatch test coverage landed.

## Re-run evidence

```
$ mix test test/smalt_egress_router_test.exs test/egress_dispatch_test.exs test/egress_wiring_test.exs
Finished in 2.1 seconds (0.0s async, 2.1s sync)
115 tests, 2 failures
```

Failures (both egress_dispatch_test.exs):
1. `:415` KV create — `release_policy` nil vs expected `%{"allowed_operations" => ["release", "export"]}`
2. `:2188` whitelist-extension law — expects 201 verbatim store for `PUT /keys/vltkey/create`;
   lib answers typed 404 (reserved namespace), which the comp-whitelist court (r98) asserts
   as the NON-VACUOUS behavior.

## Verdict

PARTIAL_ALIVE. 113/115 green; the two open failures are a response-shape mismatch and a
lib-vs-test semantic conflict on reserved-namespace PUT. Not receipted as closed.
