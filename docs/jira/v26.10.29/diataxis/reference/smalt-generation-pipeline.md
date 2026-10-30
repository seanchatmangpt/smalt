# smalt-generation-pipeline

The real code-generation chains in smalt, with file:line citations read
this session. Three chains exist; only one of them is the "generation
pipeline" people usually mean.

## Chain 0 — the red herring: root ggen.toml

The root `ggen.toml` in smalt renders k8s YAML from `priv/smalt-k8s.ttl`
only (r11 §"Pipeline shape found"). It is NOT what generates `lib/`
artifacts. Treating it as the generation pipeline is a recon error this
wave corrected on day one.

## Chain 1 — the substrate pipeline (the real one)

`mix smalt.gen` = `lib/mix/tasks/smalt.gen.ex`. Six `Mix.Task.rerun
"ggen_igniter.sync"` stanzas over
`../ggen-marketplace/packs/smalt-substrate-pack` (ontology.ttl + queries +
templates), each render followed by `mix format` (smalt.gen.ex:58-62).
Citations from the file read this session:

| Stanza | Outputs | Lines |
|---|---|---|
| control_plane.rq + payload_rules.rq | lib/smalt/registry.ex | :28-31 |
| event_types.rq + ocel_object_types.rq | lib/smalt/ocel/event_registry.ex | :32-35 |
| store_tables.rq | lib/smalt/store_tables.ex | :36-38 |
| cascade_edges.rq | lib/smalt/cascade_edges.ex | :39-41 |
| config_keys.rq | lib/smalt/config.ex | :42-44 |
| smalt-semconv-pack (own pack) | lib/smalt/telemetry/semconv/registry.ex | :47-55 |

(Templates: registry.ex.eex, event_registry.ex.eex, store_tables.ex.eex,
cascade_edges.ex.eex, config.ex.eex, semconv registry.ex.eex — all under
the pack; line cites are `lib/mix/tasks/smalt.gen.ex` offsets.)

Why a task and not an alias chain: `Mix.Task.run/2` skips a task already
executed in the current VM, so a multi-stanza alias silently executed only
the FIRST stanza (witnessed 2026-10-17, W2a; documented in the task's own
@moduledoc, smalt.gen.ex:7-13). `Mix.Task.rerun/2` forces each stanza.

Downstream:

```text
Smalt.Registry (compile-time data)
  -> Smalt.Projection.Canonical.capability_document/0
       (lib/smalt/projection/canonical.ex — NOT ggen-projected; reads
        Registry accessors only; capability_document/0 at :58,
        write/0 at :180)
  -> mix run -e 'Smalt.Projection.Canonical.write()'
       -> docs/capabilities.json + docs/THIRD_PARTY.md
```

(citation: r12 §1 chain diagram + the canonical.ex read this session:
`def capability_document` at line 58, `def write` at line 180.)

Fences (r11 §"Pipeline shape found"): the ash_gen replay-identity test
`test/smalt_gen_ash_replay_identity_test.exs` covers the ash_gen pipeline
only — NOT the substrate pack; the pack fence is designed to be re-pinned
by landing regenerated outputs. There is no byte-frozen substrate replay
test in the tree.

## Chain 2 — the MCP descriptor (independent, deliberately separate)

`lib/smalt/mcp/gen/smalt_mcp_surface.ttl` → elixir-mcp-a2a-pack
`mcp_capabilities.rq` → `lib/smalt/mcp/generated/mcp_descriptor.ex`
(rendered from the sibling `mcp_descriptor.ex.eex`). The ema: vocabulary
has no standing field and the surface is read-only MCP tools, so identity
faces are NOT modeled there (r12 §1, named decision). The surface file
itself declares the `ema:` prefix pointing at the elixir-mcp-a2a pack
(smalt_mcp_surface.ttl:11, read this session).

## Chain 3 — the ggen CLI (ggen.toml + Tera), used for scaffolds

The `ggen sync run` CLI chain is what the tutorials/how-tos in this guide
cover (see [the sync-run contract](ggen-sync-run-contract.md)). It renders
Tera templates from SPARQL over a Turtle ontology. smalt's in-repo
generation (Chain 1) is ggen_igniter + EEx templates — a different
actuator with the same law: ontology in, projection out, no second source
of truth.

## Which chain do I touch?

- any of the six Chain-1 artifacts (registry, config, store_tables,
  cascade_edges, event_registry, semconv) → Chain 1: pack ontology +
  templates, `mix smalt.gen`
- docs/capabilities.json → Chain 1 downstream (canonical.ex, never
  hand-edit)
- MCP tool surface descriptor → Chain 2
- new scaffold set / decomposition plan → Chain 3 (this guide's how-tos)

## Related

- [extend-the-capability-graph](../how-to/extend-the-capability-graph.md)
- [generated-files-are-projections](../explanation/generated-files-are-projections.md)
- [version-drift](version-drift.md)
