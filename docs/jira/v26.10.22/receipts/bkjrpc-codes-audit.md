# BK-JRPC — JSON-RPC error-code audit of lib/smalt/mcp/router.ex, ALIVE

Context: solo
Standing: ALIVE
Date: 2026-10-22
Owner lane: BK-JRPC
Files: `lib/smalt/mcp/router.ex` (one-attribute fix, BK-MCPW class)

## Method

Enumerated every error path in `lib/smalt/mcp/router.ex` against the
JSON-RPC 2.0 spec codes (-32700 parse / -32600 invalid request / -32601
method not found / -32602 invalid params / -32603 internal), then witnessed
each on the wire through real `Smalt.Mcp.Router.call/2` via `Plug.Test`
(`mix run --no-start`, no app boot needed — avoids the 8443 collision with
the live substrate). Post-fix, re-witnessed and ran mcpt1 + bkegs1 + expl8r
courts fresh.

## Per-path table

| # | Path (router.ex) | Stimulus | Spec code | Pre-fix wire | Post-fix wire | Verdict |
|---|---|---|---|---|---|---|
| 1 | `{:error, :invalid_json}` leg (~:305) | malformed JSON body | -32700 | 400, -32700, data.code PARSE_ERROR (witnessed, BK-MCPW fix live) | unchanged | SPEC-EXACT |
| 2 | `{:error, :invalid_request}` leg (~:316) | valid JSON, not a JSON-RPC 2.0 request object (missing method / wrong `jsonrpc` version) | -32600 | 400, **-32602**, data.code INVALID_REQUEST — DRIFT | 400, **-32600**, data.code INVALID_REQUEST | FIXED |
| 3 | batch-fallthrough `%{"method" => _other}` (~:288) | unknown method | -32601 | 200, -32601, METHOD_NOT_FOUND | unchanged | SPEC-EXACT |
| 4 | `tools/call` without `params.name` (~:279) | tools/call missing name | -32602 | 200, -32602, INVALID_PARAMS | unchanged | SPEC-EXACT |
| 5 | `{:more, _}` 8MiB body cap (~:296) | oversized body, 413 | judgment: -32602 defensible (shape rejected); -32600 arguable | 413, -32602 PAYLOAD_TOO_LARGE | unchanged | DEFENSIBLE (noted, not a defect) |
| 6 | `handle_errors/2` crash envelope (~:155) | unhandled exception | -32603 | 500, -32603 "Internal server error." (code-inspected) | unchanged | SPEC-EXACT |
| 7 | `@fegs1_fallback_body` literal (~:177) | handle_errors itself faulting (F-EGS1) | -32603 | 500, -32603 literal (code-inspected) | unchanged | SPEC-EXACT |
| 8 | tool refusals (`{:refusal, code, message}`) | tool-level failures | n/a — MCP `isError:true` tool results, not JSON-RPC error objects; codes are string tool codes (TOOL_NOT_FOUND, INVALID_PARAMS, ACTUATION_REFUSED, RESOURCE_NOT_FOUND, MCP_INTERNAL) | isError:true envelope | unchanged | IN-CONTRACT |

## Defect + repair (BK-MCPW class)

Path #2: `{:error, :invalid_request}` carried `@json_rpc_invalid_params`
(-32602) with data.code "INVALID_REQUEST" — the data.code said Invalid
Request while the wire code said Invalid Params. Identical one-attribute
class to BK-MCPW (that lane's undefined `@json_rpc_parse_error` expanded to
an atom; this lane's wrong-attribute reference pointed at the sibling code).
Fix: defined `@json_rpc_invalid_request -32_600` alongside its siblings
(router.ex ~:204) and pointed the `:invalid_request` leg at it. Wire delta
is exactly the one envelope field: `error.code` -32602 → -32600 on the
invalid-request leg; nothing else.

## Witness (embedded output)

Pre-fix (probe via `Plug.Test` + `Router.call/2`, `mix run --no-start`):

```
not rpc object: status=400 {"error":{"code":-32602,"data":{"code":"INVALID_REQUEST","message":"request is not a JSON-RPC 2.0 object"}},"id":null}
wrong version: status=400 {"error":{"code":-32602,"data":{"code":"INVALID_REQUEST","message":"request is not a JSON-RPC 2.0 object"}},"id":null}
```

Post-fix:

```
not rpc object: 400 {"error":{"code":-32600,...INVALID_REQUEST...}}
wrong version:  400 {"error":{"code":-32600,...INVALID_REQUEST...}}
malformed JSON: 400 -32700 PARSE_ERROR   (unchanged)
unknown method: 200 -32601 METHOD_NOT_FOUND (unchanged)
tools/call no name: 200 -32602 INVALID_PARAMS (unchanged)
```

## Verification (embedded output)

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-bkjrpc mix test \
    test/internal/mcpt1_dispatch_court_test.exs \
    test/internal/bkegs1_fence_court_test.exs \
    test/internal/expl8r_court_test.exs
Finished in 1.6 seconds (0.00s async, 1.6s sync)
Result: 28 passed

$ MIX_ENV=test MIX_BUILD_ROOT=_build-bkjrpc mix compile --force
$ grep -c "mcp/router" /tmp/bkjrpc_compile.log
0
```

Compile warning-free on router.ex (0 hits in the full `--force` log;
remaining warnings are pre-existing deps/yamerl Erlang deprecations).
Courts fresh green post-edit. No test-file edits (lane contract: router.ex +
receipt only); the wire witness above is the receipt for the fixed leg —
flagging that the mcpt1 court does not yet pin -32600, left to the mcpt1
owner.

## Landing provenance

Coordinator tick checkpoint 628ad822 swept this lane's router.ex fix to HEAD
as an in-flight snapshot (BK-JRPC not named in the checkpoint message —
disclosed here); this lane's commit 647c4600 carries the receipt only.
router.ex content at HEAD is byte-identical to what this lane verified (the
-32600 fix is at lines 204/321, witnessed post-sweep via the court run above,
which postdates the sweep).
