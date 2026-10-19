# V261019-03 — GAP-AZB20-1/4 plane-mounting implementation (Option A)

- **Release:** v26.10.19
- **Lane:** gap-azb20
- **Base:** HEAD `4fd2ff2ba80e618341dc85de3ef84fcb8702bff3` (postfix re-test
  evidence is against `502c4ed`; all 4 cells still FAIL on HEAD —
  `docs/jira/v26.10.18/receipts/i29-azb20-postfix.md`)
- **Status:** ready-for-work

## Objective

Close all four open GAP-AZB20 cells by mounting, not declaring out of scope
(`docs/jira/v26.10.18/azsim-burn/GAP-AZB20-1-PLAN.md`, Option A): ~50 lines,
3 edits, zero StoreTable additions — `Smalt.Store.init/1` is idempotent
(creates each table only `if :ets.info(table) == :undefined`,
`lib/smalt/store.ex:29-43`).

Root cause (confirmed in code): on a control-only boot
(`SMALT_PLANES=control`), `lib/smalt/plane/control_supervisor.ex:17-38` starts
only the ARM Bandit listener + TLS twin + LRO + Wasm — `Smalt.Store` never
starts, so `:smalt_resources` etc. are undefined; ARM handlers dereference
Store unguarded → ArgumentError → 500 (cell 2). EgressRouter's
`tables_ready?` guard answers 503 RouteNotReady on the TLS twin (cell 5). The
resourcegraph probe hits plain-HTTP ARM (9443) where the router has no
`/providers/Microsoft.ResourceGraph/resources` route → catch-all 404 (cell 3;
the engine exists: `Smalt.DataPlane.ResourceGraph.query/3`, data_plane/resource_graph.ex).
Crash-rendered 500s bypass `arm_request_id`'s `register_before_send`
(`lib/smalt/arm_gateway/router.ex:101-111`) because the route raises before
any `send_resp` — Bandit renders the 500 without `x-ms-request-id` → 34
header-audit violations (cell 1).

The plan's alternative (declare control-plane 500s out of scope) was
explicitly NOT recommended — do not take it; it weakens the parity claim and
the mount is idempotent and cheap.

## Files owned (this lane)

| File | Scope |
|---|---|
| `lib/smalt/plane/control_supervisor.ex` | conditional `Smalt.Store` child when `:data` not selected (closes cells 2 + 5) |
| `lib/smalt/arm_gateway/router.ex` | `use Plug.ErrorHandler` + `arm_request_id` private-stash + crash-path `handle_errors/2` (cell 1); `post "/providers/Microsoft.ResourceGraph/resources"` route (cell 3) |
| `lib/smalt/application.ex` | one-line comment noting the first top-level `/providers` prefix on ARM |
| `docs/jira/v26.10.19/receipts/` | postfix re-test receipt; GAP-AZB20 row-flip citations |

**NOT owned by this lane:** `lib/smalt/egress_router.ex` (ResourceGraph
egress arm already landed at `egress_router.ex:1515`; TLS-twin prefixes
unchanged); `lib/smalt/data_plane/resource_graph.ex` engine; `lib/smalt/store.ex`
(no table changes); SOVEREIGN register rows (lane 02).

## Tasks

### Task 1 — control_supervisor: mount Store when :data absent
Add a `store_child/0` helper returning `[]` when
`Application.get_env(:smalt, :planes, :all)` is `:all` or includes `:data`,
otherwise `[Smalt.Store]` — prepended FIRST (Store → ARM listener order) in
`init/1`'s children (`control_supervisor.ex:17-38`). Avoids "already started"
on `:all`/data+control boots.

### Task 2 — router: crash-path header plug
Immediately after `use Plug.Router` (`router.ex:17`): `use Plug.ErrorHandler`.
In `arm_request_id/2` (`router.ex:101`), stash the id:
`conn |> put_private(:arm_request_id, request_id) |> register_before_send(...)`.
Add `handle_errors/2`: log the exception, and if `conn.state == :unsent`,
send the ARM 500 `InternalServerError` shape reusing
`conn.private[:arm_request_id]` (falling back to a fresh uuid) in an
`x-ms-request-id` header (closes cell 1: 34 header-audit violations).

### Task 3 — router: ResourceGraph route
`post "/providers/Microsoft.ResourceGraph/resources"` delegating to
`Smalt.DataPlane.ResourceGraph.query/3` — `{:ok, s, r} -> send_json`,
`{:error, s, r} -> send_arm_error` (probe expects the 400 shape; currently
catch-all 404). First top-level `/providers` prefix on ARM; TLS-twin dispatch
unchanged — add the one-line `application.ex` comment.

### Task 4 — re-test + flips
Re-read lane-dirty files before editing (plan's md5 snapshots: router.ex
`a7a905c7…`, egress_router.ex `78ea6a2a…`, control_supervisor.ex
`557027ba…`). Run the probe matrix + regression, write the postfix receipt,
flip the GAP-AZB20 rows receipt-gated.

## Acceptance criteria

```bash
MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk
# cell 2 (arm-resources):     404 → pass (no more 500)
# cell 3 (resourcegraph):     400-shape pass (no more catch-all 404)
# cell 5 (keyvault+secrets):  pass (no more 503 RouteNotReady)
# header audit (cell 1):      0 violations
mix test test/data_plane/ test/arm/ test/wire/ test/azsim/   # green
grep -n "use Plug.ErrorHandler" lib/smalt/arm_gateway/router.ex          # 1 hit
grep -n "Smalt.Store" lib/smalt/plane/control_supervisor.ex              # mounted
grep -n "Microsoft.ResourceGraph" lib/smalt/arm_gateway/router.ex        # > 0 hits
```

## Falsifier

`SMALT_PLANES=control` boot, then:
```bash
curl -s http://127.0.0.1:9443/subscriptions/<sub>/resourceGroups/rg/providers/M.Foo/bars?api-version=2020-01-01
```
On the pre-fix tree this is an adapter-rendered 500 with no `x-ms-request-id`
header; post-fix it must be a well-formed ARM error response carrying the
request-id header. Likewise, `POST
/providers/Microsoft.ResourceGraph/resources` with a malformed body must
return the probe's expected 400 shape (not 404). If any cell still fails, the
GAP-AZB20 rows stay open — do not flip without the probe witness.
