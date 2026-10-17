# I15 — MCP descriptor regen (no-op refresh)

Standing: PASS

## Scope
Lane I15 lease only: `lib/smalt/mcp/gen/`, `lib/smalt/mcp/generated/`. No other git operations.

## Command

```
mix ggen_igniter.sync --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
  --query caps=../ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
  --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex --out lib/smalt/mcp/generated/mcp_descriptor.ex
```

Output (real):

```
Igniter:

    No proposed content changes!

Notices:

* ggen_igniter: unchanged (skipped, identical content): lib/smalt/mcp/generated/mcp_descriptor.ex (engine: graphlaw, 1 query, 8 total row(s)) (via reactor)
```

Exit 0. Note: the task's literal `--query <path>` form was refused by ggen_igniter 26.10.7
(`each --query must be name=path.rq`); retried with `caps=` name prefix — that is the
accepted CLI form, not a semantic change.

`mix format` then applied to the generated file; no formatting churn.

## Verification

- `git diff --stat` over the lease: generated file `mcp_descriptor.ex` shows NO diff
  (byte-identical, as expected). Only the template `mcp_descriptor.ex.eex` diff appears
  (+5/-1: `receipt_semantics: :logged` literal → `:<%= row["receipt_semantics"] %>`
  projection, plus an explanatory `<%# %>` comment on capability_order) — that template
  change is the pre-existing lane input, not regen drift.
- All 8 rows carry `receipt_semantics: :logged` in the regenerated output
  (`grep -c 'logged'` → 8). No STOP condition met.

## Result
No drift. Manifest template hash refreshed via no-op regen. Receipt path exists for
`just docs-dod-check`.
