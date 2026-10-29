# BK-MCPW — `@json_rpc_parse_error` undefined-attribute repair, ALIVE

Context: solo
Standing: ALIVE
Date: 2026-10-22
Owner lane: BK-MCPW
Files: `lib/smalt/mcp/router.ex`, `test/internal/mcpt1_dispatch_court_test.exs`

## Defect

`lib/smalt/mcp/router.ex:309` referenced undefined module attribute
`@json_rpc_parse_error` (flagged by BK-XPRIF's receipt as pre-existing).
Triage: the reference is **live** — it sits in the `{:error, :invalid_json}`
leg of the `post "/"` router (malformed-JSON → typed 400 via
`send_json_rpc_error/6`), reachable on every malformed body. Not dead code;
not shadowed by the BK-EGS1 fence (the fence only intercepts unhandled
exceptions; `decode_rpc/1` returns the typed leg without raising).

## Repair

Defined the attribute per the JSON-RPC 2.0 spec parse-error code, alongside
its siblings:

```elixir
@json_rpc_parse_error -32_700
@json_rpc_method_not_found -32_601
@json_rpc_invalid_params -32_602
```

(router.ex, with the other JSON-RPC codes at ~line 203.)

Precise behavior delta: with the attribute undefined, Elixir expands
`@json_rpc_parse_error` to the atom `:json_rpc_parse_error` (plus a compile
warning), so the pre-fix wire face carried `"error": {"code":
"json_rpc_parse_error", ...}` — a stringified atom, not the spec code. The
fix changes the malformed-JSON envelope's `error.code` from that garbage atom
to the spec-correct `-32700` integer: the intended payload per the module's
error contract, and nothing else. The new court leg pins this.

## Court leg (mcpt1)

New leg in `test/internal/mcpt1_dispatch_court_test.exs`: POST malformed JSON
(`{"jsonrpc": "2.0", `) through the real `Router.call/2` wire face → assert
HTTP 400, `error.code == -32_700`, `error.data.code == "PARSE_ERROR"`,
`error.data.message == "invalid JSON body"`, `id == nil`.

## Verification (embedded output)

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-bkmcpw mix test \
    test/internal/mcpt1_dispatch_court_test.exs \
    test/internal/bkegs1_fence_court_test.exs
Finished in 1.5 seconds (0.00s async, 1.5s sync)
Result: 17 passed

$ MIX_ENV=test MIX_BUILD_ROOT=_build-bkmcpw mix test \
    test/internal/mcpt1_dispatch_court_test.exs --trace   # new leg
* test malformed JSON body renders the JSON-RPC -32700 PARSE_ERROR envelope (BK-MCPW) [L#155]
Result: 10 passed

$ MIX_ENV=test MIX_BUILD_ROOT=_build-bkmcpw mix compile --force
$ grep -c "mcp/router" /tmp/bkmcpw_compile.log
0
```

Compile warning-free on router.ex (0 hits for `mcp/router` in the full
`--force` compile log; remaining warnings in the log are pre-existing
`deps/yamerl` Erlang deprecations, unrelated to this file).
