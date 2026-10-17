# Receipt — R51 + R57 + R58 + R68 + R95 + R96 + R81 (AMQP/DET-S batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files (shared-suite bundle)

- `lib/smalt/messaging/amqp/lock_manager.ex:59`/`:65` — R51 (SHIM-COURT):
  `token_to_raw/1` returns the WIRE layout; stale-lock 410 MESSAGE_LOCK_LOST
  on every live lock fixed
- `test/amqp/pyamqp_parity_test.exs:130`/`:266` — R57/R58: attach top-level
  `<= 14` with per-performative ceilings (source=8, target=7) — the
  `== 14` tightening seam S1
- `test/amqp/lock_manager_test.exs:254` — R68: .NET-GUID byte-reorder
  involution property check
- `test/amqp/fuzz_test.exs:594` — R95 (D63/R95): retry-windowed atom-flood
  measurement fence (corrects the stale W3/W4 "no landed artifact" claim)
- `lib/smalt/messaging/amqp/connection.ex:500`/`:532`/`:1961`/`:2172` — R96:
  full-URI attach queue links normalize; unguarded stderr IO.puts removed
- `test/store_dets_test.exs:103` — R81: shared app-owned DETS table — clear
  pre-seed so prior tests cannot pollute

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/lock_manager_test.exs test/amqp/pyamqp_parity_test.exs test/amqp/connection_test.exs test/store_dets_test.exs test/amqp/fuzz_test.exs test/smalt_egress_router_test.exs test/kv_tls_test.exs
71 tests, 0 failures (16 excluded)
```
