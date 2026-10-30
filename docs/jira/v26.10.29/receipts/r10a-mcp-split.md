# R10A — MCP router split

window: v26.10.29 · lane: L12 · ticket: T10 (mcp leg) · status: ALIVE (28/30 gate,
2 pre-existing failures disclosed)

## Subject and diff

- Repo /Users/sac/smalt, branch main, HEAD at lane start 338caed. Working tree only
  (coordinator owns git transitions; no commits by this lane).
- `lib/smalt/mcp/router.ex`: 1793 -> 488 lines. Keeps plug wiring (RequestId,
  HealthPlug, mcp_cors, Logger, match/dispatch), handle_errors/F-EGS1 fallback,
  JSON-RPC envelope (initialize, tools/list, tools/call, notification 204, batch
  METHOD_NOT_FOUND), tool registry `tools/0` (capability_id-sorted off the
  generated Descriptor), the typed dispatch gate (dispatch_tool/2,
  actuation_attempt?/1, actuation_verb?/2, registered?/1, actuation_fragments/0
  test seam), respond/respond_error/send_json_rpc_error/decode_rpc.
- NEW `lib/smalt/mcp/tool/` — 12 modules, one tool family each, returning the
  standard tool envelope `{:ok, result} | {:refusal, code, message}` and `nil`
  fall-through for ids outside the family:
  - `shared.ex` — default_subscription/0 (was Router default_subscription/0)
  - `core.ex` — substrate.status, substrate.capabilities, doctor.summary
  - `arm.ex` — arm.get
  - `cosmos.ex` — cosmos.query, cosmos.stats, cosmos.uniquekeys.get,
    cosmos.ttl.effective
  - `cosmos_feed.ex` — cosmos.changefeed.peek, cosmos.changefeed.cursor (+ the
    read-only cf_cursor_read/cf_doc_new? cursor mirrors)
  - `storage.ex` — blob.list, eg.dlq.list (+ dlq_blob_row content-free DLQ
    projection)
  - `service_bus.ex` — sb.peek, sb.topics.list, sb.topics.subscriptions,
    sb.rules.list (+ message_count_arg schema-bounded clamp refusal)
  - `key_vault.ex` — kv.get, kv.deletedkeys.list, kv.deletedsecrets.list,
    kv.certificates.list, certificates.get, kv.rotationpolicy.get (+
    public_vault_record key-material drop)
  - `policy.ex` — policy.exemptions.list, policy.remediations.list,
    policy.locks.list, policy.setdefinitions.list
  - `eventing.ex` — eventgrid.topics.list, eventgrid.subscriptions.list,
    eventgrid.events.recent, eh.consumergroups.list, eh.geo-dr.aliases,
    eg.schemaregistry.groups (+ eg_scan/eg_id/eg_id_matches? registry scans)
  - `catalog.ex` — atlas.lineage.get, appconfig.snapshots.list,
    appconfig.snapshots.kv, dns.zones.list
  - `operations.ex` — cluster.status, health.readiness, lro.operations.list,
    monitor.alerts.list
- Router delegates: `input_schema/1` and `invoke/2` resolve across
  `@families` (11 family modules + Shared) via Enum.find_value; a registered id
  with no family schema raises instead of serving an empty schema; an unhandled
  invoke falls back to the original TOOL_NOT_FOUND clause text.
- Generator-owned surfaces untouched, byte-identical to HEAD (sha1):
  - lib/smalt/mcp/gen/smalt_mcp_surface.ttl 7e348538c08ce5221f7a9110daea9542422fc749
  - lib/smalt/mcp/generated/mcp_descriptor.ex 9c8d2cc9d14b3a102f72d33e21a19ffff2f21ed0
  Tools reference the TTL surface; they never redefine it.

## Method

Line-range surgery off a `git show HEAD:lib/smalt/mcp/router.ex` snapshot with
per-cut boundary asserts, so every kept line is byte-preserved; the two
inserted seams (family fence + @families + input_schema/1 delegation; invoke/2
delegation) are the only new text in router.ex. Family bodies were transplanted
verbatim from the original clause groups (same clause order, same comments),
then wire-verified by differential, not by reading.

## Verification ladder (real output embedded)

1. Module syntax/compile: 12/12 family beams produced (elixirc standalone), new
   router passes macro expansion.
2. Gate (ALIVE): `MIX_BUILD_ROOT=_build-l12 mix test test/internal/mcpt1_dispatch_court_test.exs
   test/internal/expl8r_court_test.exs test/internal/bkegs1_fence_court_test.exs`

```
Result: 28/30 passed
Failed: 2 tests
1) test tools/list includes all five wave-6 tools (Internal.MCPT1DispatchCourtTest)
   test/internal/mcpt1_dispatch_court_test.exs:70
   code:  assert length(resp["result"]["tools"]) == 37
   left:  40
   right: 37
2) test descriptor capability count equals TTL capabilityId count (drift fence)
   test/internal/mcpt1_dispatch_court_test.exs:55
   code:  assert ttl_count == 37
   left:  40
   right: 37
```

3. Byte-identity differential (stronger than a schema diff): in one `mix run
   --no-start` process, compile the HEAD router (renamed L12.OrigRouter) and the
   split router (renamed L12.NewRouter) side by side, drive both over
   Plug.Test:

```
BYTE-IDENTICAL: tools/list + 67 wire probes identical
```

   Probes: tools/list full body (names, descriptions, inputSchema, annotations,
   order), plus tools/call for every registered id (64) with invalid/probe args
   and 27 targeted invalid-arg probes — envelopes ({:ok,_}/{:refusal,code,msg}),
   refusal codes and message text all identical. doctor.summary excluded from
   the probe set only because the --no-start process has no supervisor (both
   routers share that environment; the hostile-supervisor fence covers it in
   the court run).
4. Drift fence inputs re-verified at HEAD: TTL capabilityId count = 40, so both
   failing assertions fail identically with the original router — the court's
   hardcoded 37 predates the T-03 (v26.10.28) eventgrid trio; r4 triage says
   exactly this ("tools/list includes all five wave-6 tools" fails among the
   deterministic set). No test edits made.

## Pre-existing vs session-introduced

- Pre-existing (not session-introduced): the two mcpt1 count assertions above
  (court constant 37 vs landed 40-tool surface; failing inputs are generator-
  owned and byte-identical to HEAD).
- Session-introduced: none. Every previously-passing test in the gate passes.
- Compile-freeze events observed and disclosed: shared lib freezes from other
  lanes mid-session (oidc_code_store.ex, iac_export/terraform.ex,
  purview_atlas/glossary.ex, messaging/amqp/frame_codec.ex). Each was another
  lane's in-flight edit; this lane polled exit-status-bounded (no sleeps in
  tests; poll on real observable = mix compile exit code) and gated on green.
- Lane-internal note: two router.ex mid-rewrite states existed on disk for under
  a minute total during the freeze windows; both were repaired to a compiling
  state within the SLA window by restore from the HEAD snapshot, and the final
  state is court-gated. Disclosed for diff-attributability.

## Standing

ALIVE for the split subject: the 30-test MCP court set runs 28/30 with the only
failures being the two disclosed pre-existing count fences; wire byte-identity
proven by differential (tools/list + 67 probes). PARTIAL only in the sense the
two stale court constants (37) need the T-03 count refresh by whoever owns the
mcpt1 court (test edits are out of my lane).
