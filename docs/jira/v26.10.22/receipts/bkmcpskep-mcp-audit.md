# Receipt: BK-MCPSKEP — whole-MCP-surface skeptic audit (v26.10.22)

- **Date**: 2026-10-22
- **Lane**: BK-MCPSKEP (read-only skeptic audit)
- **Standing**: ALIVE (MCP face holds; two typed findings, neither a face defect)
- **Context**: solo
- **Subject**: the full 37-tool JSON-RPC face of `Smalt.Mcp.Router` (port 9545)
  post MCP-T1 descriptor regen

## Wait-bounded on in-flight lanes

- **MCP-T1**: LANDED during this audit (receipt
  `mcpt1-descriptor-regen.md`, standing ALIVE, bounded poll hit at poll 1 of
  a 10x30s loop). Descriptor regen + 9-test wire court verified in this
  audit independently (below).
- **EXPL8-R**: NOT landed within the bounded window (receipt
  `expl8r-repairs.md` absent after ~7 min of bounded polls; owner still holds
  `lib/smalt/attestation/maa.ex`). Scope check: EXPL8-R's files
  (attestation + bench harnesses) have **zero overlap** with the MCP surface
  (`lib/smalt/mcp/`, `Smalt.Mcp.Router`), so the MCP-face verdict does not
  block on it.

## Census (both directions)

Static, compiled source of truth (`mix run --no-start` over the working
tree; descriptor already post-regen at audit start):

- `Smalt.Mcp.Descriptor.capabilities()` — **37** tools
- `defp invoke/2` clauses — **37** (every registered tool has an implementing clause)
- `defp input_schema/1` clauses — **37**
- `DESC_ONLY` (registered, no clause): `[]`
- `INVOKE_ONLY` (clause, not registered): `[]`
- `SCHEMA_MINUS_INVOKE` / `INVOKE_MINUS_SCHEMA`: `[]`

TTL drift fence, independently re-derived (not via the court only):

```
$ grep -c 'ema:capabilityId' lib/smalt/mcp/gen/smalt_mcp_surface.ttl
37
$ map_size(Descriptor.capabilities())  # mix run --no-start
37
```

## ACTUATION_REFUSED gate — witnessed live

Over the real wire (loopback HTTP to the shared substrate, port 9545):

```
$ curl -s http://localhost:9545/ -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"blob.delete","arguments":{}}}'
→ result.isError == true, structuredContent.code == "ACTUATION_REFUSED",
  "refused: \"blob.delete\" is an actuation tool; the smalt substrate exposes
  read-only MCP tools only and refuses unreceipted DO by law"
```

Negative control on the same wire: unknown non-actuation id → typed
`TOOL_NOT_FOUND` (not the stronger actuation verdict). Both directions of
the actuation-verb classification witnessed live.

## Adversarial probes (live wire, all typed — zero 500s)

| probe | verdict |
|---|---|
| malformed params (`cosmos.query` with `db:123, coll:null`) | typed `INVALID_PARAMS` ("requires db and coll") |
| `jsonrpc:"9.9"` | JSON-RPC error -32602, data.code `INVALID_REQUEST` ("not a JSON-RPC 2.0 object"), `id:null` |
| missing `method` | same typed -32602 `INVALID_REQUEST` |
| 2 MB `db` param into `cosmos.query` | no 500; typed success over an empty/nonexistent db (empty document list; data-plane concern, not a face defect) |
| unknown tool `no.such.tool` | typed `TOOL_NOT_FOUND` |
| mutating id `blob.delete` | typed `ACTUATION_REFUSED` (above) |

## Suites + court

```
$ scripts/fast_test.sh test/internal/expl8r_court_test.exs test/internal/mcpt1_dispatch_court_test.exs
Result: 20 passed   (wall 104s, build root _build-ft-216802c7)
```

Includes the mcpt1 drift fence (`length(Descriptor.capabilities()) == 37 ==
TTL capabilityId count`), all-5-wave-6 tools/list assertion over the real
wire face, end-to-end dispatch of `cosmos.ttl.effective`, and the
`kv.rotationpolicy.put` → `ACTUATION_REFUSED` leg.

## Descriptor regen faithfulness (skeptic re-derivation)

Fresh regen rerun by this lane (exact receipt command, `caps=` query name,
output redirected to `tmp/` — the tool refuses out-of-root targets, typed):

```
$ shasum tmp/bkmcpskep_descriptor_check.ex lib/smalt/mcp/generated/mcp_descriptor.ex
35f25577bc4751135793001355d80518b1fe4ee5  tmp/bkmcpskep_descriptor_check.ex
35f25577bc4751135793001355d80518b1fe4ee5  lib/smalt/mcp/generated/mcp_descriptor.ex
```

On-disk generated descriptor is **byte-identical** to a fresh regen from the
TTL — the generated-artifacts law holds materially.

## Typed findings (repair tickets, none block ALIVE for the face)

1. **FD-1 — shared-substrate stale beam**: the substrate process on 9545
   booted before the regen commit; its `tools/list` returns **32** tools
   (missing exactly the 5 wave-6 tools; nothing extra). The router maps
   `Descriptor.capabilities()` directly, so this is a stale-beam artifact,
   not a code filter. **Repair**: coordinator `just substrate-down &&
   just substrate-up` (flock-managed) after the wave settles; expected
   tools/list == 37 post-remount. Re-probe one-liner embedded above.
2. **FD-2 — [RESOLVED-WITH-CORRECTION 2026-10-22, BK-MCPSHA] mcpt1 receipt
   sha256 mis-recorded**: `mcpt1-descriptor-regen.md`
   claims a byte-identical rerun sha256 of `5c9446bd…`, but (a) on-disk is
   `35f25577…` and (b) the claim is internally inconsistent with the
   receipt's own "55 lines added" diff (a regen identical to pre-regen adds
   0 lines). Fresh regen today reproduces the on-disk file exactly, so the
   generator is faithful; the sha line is the defect. **Repair**:
   MCP-T1 owner re-receipts the sha against `35f25577…` (or explains the
   different generator identity that produced `5c9446bd…` — generator
   plurality, primitive R, would be a legitimate explanation if named).

   **Correction (2026-10-22, lane BK-MCPSHA — finder BK-MCPSKEP, finding
   WITHDRAWN)**: FD-2 was an algorithm-confusion artifact, not a defect.
   `35f25577bc4751135793001355d80518b1fe4ee5` is the **SHA-1** of the same
   file; its SHA-256 is exactly the receipted
   `5c9446bdc675efa9eb602f846ce01bc2d7610244be567b2d265bff24b0457e38`.
   BK-MCPSKEP's verification block ran bare `shasum` (SHA-1) while comparing
   against a SHA-256 claim. BK-MCPSHA re-derived: fresh regen via the exact
   receipt command is byte-identical to the on-disk descriptor (both digests
   match); sha256 on disk = `5c9446bd…` (matches MCP-T1 receipt, no edit
   needed); the 55-added/0-removed diff is confirmed against pre-regen
   commit 934d21aa. The FD-2 "internally inconsistent with 55 lines added"
   reasoning was also unsound: the 55-line diff is regen-vs-pre-regen, not
   regen-vs-regen. Receipt `bkmcpsha-sha-fix.md` is the correction receipt.

## Verdict

ALIVE for the whole 37-tool MCP face: census closes both directions, the
read-only actuation gate is witnessed live with typed structured codes,
adversarial probes return typed verdicts (no 500s), the mcp suites + mcpt1
court pass 20/20, and the generated descriptor reproduces byte-exactly from
the TTL. FD-1/FD-2 are coordinator/owner repairs on top of an ALIVE face.
