# T10 — MCP router, Policy, and the long tail

- window: v26.10.29 · status: QUEUED · class: decomposition

## Why

`mcp/router.ex` (1793 lines, only 2 top-level defs — one giant plug body),
`policy.ex` (1404 lines, 44 defs), plus the 900-1600-line tail (kql.ex
1542, management_rpc.ex 1454, queue_store.ex 1435, iac_export.ex 1218,
event_hubs.ex 1103, frame_codec.ex 1022, event_grid.ex 984,
purview_atlas.ex 981, trust_profile.ex 956, journal_sink.ex 903,
azure_cache.ex 844 ...).

## Split plans

**MCP router**: extract each tool family into
`Smalt.Mcp.Tool.<Family>` modules returning the standard tool envelope;
router shrinks to tool registry + dispatch. The generated
`mcp_descriptor.ex` surface is generator-owned — never edited; tools
reference the TTL surface, they do not redefine it.

**Policy**: split by concern — `Policy.Eval` (engine), `Policy.Store`
(shadow-table law), `Policy.Assignments` / `.Exemptions` / `.Remediations`
(ARM faces). Keep `Smalt.Policy` as the defdelegate facade (external
call sites unchanged).

**Tail rule**: any file >800 lines is a candidate for extraction by its
existing `# ====` section fences into sibling modules under the same
parent namespace, one family per module, facade + defdelegate kept where
external callers exist. Mechanical, court-gated, one file per diff.

## Constraints

- Byte-identical wire behavior; existing courts gate every step; no test
  edits; generated files never hand-edited.
- Fan-out law applies: one file (one lane) per agent, disjoint ownership.
