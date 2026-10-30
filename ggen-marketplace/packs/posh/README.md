# POSH pack — ggen v2 frontmatter sync notes (lane P3, v26.10.30)

ggen used: `ggen 26.10.11`.

## Schema: frontmatter, not declarative-rules

ggen 26.10.11 refuses ambiguous manifests (FM-CONFIG-101). This pack uses the
**frontmatter schema**: `[project]` (`name` only — `version` is a declarative
marker), `[ontology] source`, `[templates] dir`. Adding `[generation]`,
`[inference]`, `[sync]`, or `[output]` flips the schema and the manifest is
refused. The CONSTRUCT→SELECT wiring is therefore done **in the template
front-matter sparql**, not in ggen.toml inference rules.

## CONSTRUCT→SELECT wiring

`queries/construct_go_adapter.rq` and `queries/construct_beam_pipeline.rq`
are the canonical projection registers. Because the frontmatter schema has no
inference stage, each template's front-matter `sparql:` SELECT carries the
CONSTRUCT's WHERE pattern inline against the A-box (ontology A-box section
`satisfy every triple pattern`). **The .rq files and the front-matter SELECTs
must stay in lockstep** — a topology change edits both. The A-box in
`ontology/posh.ttl` binds every pattern both projections need: route →
`posh:admittedBy`/`posh:membraneOp`/`posh:shape`/`posh:sink`; turnstile →
`posh:emits`; sink → `posh:deliverTo`/`posh:transport`/`posh:receiptRule`;
rule → `posh:onMissing`/`posh:tokenSize`.

## Output landing (measured, ggen 26.10.11)

- `to:` paths resolve from the **cwd where `ggen sync run` executes** (the
  pack dir). There is no output-root key in the frontmatter schema:
  `[project]` allows only `name`; `[templates]` allows only
  `dir`, `aggregate_modules`, `consumer_mode`; `[output]`/`[generation]` are
  declarative-schema markers and make the manifest ambiguous.
- `to:` with `..` traversal is refused fail-closed (FM-WRITE-002, "must stay
  inside the project root"). The pack therefore renders into its own
  `generated/` tree, mirroring repo-root-relative paths:
  - `generated/posh/internal/adapter/generated_adapters.go`
  - `generated/lib/smalt/posh/pipeline/<op>.ex`
  The integration lane (justfile, `just posh-sync`) copies them to repo-root
  `posh/internal/adapter/` and `lib/smalt/posh/pipeline/`.
- Landing target is `posh/internal/adapter` — NOT `posh/internal/api`.
  `internal/egress` imports `internal/api`, so package `api` cannot call
  `egress` (import cycle); `adapter` imports api+egress+config acyclically.

## Template ABI (verified by go build + go vet)

The rendered adapter calls only landed symbols: `api.NewRefusedEgress`,
`api.NewTransport`, `api.NewUpstream`, `api.NewErrorResponse`, `api.DecodeRequest`,
`api.NewOK`, `api.Encode`, `egress.AdmitsHost`, `egress.NewFencedClient`,
`config.Config`. No phantom C ABI. Receipt rule is fail-closed: missing
turnstile token or non-admitted host = REFUSED_EGRESS (POSH-008).
