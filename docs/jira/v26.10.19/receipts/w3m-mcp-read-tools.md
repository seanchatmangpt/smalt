# Receipt — wave-3 MCP read-tools lane (ERRC RAISE, mcp-tools)

- **Standing**: PARTIAL_ALIVE (wire-witnessed end to end: tools/list = 26, all 6 new tools answer with seeded data over the real Plug wire path, actuation refused; internal tier has 5 failures, all attributable to other lanes' in-flight files — see Internal tier below)
- **Date**: 2026-10-20
- **Repo**: /Users/sac/smalt (canonical checkout, no worktrees)
- **Lane ownership**: MCP TTL + generated descriptor + MCP router (the established chain) — honored; no other file touched
- **Build isolation**: `MIX_BUILD_ROOT=_build-lane-w3n`
- **No git operations performed** (coordinator owns transitions)
- **Context**: solo

## Diff

- `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` (+55): 6 new `ema:Capability` rows,
  orders 21–26 — `policy.locks.list`, `appconfig.snapshots.kv`,
  `cosmos.changefeed.peek`, `sb.topics.subscriptions`,
  `eh.consumergroups.list`, `certificates.get`. All
  `observationScope read_only / mutationScope none / requiresAuthority false /
  receiptSemantics logged`.
- `lib/smalt/mcp/generated/mcp_descriptor.ex` (+66) — GENERATED, never
  hand-edited, via the TTL-header sync command:
  `MIX_BUILD_ROOT=_build-lane-w3n mix ggen_igniter.sync --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl --query caps=$HOME/ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex --out lib/smalt/mcp/generated/mcp_descriptor.ex`
  → `wrote lib/smalt/mcp/generated/mcp_descriptor.ex (engine: graphlaw, 1 query, 26 total row(s))`
  Replay fence: second sync run is byte-identical (sha256 -c OK):
  ```
  lib/smalt/mcp/generated/mcp_descriptor.ex: OK
  REPLAY BYTE-IDENTICAL
  ```
- `lib/smalt/mcp/router.ex` (+237/-1): `input_schema/1` + `invoke/1` clauses
  for the 6 ids. Notable seams:
  - `cosmos.changefeed.peek` is a READ-ONLY mirror of the change-feed cursor
    semantics (cursor `{2, db, coll}` in `:smalt_cosmos_pk_meta`, ts-boundary +
    seen-etag pins via `cf_cursor_read/1` + `cf_doc_new?/2`, kept AFTER the
    invoke/2 clause group per the file's contiguity convention). The wire
    `change_feed/3` ADVANCES the cursor as a side effect, so the read-only MCP
    surface cannot call it; the witness proves the peek is idempotent and the
    wire feed still delivers both docs afterwards (cursor intact).
  - `certificates.get` projects id/name/attributes only — never `cer`, key
    material, or stored request headers (same projection as the existing list
    tool).
  - All actuation-verb refusal fences unchanged (`certificates.delete`,
    `cosmos.putdoc` → ACTUATION_REFUSED).

## Witness (real output)

Command: `MIX_ENV=test MIX_BUILD_ROOT=_build-lane-w3n mix run /tmp/w3n_mcp_witness.exs`
(ephemeral-port app boot; every seed is a real substrate write —
`Smalt.Policy.put_lock/3`, `AppConfigSnapshots.create/3`,
`Cosmos.create_db/create_collection/create_doc`, `Store.put(:smalt_resources, ...)`,
`EventHubs.create_consumer_group/2`, `Certificates.create/3` — every tool call
rides the real `Smalt.Mcp.Router` Plug dispatch):

```
tools/list count = 26
all 6 wave-3 tool ids registered
seeded: lock, snapshot(2), 2 cosmos docs, sb subscription, eh group, certificate
PASS policy.locks.list count=1 name=w3n-lock
PASS appconfig.snapshots.kv count=2
PASS cosmos.changefeed.peek count=2 cursor_advanced=false
PASS cosmos.changefeed.peek idempotent (cursor not advanced)
PASS wire change_feed delivers 2 docs after 2 peeks (cursor intact)
PASS sb.topics.subscriptions count=1 name=s-w3n
PASS eh.consumergroups.list groups=["$default", "w3n-cg"]
PASS certificates.get attributes-only (no cer/key material)
PASS actuation attempt (cosmos.putdoc) -> ACTUATION_REFUSED
PASS actuation attempt (certificates.delete) -> ACTUATION_REFUSED
PASS unknown tool -> TOOL_NOT_FOUND
PASS missing scope -> INVALID_PARAMS
WITNESS COMPLETE: tools/list=26, 6 tools PASS with seeded data, actuation refused
```

Witness exit code 0.

Witness script: /tmp/w3n_mcp_witness.exs (scratch; harness shape: JSON-RPC
tools/call over `Plug.Test.conn` against `Smalt.Mcp.Router`, real stores, no
mocks — Chicago).

## Compile gate

`MIX_BUILD_ROOT=_build-lane-w3n mix compile --warnings-as-errors` → exit 0
(`Compiling 11 files (.ex)`, no warnings) after concurrent lanes settled
(four polls during which foreign in-flight files
`cosmos_sql.ex`/`blob_storage.ex`/`queue_store.ex` were mid-edit — none of the
poll failures named an mcp file).

## Internal tier

`MIX_ENV=test MIX_BUILD_ROOT=_build-lane-w3n mix test test/internal --include internal` →
**43 tests, 5 failures — all 5 are census-fence trips by OTHER lanes'
in-flight files** (`deletedkeys_purge_route_test.exs`,
`eh_geo_dr_test.exs`, `eh_arm_test.exs`: population fence, status-literal
fence, module allowlist, client-token fence, ARM-literal fence). **Zero
violations name an mcp file.** Same class as the W3A sibling receipt
("internal tier has 7 failures, all attributable to other lanes'
in-flight files").

## Falsifier status

- tools/list count, per-tool seeded reads, cursor non-advance, and actuation
  refusal: all asserted in the witness above — none refuted.
- Descriptor regen from TTL is byte-identical on replay — the generated file
  is a faithful projection.
