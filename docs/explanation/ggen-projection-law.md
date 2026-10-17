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
is in the pack family, not in smalt's local config. smalt consumes its
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
