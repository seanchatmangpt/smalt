# BK-JRPC2 — mcpt1 court pins the -32600 invalid-request leg, ALIVE

Context: solo
Standing: ALIVE
Date: 2026-10-22
Owner lane: BK-JRPC2
Files: `test/internal/mcpt1_dispatch_court_test.exs` (two new test legs, no lib/ changes)

## Method

BK-JRPC's audit
(`docs/jira/v26.10.22/receipts/bkjrpc-codes-audit.md`, path #2) fixed the
`:invalid_request` drift in `lib/smalt/mcp/router.ex` (wire code -32602 →
-32600 per JSON-RPC 2.0 spec) and flagged that the mcpt1 court pinned -32700
but not -32600. This lane closed the flag: added the two -32600 legs to
`test/internal/mcpt1_dispatch_court_test.exs`, same wire shape as the
existing BK-MCPW -32700 leg (real `Plug.Test` → `Router.call/2`):

1. valid JSON that is not a JSON-RPC 2.0 request object (`{"foo": 1}`) →
   400, `error.code == -32600`, `data.code == "INVALID_REQUEST"`, `id: null`
2. wrong `jsonrpc` version (`"1.0"`) → 400, `error.code == -32600`,
   `data.code == "INVALID_REQUEST"`

No lib/ edits; the court now fences the fix against regression.

## Verification (embedded output)

```
$ export PATH="$HOME/.asdf/shims:$PATH"
$ cd /Users/sac/smalt && MIX_ENV=test MIX_BUILD_ROOT=_build-bkjrpc2 \
    mix test test/internal/mcpt1_dispatch_court_test.exs \
             test/internal/bkegs1_fence_court_test.exs \
             test/internal/expl8r_court_test.exs
```

(mcpt1 + regression bkegs1 + expl8r, fresh, in one run)

```
Finished in 1.0 seconds (0.00s async, 1.0s sync)
Result: 30 passed
```

30 = 28 pre-existing (per BK-JRPC receipt) + 2 new -32600 legs. The visible
stack trace in the output is bkegs1's intentional boom-rig negative control
(expected, pre-existing); zero failures, zero other changes.
