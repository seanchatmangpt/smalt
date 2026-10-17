# Receipt — R135 + R137 + R138 (mgmt entity-name resolution, raw path-segment fence, KV colon-name collision)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/messaging/amqp/management_rpc.ex:762` — R135: management ops
  resolving an entity by name accept bare/unnormalized names; addresses
  already normalize via `Connection.bare_entity/1` (R96/R129). Dedicated
  check file `test/r135_check_test.exs` existed at lane dispatch and was
  removed by its owning lane before this receipt; the durable court is
  `test/amqp/management_rpc_test.exs`.
- `lib/smalt/egress_router.ex:1916` — R137: Plug `path_info` segments are RAW
  (undecoded); the fence now decodes before matching, so `%2F`-style encoded
  separators cannot split a segment. Flip witness:
  `test/w5r15_repro_test.exs` ("R137 fence flip").
- `lib/smalt/data_plane/key_vault_actions.ex` (R138, W5-6): a `:` in a secret
  name cannot collide with the version separator
  (`test/data_plane/key_vault_actions_test.exs:710`).

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/management_rpc_test.exs
30 tests, 0 failures (3 excluded)

$ MIX_BUILD_ROOT=_build-w6docs mix test test/smalt_arm_gateway_test.exs test/w5r15_repro_test.exs test/tls_test.exs
46 tests, 0 failures

$ MIX_BUILD_ROOT=_build-w6docs mix test test/telemetry_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs
181 tests, 0 failures
```
