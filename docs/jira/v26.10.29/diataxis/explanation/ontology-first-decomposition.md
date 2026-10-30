# ontology-first-decomposition

Why the split plan was rendered by ggen instead of hand-created, what that
buys, and where it stops.

## The situation

The wave decomposed oversized router/engine modules (T06-T10) into 25
target modules across five tickets. The plan could have been a spreadsheet
or a pile of hand-typed placeholder files. Instead it is a Turtle graph
(/tmp/ggen-split/ontology/split.ttl): one `spl:Ticket` per ticket, one
`spl:Module` per target file, each row carrying path, namespace, boundary
label, gate string, ticket pointer, and landing receipt.

## What graph-rendered scaffolds buy over hand-created files

1. Compile-validated boundaries. Every scaffold is a real `defmodule` that
   compiles; the session's compile sweep produced 25 beams in
   /tmp/ggen-split/ebin (`ls /tmp/ggen-split/ebin/*.beam | wc -l` → 25).
   A hand-created file can be typoed; a rendered one is either uniformly
   right or loudly broken at render (`[FM-GEN-008]` — the unbound-variable
   defect reproduced this session).
2. Lineage in every moduledoc. Each scaffold names its ticket, gate, and
   landing receipt (the tutorial's rendered excerpt shows T06/Lro with
   `Gate: test/internal + test/integration green, zero test edits` and
   `Receipt on landing: .../r6-armgateway-split.md`). The plan row IS the
   provenance; no file is orphaned from its why.
3. Plan mutations are one edit. Adding a 26th target is one TTL row and a
   re-render, not a copy-paste.
4. Uniformity is mechanical. The `# NEVER hand-expand` header law rides
   the template, so all 25 scaffolds state it identically.

## The limit: it generates boundaries, not behavior

The scaffold renders the module boundary — namespace, moduledoc, gate,
receipt pointer — and `end`. The behavior still lands by verbatim
extraction from the monolithic source (the template's own header law).
ggen cannot extract `handle_event/2` bodies; the owning lane does, and its
court gates the result. Said plainly: the graph renders the plan's shape;
humans-and-courts land the plan's content. The 425-line all-modules.txt is
26 KB of scaffolds, zero bytes of business logic.

## The same shape at wave scale

This is the same law the substrate pack follows for real artifacts
(registry.ex, config.ex — see
[the pipeline reference](../reference/smalt-generation-pipeline.md)):
model the decision space in the graph, render the mechanical parts, gate
the landed result. The split scaffold differs only in output lifetime —
scaffolds are extraction targets, not permanent generated surfaces — which
is why hand-expansion is banned for both but for different reasons
(scaffolds: the extraction is the work; artifacts: the graph is the work).

## Related

- [bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md)
- [generated-files-are-projections](generated-files-are-projections.md)
- [adopt-generated-code-safely](../how-to/adopt-generated-code-safely.md)
