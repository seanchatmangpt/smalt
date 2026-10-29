# Receipt: BK-MCPF2 — MCP fence no-regression verify (v26.10.22)

- **Date**: 2026-10-22
- **Lane**: BK-MCPF2 (read-only verify lane)
- **Standing**: ALIVE — the 37-tool JSON-RPC face holds identically post-BK-EGS1 fence
- **Context**: solo
- **Subject**: `Smalt.Mcp.Router` (port 9545) on the current tree at the
  BK-EGS1 fence commit (1dd8d5a5), verified read-only over the real wire and
  the real test suite.

## 1. Whole MCP suite + adversarial probe set, fresh

Suite (private lane build root, `_build-ft-7d1d1afe`):

```
$ MIX_BUILD_ROOT=_build-lane-bkmcpf2 scripts/fast_test.sh \
    test/internal/mcpt1_dispatch_court_test.exs \
    test/internal/bkegs1_fence_court_test.exs \
    test/internal/expl8r_court_test.exs
Result: 26 passed   (wall 173s)
```

The bkegs1 legs that render stack traces in the log output (ArmBoomRig →
`Bandit.Pipeline.call_plug!`) are the fault legs doing their job — the run
is 26/26 passed.

Adversarial wire probes (live loopback, port 9545, fresh this session):

| probe | verdict |
|---|---|
| malformed params (`cosmos.query` db:123, coll:null) | HTTP 200, typed `INVALID_PARAMS` ("requires db and coll") |
| `jsonrpc:"9.9"` | HTTP 400, JSON-RPC -32602, data.code `INVALID_REQUEST`, id:null |
| missing `method` | HTTP 400, same typed -32602 `INVALID_REQUEST` |
| 2 MB `db` param | HTTP 200, typed success over empty/nonexistent db (`_count:0`) — no 500 |
| unknown tool `no.such.tool` | HTTP 200, typed `TOOL_NOT_FOUND` |
| actuation id `blob.delete` | HTTP 200, typed `ACTUATION_REFUSED` |

**Zero naked 500s.** Every probe answered a well-formed JSON-RPC envelope.

## 2. Fence interaction: double-respond probe

The fence only fires when `conn.state in [:unset, :set]` (nothing sent yet)
and the rescue path re-checks the same guard, so double-respond is
structurally excluded; witnessed at the wire by re-reading each error-path
body with a strict `JSONDecoder.raw_decode` — every body is EXACTLY one JSON
document with zero trailing bytes, and `content-length` matches:

```
INVALID_PARAMS      content-length 231  json docs: 1, trailing bytes: 0
-32602 INVALID_REQUEST  content-length 134  json docs: 1, trailing bytes: 0
TOOL_NOT_FOUND      content-length 311  json docs: 1, trailing bytes: 0
ACTUATION_REFUSED   content-length 416  json docs: 1, trailing bytes: 0
```

No error path now sends twice (fence + handler); single well-formed envelope
per request. The `x-ms-request-id` header on the 500 face is generated per
request (fence) or the constant `00000000-0000-4000-8000-000000000000`
(fallback).

## 3. Face invariants

- `tools/list` over the live wire: **37** tools (also confirms the substrate
  beam is NOT the stale FD-1 beam — the stale beam answered 32).
- `ACTUATION_REFUSED` witnessed live on `blob.delete` (probe P6 above).

## 4. Scope note (honest boundary)

The live-wire probes exercise handled error paths only; a live-wire witness
of the 500 fence itself would require a real unhandled crash on the shared
substrate, which this read-only lane does not perform (the shared beam's
beam-age vs the fence commit is not provable from handled paths). Fence
behavior IS witnessed fresh on this tree by the bkegs1 court legs (real
Bandit rigs, LEG2/3/5/6) inside the 26-passed run above — real server, real
crash, real fence envelope.

## 5. Verdict

The BK-EGS1 fence changes nothing on any handled MCP error path (all six
probe classes byte-identical verdicts to the pre-fence bkmcpskep audit) and
covers the previously-naked crash path. **Standing: ALIVE.**
