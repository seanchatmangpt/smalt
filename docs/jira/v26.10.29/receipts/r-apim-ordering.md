# R-APIM-ORDERING — L04 APIM gateway plug ordering (v26.10.29)

Standing: ALIVE — all 6 ApimWireTest courts green on the live router
(`Result: 6 passed`, exit 0, witnessed twice this session at 22:14 and
22:38 on the current tree); full `mix compile --warnings-as-errors`
exit 0; no test files edited.

## Subject

- Repo: /Users/sac/smalt (one canonical checkout, lane L04, build root
  `_build-l04`)
- Files owned + edited (2):
  - `lib/smalt/apim.ex` — gateway wire plane added to `Smalt.Apim` (the
    PRD-APIM policy runner the wire court's moduledoc names as the wired
    module)
  - `lib/smalt/egress_router.ex` — the single wiring seam:
    `plug(:apim_gateway_plane)` at line 473 (before `:w6r_fallthrough` /
    `:match`), plus the private `apim_gateway_plane/2` at line 493
    (runtime atom-plug idiom, same as `:w6r_fallthrough`)
- Receipt: this file
- Test file: `test/integration/apim_wire_test.exs` — read-only (not edited)

## Root cause (the ordering bug)

The blanket 400 did not come from a mis-ordered plug INSIDE the gateway —
the `/apim-gw` family was UNWIRED in `Smalt.EgressRouter` entirely
(EgressRouter contained zero `apim` references; WINDOW_HANDOFF.md item 2
lists "the APIM gateway" among the unwired planes). Chain of causation:

1. `GET /apim-gw/{api}/{rest}` has exactly the 3-segment shape of the blob
   catch-all `/:account/:container/*blob`, so every wire-court request
   fell through all pre-`match` plugs into the blob routes.
2. The blob catch-all's admission guard `run_guarded/4`
   (lib/smalt/egress_router.ex:3767) blanket-400s any request lacking an
   `x-ms-version` header / SAS token / allowlisted host
   (`MissingXMsVersion` envelope). The guard runs before any route handler
   body — no gateway policy ever executed.
3. Every policy face was shadowed: jwt → 401 face, rate-limit → 429 face,
   header-transform → 200 echo face, default-off → typed 404 face — all
   answered `400` (`left: 400` on all 12 rows of the r4 triage; all 6 rows
   of this session's baseline run, exit 1, 21:56).

Repair mandated by the lane ("reorder/repair the plug chain so policy
evaluation precedes the blanket 400"): mount the gateway plane as a
pre-`match` plug that claims `/apim-gw/*` and answers (or passes) BEFORE
the blob catch-all's MissingXMsVersion guard is ever reached.

## Fix shape

- `lib/smalt/apim.ex` — `Smalt.Apim` gains the gateway wire plane:
  - `gateway/2` (apim.ex:133): claims only `["apim-gw", api | rest]` path
    shapes (first segment `apim-gw`), passes everything else through
    un-halted; reads `config :smalt, :apim_gateways` per request (binary
    api keys — no String.to_atom on request-shaped input).
  - `dispatch_gateway/2` (apim.ex:143): configured api → `run/2` policy
    chain (first refusal halts with the typed envelope — jwt 401 /
    rate-limit 429 + Retry-After; chain order is the config list order, so
    a jwt refusal wins over an already-admitted rate slot), then the
    built-in echo face: 200 `{"api","method","path","headers"}` (headers
    are the POST-transform req_headers, so the court pins that the header
    transform actually ran on the wire). Unconfigured api →
    `gateway_not_found/2` (apim.ex:174): typed 404
    `{"error":{"code":"ApiNotFound",...}}`.
  - `conf_policies/1` (apim.ex:167-169): accepts the wire contract's map
    shape `%{policies: [...]}` (the first run raised FunctionClauseError
    from Keyword.get on the map — fixed and witnessed this session) and
    tolerates a keyword list.
- `lib/smalt/egress_router.ex` — one plug line + one 3-line private fn:
  - `plug(:apim_gateway_plane)` (egress_router.ex:473), before
    `:w6r_fallthrough` / `:match`, so it precedes the blob catch-all's
    `run_guarded/4` MissingXMsVersion blanket 400 (egress_router.ex:3767).
  - `defp apim_gateway_plane(conn, _opts), do: Smalt.Apim.gateway(conn, [])`
    (egress_router.ex:493) — runtime atom plug (same idiom as
    `:w6r_fallthrough`), claims only `/apim-gw/*`, passes everything else
    through un-halted. All pre-existing route families byte-identical: the
    plug is a no-op outside the `apim-gw` first segment.
- No test edits. No config default changed: `:apim_gateways` defaults to
  `%{}` — the default-OFF posture is preserved (unconfigured api answers
  the typed 404, it never reaches the blob splat).

## Embedded real output

Baseline (pre-fix, 21:56, `MIX_BUILD_ROOT=_build-l04 mix test
test/integration/apim_wire_test.exs`, exit 1):

```
  4) test policy chain admits: echo backend 200 carries the post-transform
     request header (Smalt.Integration.ApimWireTest)
     Assertion with == failed
     code:  assert conn.status == 200
     left:  400
     right: 200
  6) test default-off: unconfigured api under /apim-gw falls through to
     the typed 404 face (Smalt.Integration.ApimWireTest)
     code:  assert conn.status == 404
     left:  400
     right: 404
Result: 0/6 passed
Failed: 6 tests
```

Gate (post-fix, 22:38, same command, exit 0; run log
/tmp/l04_apimwire_final.log):

```
22:38:19.542 info[] Sent 404 in 13ms
22:38:19.996 info[] Sent 401 in 453ms
22:38:20.023 info[] Sent 200 in 14ms
22:38:20.023 info[] Sent 200 in 70µs
22:38:20.027 info[] Sent 200 in 56µs
22:38:20.027 info[] Sent 200 in 32µs
22:38:20.027 info[] Sent 429 in 81µs
Result: 6 passed
```

Regression neighbours (same build root, real runs this session):

```
test/apim_policy_test.exs + impl6_process_label + internal_tier_census:
  Result: 16 passed
test/integration/apim_test.exs: Result: 11 passed (exit 0)
test/integration/parity_lane_wire_test.exs + blob_kd_fixes_test.exs:
  Result: 11/17 passed — the 6 failures are all BlobKdFixesTest KD-* rows
  and docs/jira/v26.10.29/receipts/r4-baseline-triage.md (~line 191) lists
  "BlobKdFixes 6+6" as a PRE-EXISTING baseline cluster — not
  session-introduced.
```

## Cross-lane disclosures (compile-freeze SLA)

No cross-lane file edits. Five sibling-lane in-flight writes froze the
shared compile during this lane's runs (identity/saml_slo.ex,
data_plane/cosmos/auth.ex, mcp/tool/arm.ex, mcp/tool/service_bus.ex,
mcp/router.ex, key_vault/keys.ex, messaging/amqp/frame_codec.ex — each a
transient unclosed-delimiter TokenMissingError while the owner lane wrote
atomically). Each settled by its owner within the ~10-min SLA. This lane
responded with bounded polls only (poll on `mix compile` cleanliness and
on the :9445 listener occupancy; no Process.sleep outside bounded poll
intervals; no stashes; no git state commands; coordinator owns git
transitions).

## Verification ladder

1. Baseline: 0/6, exit 1 — all six faces answered 400 (witnessed 21:56).
2. Fix compile: full `mix compile --warnings-as-errors` exit 0 after
   touching both owned files (forces smalt recompile; rc=0).
3. Gate: `MIX_BUILD_ROOT=_build-l04 mix test
   test/integration/apim_wire_test.exs` → `Result: 6 passed`, exit 0
   (witnessed twice: 22:14 and 22:38).
4. Neighbours: apim unit+census 16 passed; integration apim_test 11
   passed; parity_lane_wire 11/11 passed; blob_kd_fixes 6 pre-existing
   baseline failures (r4 triage "BlobKdFixes 6+6"), not introduced here.
