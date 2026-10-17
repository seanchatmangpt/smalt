# The ggen Projection Law

Understanding-oriented. This doc explains *why* smalt's generated
artifacts are projections of an ontology through ggen packs rather than
hand-maintained files, and what makes a projection admissible. The
roadmap of concrete projections lives in
`docs/explanation/semantic-kernel-roadmap.md`; this doc is the law.

## The law

Anything derivable from the ontology is generated, and the generation
is replayable: two runs of the same generator identity over the same
ontology must produce byte-identical output, and the drift fence is a
gate that can fail (`--check` mode: `just gen-error-codes --check`,
`mix smalt.gen` byte-identical replay test fence on
`lib/smalt/registry.ex`). Hand-editing a generated file is a category
error: the next regen silently discards it, so the edit was never
admitted. The registry regen is test-fenced for exactly this reason
(mix.exs alias `smalt.gen`; drift fails the test, not a code review).

## Why replay identity is the admissibility test

A generator whose output you cannot reproduce cannot be audited: the
artifact on disk has no provenance if a second run could have produced
a different one. Replay identity (byte-identical second run) is what
converts "a tool wrote this" into "this is a projection of named
inputs" — the artifact's authority transfers from the tool to the
graph. That is why the pack surface is a single authoring identity:
the **smalt-substrate-pack** (`~/ggen-marketplace/packs/smalt-substrate-pack/`,
external repo — ontology.ttl, queries/, templates/, gates/, verify/,
rendered/). Every borrowed generator identity would be a parity surface
of its own; the pack is curated to one, with two named exceptions
(vocabulary-only ports), the reasoning recorded in
`docs/explanation/semantic-kernel-roadmap.md`.

## The precedent: the matter projection packs

The legal-matter precedent (`ggen-marketplace/packs/matter-pack/`)
is the proof that the pattern generalizes beyond one repo: an ontology,
queries, templates, verify queries, and generated/ output organized as
a matter pack — the same shape smalt's substrate pack uses. Two
independent packs, same structure, same projection discipline: the law
is in the pack family, not in smalt's local config.

## One engine, no choice (2026-10-17)

The projection pipeline's SPARQL engine is a fixed constant: graphlaw
(`GgenIgniter.Engine.fixed/0`), not a selectable option. ggen_igniter's
`--engine` flag (sparql/qlever/oxigraph/comparison mode) was removed —
standardized on measured evidence: graphlaw matched the oxigraph reference
row-for-row on the entire smalt-substrate-pack SELECT query set (11 queries,
including the OPTIONAL/!BOUND gates and ORDER BY), and the old default
`sparql` hex engine (0.3.12) was bug-ridden (ignored ORDER BY, no
FILTER NOT EXISTS, broken ASK/CONSTRUCT). `mix smalt.gen` passes no engine
flag; the templates defensively re-sort, so the engine's row order is not
load-bearing for byte-identity (the replay fence in
`test/smalt_registry_replay_identity_test.exs` is the proof, not the doc).
smalt consumes its
own capital the same way (self-hosting: ggen.toml pins the ontology and
pack; `ggen sync run` replays deterministically — the composition
recorded as C25 in `~/.claude/dfcm/composition-catalog.md`).

## What the law governs concretely

| Generated artifact | Regen | Fence |
|---|---|---|
| `docs/ERROR_CODES.md` | `just gen-error-codes` | `--check` drift fence |
| `lib/smalt/registry.ex` | `mix smalt.gen` | byte-identical replay test |
| `docs/jira/v*/RECEIPTS.md`, `receipts/INDEX.md` | `just receipt-index` | R8 drift gate (`docs/jira/v26.10.16/receipts/r08-receipt-index-drift-gate.md`) |
| `docs/jira/v*/BENCH_RESULTS.md` | `just bench-report` | fail-closed report (`r36-bench-report-fail-closed.md`) |
| `lib/smalt/mcp/generated/mcp_descriptor.ex` | ggen_igniter.sync | replay from `lib/smalt/mcp/gen/smalt_mcp_surface.ttl` |
| `lib/smalt/config.ex` (W1a rider) | `mix smalt.gen` | `test/config_replay_identity_test.exs` (`config_keys.receipt.md`) |
| `lib/smalt/store_tables.ex` (W1b rider) | `mix smalt.gen` | `test/store_tables_replay_identity_test.exs` (`store.receipt.md`) |
| `lib/smalt/cascade_edges.ex` (W2a rider) | `mix smalt.gen` | `test/cascade_replay_identity_test.exs` (`cascade.receipt.md`) |
| `lib/smalt/telemetry/semconv/registry.ex` (W2b rider) | ggen_igniter.sync (smalt-semconv-pack) | `test/semconv_replay_identity_test.exs` + `test/semconv_test.exs` (`semconv.receipt.md`) |
| `lib/smalt/projection/canonical.ex` (Canonical rider) | `mix smalt.gen` | `test/canonical_projection_test.exs` (`canonical.receipt.md`) |

Each row: the artifact is never hand-edited; disagreement between
artifact and graph is resolved by regen, and the regen itself is
receipted. The KD row is the register of truth for any divergence the
fence finds (KD register: `docs/jira/v26.10.16/KNOWN_DIVERGENCES.md`).

## See Also

- `docs/explanation/semantic-kernel-roadmap.md` — the five projection
  lanes and their staging
- `docs/SEMANTIC_PROJECTION.md` — semantic projection surface
- `docs/PACK_INTEGRATION/canonical-projection.md` — canonical
  projection (idempotent byte-identical `Smalt.Projection.Canonical.write()`)
- `docs/explanation/emulation-stance.md` — the KD register, the honesty
  mechanism the fences feed
