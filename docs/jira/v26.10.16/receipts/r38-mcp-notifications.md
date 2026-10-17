# R38: MCP notifications

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/mcp/router.ex` (+26 diff), `lib/smalt/mcp/gen/smalt_mcp_surface.ttl`

## Claim

MCP notifications surface repairs landed.

## Re-run evidence

```
$ mix test test/mcp_test.exs test/mcp_wire_test.exs
Finished in 38.4 seconds (0.00s async, 38.4s sync)
81 tests, 0 failures
```

## Verdict

PASS. 81/0 over MCP unit + wire tiers.
