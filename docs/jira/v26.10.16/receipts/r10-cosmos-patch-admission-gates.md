# Receipt — R10 (cosmos PATCH runs PUT admission gates)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PARTIAL_ALIVE (unit-level PASS; wire-level FAIL WITNESS)
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files

- `lib/smalt/data_plane/cosmos.ex:621` — R10: PATCH now runs the same
  admission gates as PUT (`test/data_plane/cosmos_test.exs:2630`, "R10 repair
  (audit A2 finding 1): PATCH previously ran doc_id_check only")

## Verification (2026-10-16, W6 docs lane, unedited output)

Unit level (cosmos suite, includes the R10 tests):

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/telemetry_test.exs test/data_plane/cosmos_test.exs test/data_plane/key_vault_actions_test.exs
181 tests, 0 failures
```

Wire level (FAIL WITNESS — deterministic, 2/2 runs):

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/wire/egress_wire_test.exs
10 tests, 1 failure

1) test Cosmos: PATCH valid, pk-move 400, unique-key steal 409 over the wire (Smalt.Wire.EgressWireTest)
   test/wire/egress_wire_test.exs:242
   valid patch answered 400: {"code":"BadRequest","message":"The patch document is invalid."}
```

A previously-valid wire PATCH (JSON-Patch array body, `content-type:
application/json`) now answers 400 BadRequest — the R10 gate's document-shape
check is stricter than the wire shape the court sends. Unit-level patch
documents pass; the wire court's shape is refused. Owner: cosmos/egress lane —
either admit the array+application/json wire shape or re-pin the wire court
with an explicit divergence row. Docs lane did not touch lib/.
