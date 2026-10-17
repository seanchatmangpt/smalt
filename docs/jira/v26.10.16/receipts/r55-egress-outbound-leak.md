# R55: egress outbound leak

Standing: PARTIAL_ALIVE
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/egress_router.ex` (+747 diff)

## Claim

Outbound-leak repairs in the egress router (air-gap enforcement) landed.

## Re-run evidence

```
$ mix test test/smalt_egress_router_test.exs test/egress_dispatch_test.exs test/egress_wiring_test.exs
Finished in 2.1 seconds (0.0s async, 2.1s sync)
115 tests, 2 failures
```

Both failures are in egress_dispatch_test.exs, not the router's air-gap legs:

1. `KV create: allowed_operations list admits; nested claim admits` (:415) —
   `conn.resp_body` carries `"release_policy": nil` where the test expects
   `%{"allowed_operations" => ["release", "export"]}`.
2. `raw_blob_put? whitelist redesign ... non-listed service namespace stores verbatim`
   (:2188) — test expects 201 (store verbatim) for `PUT /keys/vltkey/create`; lib answers
   typed 404 "reserved namespace 'keys'".

## Verdict

PARTIAL_ALIVE. Air-gap/outbound-leak legs of the router are green (113/115); the two
residual failures are a release_policy response-shape mismatch and a lib-vs-test conflict
on reserved-namespace PUT semantics (lib's typed 404 is the behavior the comp-whitelist
court asserts as NON-VACUOUS — see r98). Open defects, not receipted as closed.
