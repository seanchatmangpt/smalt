# r233 — ggen_igniter manifest + 2026-10-17 receipt ledger sync (W2b)

- Date: 2026-10-17
- Lane: I2 (WO-3)
- Subject: commit d615661 `chore(projection): W2b ggen_igniter manifest + receipt ledger for the 6-artifact sync`; working-tree ledger at `.ggen_igniter/receipts/2026-10-17.jsonl`
- Standing: PARTIAL_ALIVE

## Verification commands (real output, 2026-10-17)

```
$ python3 -c "import json;[json.loads(l) for l in open('.ggen_igniter/receipts/2026-10-17.jsonl')];print('JSONL_OK')"
JSONL_OK

$ python3 -c "import json;json.load(open('.ggen_igniter/manifest.json'));print('MANIFEST_OK')"
MANIFEST_OK

$ git diff --stat .ggen_igniter/
 .ggen_igniter/manifest.json             | 10 ++---
 .ggen_igniter/receipts/2026-10-17.jsonl | 70 +++++++++++++++++++++++++++++++++
 2 files changed, 75 insertions(+), 5 deletions(-)
```

Ledger carries per-artifact reconciliation receipts, e.g.
`rcpt_0707eca251a5a18c` for `lib/smalt/cascade_edges.ex`:

```
"pack_name":"smalt-substrate-pack" … "outcome":"unchanged" …
"pre_run_hash":"sha256:e54378c11a332778d865e6b48fe9999c3e335bca500313e1d41f1bcea75a0d03"
"post_run_hash":"sha256:e54378c11a332778d865e6b48fe9999c3e335bca500313e1d41f1bcea75a0d03"
"standing":"alive"
```

`pre_run_hash == post_run_hash` on every synced artifact — byte-identical
replay evidenced in the ledger itself.

## Typed refusal observed (why PARTIAL_ALIVE, not PASS)

The same ledger's final entry `rcpt_8e8e870c388140de` is a typed refusal
against the `elixir-mcp-a2a-pack` leg:

```
"standing":"refused",
"metadata":{"failed_step":":run_queries",
"raw_error":"%ArgumentError{message: \"each --query must be name=path.rq, got: ../ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq\"}"}
```

The 6 core artifacts sync clean; the MCP pack's query-arg wiring refuses with
`ArgumentError` (query string lacks `name=` prefix). This is an open defect on
the MCP projection leg, not a regression of d615661 — recorded here so the
coordinator can route it; not fixed by this lane (lease: receipts only).

## Standing rationale

- 6/6 core artifacts: `standing: alive`, identical pre/post hashes.
- MCP pack leg: `standing: refused` (typed ArgumentError) — open, unreceipted
  elsewhere in this window.

## DONE (2026-10-17, integration fix): MCP pack leg closed

The typed refusal was a query-arg form defect, not a pack defect: the sync was
invoked with a bare `--query <path>` instead of the required `name=path.rq`
form. Re-run with `--query caps=../ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq`:

```
$ mix ggen_igniter.sync --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
    --query caps=../ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
    --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex \
    --out lib/smalt/mcp/generated/mcp_descriptor.ex
EXIT=0  (ggen_igniter: unchanged, identical content — byte-identical replay)

$ sha256sum lib/smalt/mcp/generated/mcp_descriptor.ex
900c396b7537dfa0bba43c1bdeeb78ed0b315ca0f5f26ef49f9c94512f0fac47  (unchanged; git diff empty)
```

Ledger reconciliation for this run: `RECONCILIATION_ALIVE standing=alive`.
MCP leg now `alive`; r233 standing closes to ALIVE for the sync surface.
