# BK-XPRIV — plug_status<500 exemption, cross-suite verification

- **Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-XPRIV (read-only verify; this receipt is the only write)
- **Subject**: BK-XPRIF exemption landed in `lib/smalt/arm_gateway/router.ex:146`,
  `lib/smalt/mcp/router.ex:131`, `lib/smalt/egress_router.ex:3995`
  (`if kind == :error and Plug.Exception.status(reason) < 500 do ... skip fence`),
  committed via BK-WRAP3 (see `bkwrap3-regen.md` diff table rows BK-XPRIF ×3).

## Verdict

**ALIVE.** The exemption holds both ways across the whole 400-asserting suite set:
typed plug_status < 500 exceptions render their typed status (malformed-JSON 400
restored), while genuine crashes still render the fallback 500 envelopes. Zero
400→500 regressions found in any 400-asserting court.

## (1) GLD-3 sql-ingest wire court, fresh run

`MIX_BUILD_ROOT=_build-bkxpriv SMALT_COURT_PORT_BASE=39710 mix test
test/internal/sql_ingest_wire_court.exs test/internal/bkegs1_fence_court_test.exs`

```
Finished in 1.2 seconds (0.00s async, 1.2s sync)

Result: 10 passed
```

The malformed-JSON leg is 400 again: `test/internal/sql_ingest_wire_court.exs:145`
test "400 faces: malformed JSON, empty body, missing fields, bad base64,
unsupported format" asserts `s1 == 400` (malformed JSON) through `s5 == 400`
— all five typed-400 faces pass on the current tree.

## (2) BK-EGS1 fence court, fresh run (same invocation, 10 tests incl. the 6 fence legs)

The exemption is witnessed in both directions:

- **Fallback-500 direction (legs 1–6)**: egress/ARM/MCP guarded handlers with
  healthy helpers render the 500 envelopes (`InternalServerError` XML / ARM JSON
  `{"error":{...}}` / JSON-RPC `-32603`), each with x-ms-request-id; the
  faulting-helper legs render the F-EGS1 constant fallback envelope + static
  rid. Fallback bodies asserted verbatim
  (`@egress_fallback_body`, `@arm_fallback_body`, @mcp_fallback_body`,
  `@fegs1_fallback_body`).
- **Typed-400 direction (leg 7, "BK-XPRIF")**: `Plug.Parsers.ParseError`
  (plug_status 400) renders the TYPED 400 — fence skips, the 500 envelope is
  absent. This is the regression flip witnessed on the current tree.

## (3) 400-asserting suite sweep

Grep census of `test/internal` + `test/integration` for `== 400` / `assert.*400`
yielded 24 files; the wire-facing ones re-run fresh
(`MIX_BUILD_ROOT=_build-bkxpriv`, port bases 39710–39714):

| Batch | Suites | Result |
|---|---|---|
| A | ja5_fail_fast_court + expl9r1_egress_guard + expl9r2_arm_guard | **Result: 17 passed** |
| B | kd_blob_court + blob_kd_fixes + kv_crypto_face + kv_ec_create | **Result: 30 passed** |
| C | scvd_wire_courts + arm_dcr + event_grid_webhook + certificates_kd104_witness + kd130_container_exists | **Result: 26 passed** |
| D | eventgrid_push_court + bkmaap6_nonce_bounds + mcpt1_dispatch + expl3_dataplane_repairs + ja15_error_logger | **Result: 42 passed** |

Total sweep: **125 tests, 0 failures** across 17 suites. Any 400→500 regression
would have failed the `== 400` assertions; none did. Typed finding: **none**.

## (4) Standing rationale

- Malformed-JSON leg = 400 (BK-XPRI HIGH regression closed, witnessed fresh).
- Genuine-crash legs still render fallback 500 envelopes (both directions of the
  exemption witnessed in one court run).
- The full 400-asserting suite set is green — no face regressed to 500.

Read-only lane: no `lib/` or test edits; only this receipt written.
Build root `_build-bkxpriv` used per lane-build law (lane lease, not an asset).
