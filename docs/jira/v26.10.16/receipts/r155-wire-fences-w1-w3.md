# Receipt — R155 (wire/dispatch-tier fences W1-W3)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `test/egress_dispatch_test.exs:2684-2820` (R155 DoD D87 markers): W1 container
  comp fences, W2 Cosmos PATCH gates, W3 change feed (describe blocks).
- `test/wire/egress_wire_test.exs:195` (R155/W1): container lease/ACL comps
  UNIMPLEMENTED through the real socket.
- `test/wire/egress_wire_test.exs:238` (R155/W2): Cosmos PATCH through the real
  socket.

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/egress_dispatch_test.exs
105 tests, 0 failures
$ MIX_BUILD_ROOT=_build-w7docs mix test test/wire/egress_wire_test.exs
10 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

The session-cited 115/0 is the dispatch+wire combined count, reproduced exactly:

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/egress_dispatch_test.exs test/wire/egress_wire_test.exs
115 tests, 0 failures
```

Standing: PASS.
