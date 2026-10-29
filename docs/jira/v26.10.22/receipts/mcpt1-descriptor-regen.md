# Receipt: MCP-T1 — descriptor regen + dispatchability court (EXPL-8 T1 repair)

- **Date**: 2026-10-22
- **Lane**: MCP-T1
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: regen of `lib/smalt/mcp/generated/mcp_descriptor.ex` from
  `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` + court
  `test/internal/mcpt1_dispatch_court_test.exs`

## What was done

1. **TTL premise check first**: the TTL already carries all 37 capabilityIds
   including the 5 wave-6 tools (`kv.rotationpolicy.get`, `dns.zones.list`,
   `eg.schemaregistry.groups`, `monitor.alerts.list`, `cosmos.ttl.effective`)
   — no TTL edit needed. The gap was purely the stale generated descriptor.
2. **Regen per generated-artifacts law** (TTL header recipe, exact command):
   ```
   $ MIX_BUILD_ROOT=_build-mcpt1 mix ggen_igniter.sync \
       --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
       --query caps=/Users/sac/ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
       --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex \
       --out lib/smalt/mcp/generated/mcp_descriptor.ex
   ```
   (Note: `--query` requires `name=path` form — bare path is a typed refusal:
   `each --query must be name=path.rq`.) Output: `wrote lib/smalt/mcp/generated/mcp_descriptor.ex
   (engine: graphlaw, 1 query, 37 total row(s))`. 55 lines added, 0 removed.
3. **Drift fence (rerun)**: identical command rerun → sha256 unchanged:
   `5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38`
   (byte-identical, pre- and post-regen).
4. **Court**: `test/internal/mcpt1_dispatch_court_test.exs`, 9 tests, all
   through the real wire face (Plug.Test → `Smalt.Mcp.Router.call/2`):
   - drift fence: `map_size(Descriptor.capabilities()) == 37 == TTL capabilityId count`
   - `tools/list` includes all 5 wave-6 tools; total tools listed = 37
   - `cosmos.ttl.effective` dispatches end-to-end (seeded real Cosmos store
     via `create_db`/`create_collection` with `analyticalStorageTtl: 3600`;
     wire answer `effective_ttl: 3600`) — the exact tool that returned
     TOOL_NOT_FOUND in the EXPL-8 probe
   - `kv.rotationpolicy.get` dispatches into its invoke clause (typed
     INVALID_PARAMS substrate refusal for a missing key — dispatch-level
     TOOL_NOT_FOUND fence does NOT fire)
   - `dns.zones.list`, `eg.schemaregistry.groups`, `monitor.alerts.list`
     dispatch over the wire against real (empty) stores, count 0 lists
   - negative control: unknown id → `TOOL_NOT_FOUND`
   - **ACTUATION_REFUSED leg** (T4 read-only gate): `kv.rotationpolicy.put`
     (mutating verb) → typed `ACTUATION_REFUSED`, never dispatched
5. Court output:
   ```
   $ MIX_BUILD_ROOT=_build-mcpt1 mix test test/internal/mcpt1_dispatch_court_test.exs
   Finished in 0.06 seconds (0.00s async, 0.06s sync)
   Result: 9 passed
   ```
   Also rerun after the shared-compile freeze cleared (below): 9 passed.

## Descriptor diff (embedded, abridged — full diff 55 added lines)

```diff
135a136,146
>     "cosmos.ttl.effective" => %{
>       name: "Cosmos effective TTL read",
>       description:
>         "The effective defaultTtl (container override wins over database defaultTimeToLive; :off when neither set) for one Cosmos container — read only, never a sweep or deletion.",
>       observation_scope: :read_only,
>       mutation_scope: :none,
>       requires_authority: false,
>       reversible: true,
>       consequence: :observe,
>       receipt_semantics: :logged
>     },
146a158,168
>     "dns.zones.list" => %{ name: "DNS zones list", ... },
168a191,201
>     "eg.schemaregistry.groups" => %{ name: "Event Hubs schema registry groups list", ... },
245a279,289
>     "kv.rotationpolicy.get" => %{ name: "Key Vault rotation policy get", ... },
256a301,311
>     "monitor.alerts.list" => %{ name: "Metric alert rules list", ... },
```

## Disclosures

- **Compile-freeze SLA**: the shared compile was frozen ~05:05–05:10 by an
  in-flight edit to `lib/smalt/attestation/maa.ex` (with-else scope error).
  No fix applied by this lane — the owning lane (EXPL9-R1) landed its own
  disclosed unblock fix in maa.ex before my court run; I waited and reran.
- `test/internal/mcpt1_dispatch_court_test.exs` is a NEW file; no other
  lane's files touched. Descriptor regen is coordinator-compatible: the only
  generated file is the one this lane owns.

## Falsifier status

- Stale-descriptor dispatch failure is falsified by the wire court: the
  exact EXPL-8 probe shape (`cosmos.ttl.effective` → TOOL_NOT_FOUND) now
  dispatches with a real seeded answer. Register row repair ticket E8-T1
  may be closed against this receipt.
