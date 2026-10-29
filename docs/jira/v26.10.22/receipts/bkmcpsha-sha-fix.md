# Receipt: BK-MCPSHA — MCP-T1 receipt sha correction / FD-2 resolution

- **Date**: 2026-10-22
- **Lane**: BK-MCPSHA
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: typed FD-2 from BK-MCPSKEP
  (`docs/jira/v26.10.22/receipts/bkmcpskep-mcp-audit.md`): MCP-T1 receipt
  sha vs on-disk descriptor `35f25577…` mismatch

## Verdict up front: NO defect. FD-2 WITHDRAWN (algorithm confusion).

`35f25577bc4751135793001355d80518b1fe4ee5` is the **SHA-1** of the on-disk
descriptor; its **SHA-256** is exactly what the MCP-T1 receipt recorded.
BK-MCPSKEP's verification block used bare `shasum` (defaults to SHA-1) and
compared it against a SHA-256 claim. The parent dispatch's premise ("the
receipt's own 55-lines-added diff contradicts the recorded sha") is also
unsound: the 55-line diff is regen-vs-**pre-regen**, not regen-vs-regen;
a byte-identical rerun after the regen is fully consistent with it.

## Re-derivation (embedded verification)

```
$ shasum -a 256 lib/smalt/mcp/generated/mcp_descriptor.ex
5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38  lib/smalt/mcp/generated/mcp_descriptor.ex

$ PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-bkmcpsha mix ggen_igniter.sync \
    --ontology lib/smalt/mcp/gen/smalt_mcp_surface.ttl \
    --query caps=/Users/sac/ggen-marketplace/packs/elixir-mcp-a2a-pack/queries/mcp_capabilities.rq \
    --template lib/smalt/mcp/gen/mcp_descriptor.ex.eex \
    --out tmp/bkmcpsha_descriptor_check.ex
* ggen_igniter: wrote tmp/bkmcpsha_descriptor_check.ex (engine: graphlaw, 1 query, 37 total row(s)) (via reactor)

$ shasum -a 256 tmp/bkmcpsha_descriptor_check.ex lib/smalt/mcp/generated/mcp_descriptor.ex
5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38  tmp/bkmcpsha_descriptor_check.ex
5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38  lib/smalt/mcp/generated/mcp_descriptor.ex

$ shasum tmp/bkmcpsha_descriptor_check.ex lib/smalt/mcp/generated/mcp_descriptor.ex
35f25577bc4751135793001355d80518b1fe4ee5  tmp/bkmcpsha_descriptor_check.ex
35f25577bc4751135793001355d80518b1fe4ee5  lib/smalt/mcp/generated/mcp_descriptor.ex
```

- **Byte-identical regen**: fresh generator output == on-disk descriptor
  under BOTH digest algorithms. No generator drift, no second generator
  identity. The generated-artifacts law holds materially.
- **MCP-T1 sha line is correct as written** — no edit to
  `mcpt1-descriptor-regen.md` required.

## Figure check (MCP-T1's other claims)

- **37 rows**: regen output line says `37 total row(s)`;
  `grep -c capabilityId lib/smalt/mcp/gen/smalt_mcp_surface.ttl` → 37. CONFIRMED.
- **55 lines added, 0 removed**: `diff` of on-disk descriptor vs
  pre-regen commit `934d21aa` version → 55 `>` lines, 0 `<` lines. CONFIRMED.
  (vs current HEAD `860261c9` the file is unchanged — the regen landed in
  that checkpoint commit.)

## Actions taken

1. FD-2 in `bkmcpskep-mcp-audit.md` annotated
   **[RESOLVED-WITH-CORRECTION 2026-10-22, BK-MCPSHA — finding WITHDRAWN]**
   with the full digested explanation, naming BK-MCPSKEP as finder.
2. No change to `mcpt1-descriptor-regen.md` (its sha was right all along).
3. Scratch: `tmp/bkmcpsha_descriptor_check.ex` (gitignored tmp/, left for
   replay); lane build root `_build-bkmcpsha` is scratch, coordinator may
   reclaim via `just lane-clean`.

## Falsifier status

- The FD-2 claim ("sha mis-recorded OR different generator identity") is
  falsified: one generator identity reproduces the file byte-exactly, and
  the receipted sha256 equals the on-disk sha256.
- Lesson (receipt-hygiene class): digest comparisons must name their
  algorithm; bare `shasum` is SHA-1 and will false-positive against any
  sha256 receipt.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ shasum -a 256 lib/smalt/mcp/generated/mcp_descriptor.ex
5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38  lib/smalt/mcp/generated/mcp_descriptor.ex
shasum exit 0
```

Re-check verdict: PASS — the on-disk descriptor sha256 still equals the
receipt-recorded `5c9446bd…` byte-for-byte.
