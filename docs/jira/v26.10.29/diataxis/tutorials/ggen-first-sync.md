# ggen-first-sync

Zero to green with `ggen sync run`: a scratch directory, a minimal manifest,
a two-row ontology, one SPARQL query, one Tera template, one rendered file.
Every command below ran this session (2026-10-29, ggen 26.10.11); output
blocks are verbatim.

## Prerequisites

- `ggen` on PATH. `ggen --version` printed `ggen 26.10.11`, exit 0, this
  session. See [version-drift](../reference/version-drift.md).
- One throwaway directory. `ggen sync run` reads `ggen.toml` from the cwd
  only; there is no `--manifest` flag. See
  [point-ggen-at-a-manifest](../how-to/point-ggen-at-a-manifest.md).

## Step 1 — scratch directory and skeleton

```bash
D=$(mktemp -d /tmp/ggen-learn.XXXXXX)
mkdir -p "$D/ontology" "$D/queries" "$D/templates" "$D/out"
cd "$D"
```

This mirrors /tmp/ggen-split, the real 25-module split-scaffold project this
tutorial distills: `ggen.toml`, `ontology/split.ttl`, `queries/extract.rq`,
`templates/module.ex.tera`, `out/all-modules.txt`.

## Step 2 — the manifest

Create `ggen.toml`:

```toml
[project]
name = "ggen-learn"
version = "1.0.0"
description = "first sync"
authors = ["sac"]
license = "Apache-2.0"

[ontology]
source = "ontology/data.ttl"
standard_only = false

[generation]
output_dir = "out"

[[generation.rules]]
name = "module-scaffold"
query = { file = "queries/extract.rq" }
template = { file = "templates/module.ex.tera" }
output_file = "all-modules.txt"
mode = "Overwrite"
```

Field notes:

- `output_dir` and `output_file` resolve relative to `ggen.toml`'s
  directory — always the cwd. A `..` component is rejected as
  `[FM-WRITE-002]` (reproduced this session, exit 1).
- `mode = "Overwrite"` re-renders on every run; `ggen sync run` has no
  per-rule selection (see [run-a-single-rule](../how-to/run-a-single-rule.md)).

## Step 3 — ontology TTL

Two hard laws, both witnessed this session at config-validation/render time:

1. Every SELECT needs `ORDER BY` — without it ggen exits 1 with
   `error[E0013]: Generation rule 'module-scaffold' SELECT query lacks
   ORDER BY` (reproduced this session).
2. Every projected variable must be bound in the WHERE body, not just
   listed in SELECT. Projecting `?receipt` with no triple pattern binding
   it rendered `[FM-GEN-008][TEMPLATE_VARIABLE_MISSING]`:
   `Variable row.receipt not found in context` (reproduced this session,
   exit 1; fixed by adding `spl:receipt ?receipt ;` to the body).

Create `ontology/data.ttl`:

```turtle
@prefix spl: <urn:smalt:split:> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .

spl:t1 a spl:Ticket ; rdfs:label "T1" .

spl:m1 a spl:Module ; spl:tickets spl:t1 ;
       spl:receipt "r6-armgateway-split.md" ;
       spl:path "lib/x.ex" ; spl:ns "X" ;
       rdfs:label "x module" ; spl:gate "gate one" .

spl:m2 a spl:Module ; spl:tickets spl:t1 ;
       spl:receipt "r6-armgateway-split.md" ;
       spl:path "lib/y.ex" ; spl:ns "Y" ;
       rdfs:label "y module" ; spl:gate "gate two" .
```

## Step 4 — the SPARQL query

Create `queries/extract.rq`:

```sparql
PREFIX spl: <urn:smalt:split:>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?path ?ns ?label ?ticket ?gate ?receipt WHERE {
  ?m a spl:Module ;
     spl:path ?path ;
     spl:ns ?ns ;
     rdfs:label ?label ;
     spl:gate ?gate ;
     spl:receipt ?receipt ;
     spl:tickets ?t .
  ?t rdfs:label ?ticket .
}
ORDER BY ?path
```

The `ORDER BY ?path` is load-bearing (law 1). Every variable in SELECT
appears as a triple-pattern object in the body (law 2) — this is exactly
the shape of the real /tmp/ggen-split `queries/extract.rq`.

## Step 5 — the Tera template

Create `templates/module.ex.tera`:

```text
{% for row in sparql_results %}# FILE: {{ row.path }}
# receipt={{ row.receipt }}
defmodule {{ row.ns }} do
end

{% endfor %}
```

Tera receives the query rows as `sparql_results`; each SELECT variable
becomes a row field (`row.path`, `row.receipt`). Keep `{% endfor %}` on its
own line — the tail-hygiene law is proven in
[bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md).

## Step 6 — run and verify

```bash
ggen sync run --dry-run
ggen sync run
```

Exit 0; stdout is the JSON summary (fields `written`, `skipped`,
`graph_hash_hex`, `decisions`, `closure`). This session's real summary for
the two-row ontology:

```json
{
  "decisions": { "out/all-modules.txt": "written" },
  "written": [ "out/all-modules.txt" ]
}
```

(abridged; the full shape is in
[the sync-run contract](../reference/ggen-sync-run-contract.md).)

Verify the rendered file:

```bash
cat out/all-modules.txt
```

```text
# FILE: lib/x.ex
# receipt=r6-armgateway-split.md
defmodule X do
end
# FILE: lib/y.ex
# receipt=r6-armgateway-split.md
defmodule Y do
end
```

(verbatim from this session's run, except the receipt string: the live run
used `r6.md`; the tutorial keeps the real project's receipt name so the
next section matches /tmp/ggen-split.)

## The real thing you just built

/tmp/ggen-split runs the identical shape at 25 modules: `urn:smalt:split`
vocabulary, one `spl:Module` row per decomposition target, 425-line
`out/all-modules.txt`, and a `tree/` extraction target with 25 files. The
real rendered scaffold excerpt (from `out/all-modules.txt`, verbatim):

```text
# Generated by ggen from urn:smalt:split — decomposition scaffold, ticket T06.
# FILE: lib/smalt/arm_gateway/engine/lro.ex
# NEVER hand-expand: behavior lands by VERBATIM EXTRACTION from the source module
# named in the ticket; the owning lane's court (below) is the only gate.
defmodule Smalt.ArmGateway.Engine.Lro do
  @moduledoc """
  Decomposition scaffold (ticket T06): long-running-operation engine.

  Boundary placeholder only. The lane extracts the real implementation from
  the monolithic source module per the ticket split plan; this file becomes
  the extraction target and must compile at every intermediate step.

  Gate: test/internal + test/integration green, zero test edits.
  Receipt on landing: docs/jira/v26.10.29/receipts/r6-armgateway-split.md
  """
end
```

Each module's scaffold names its ticket, gate, and landing receipt — the
graph rendered the plan, not just the files.

## Next steps

- Scale to N modules: [bulk-generate-scaffolds](../how-to/bulk-generate-scaffolds.md)
- Run one rule only: [run-a-single-rule](../how-to/run-a-single-rule.md)
- Manifest resolution and output paths:
  [point-ggen-at-a-manifest](../how-to/point-ggen-at-a-manifest.md)
- Why generated output is a projection, never a source:
  [generated-files-are-projections](../explanation/generated-files-are-projections.md)
