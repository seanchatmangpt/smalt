# GAP-AZB20-1/4 — control-plane mounting plan (Plan-lane output, verbatim)

All 4 open cells share one root, confirmed in code:

- On a control-only boot (`SMALT_PLANES=control`), `Smalt.Plane.ControlSupervisor` starts only the ARM Bandit listener + TLS twin + LRO + Wasm — **`Smalt.Store` never starts**, so `:smalt_resources` etc. are undefined. ARM handlers dereference Store unguarded (HEAD route at `lib/smalt/arm_gateway/router.ex:4736` calls `Store.keys()`) → ArgumentError → adapter-rendered 500.
- KV/secrets probes target the TLS twin (9444), where `TlsTwinDispatch` routes `/keys /secrets /kv` to `Smalt.EgressRouter.call/2` — but EgressRouter's `with_route`/`not_ready?` guard (egress_router.ex:2725-2754) checks `tables_ready?(Smalt.Store.table_names())` and answers **503 RouteNotReady** when the tables are absent (the 12 FAIL cell).
- The resourcegraph probe hits plain-HTTP ARM (9443); ARM router has no `/providers/Microsoft.ResourceGraph/resources` route → catch-all 404. The handler exists and is Store-backed: `Smalt.DataPlane.ResourceGraph.query/3`.
- Crash-rendered 500s bypass `arm_request_id`'s `register_before_send` (router.ex:101-111) because the route raises before any `send_resp`; Bandit renders the 500 → 34 header-audit violations.

## Chosen: Option A — mount, don't declare out of scope

Three bounded edits, ~50 lines, zero StoreTable additions (Store.init is idempotent — creates each table only `if :ets.info(table) == :undefined`, store.ex:29-43):

1. **lib/smalt/plane/control_supervisor.ex** — start `Smalt.Store` in the control subtree only when `:data` is not selected (avoids "already started" on `:all`/data+control boots):

```elixir
defp store_child do
  case Application.get_env(:smalt, :planes, :all) do
    planes when planes == :all or :data in planes -> []
    _ -> [Smalt.Store]   # prepend first: Store -> ARM listener order
  end
end
```

Closes ARM 500s (cell 2) and KV 503 RouteNotReady (cell 5) in one move.

2. **lib/smalt/arm_gateway/router.ex** — crash-path header plug (closes cell 1 / GAP-AZB20-3):

```elixir
use Plug.ErrorHandler   # immediately after `use Plug.Router`

# in arm_request_id/2: stash the id so the crash path reuses it
conn |> put_private(:arm_request_id, request_id) |> register_before_send(...)

defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
  Logger.error("arm_gateway crash 500: #{Exception.format(kind, reason, stack)}")
  if conn.state == :unsent do
    rid = conn.private[:arm_request_id] || generate_uuid()
    send_arm_error(put_resp_header(conn, "x-ms-request-id", rid),
      500, "InternalServerError", "Internal server error.", conn.request_path)
  end
  :ok
end
```

3. **lib/smalt/arm_gateway/router.ex** — one route delegating to the existing engine (closes cell 3 / GAP-AZB20-6): `post "/providers/Microsoft.ResourceGraph/resources"` → `Smalt.DataPlane.ResourceGraph.query(subscriptions, body, api-version)`, `{:ok,s,r} -> send_json`, `{:error,s,r} -> send_arm_error` (probe expects 400 shape). First top-level `/providers` prefix on ARM; `TlsTwinDispatch` prefixes unchanged (TLS twin still goes to egress) — add a one-line comment in application.ex.

Lane-dirty md5 snapshots taken: router.ex a7a905c7…, egress_router.ex 78ea6a2a…, control_supervisor.ex 557027ba… (re-read before editing).

## Re-test commands

Full: `MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk` (private block 39443-39475). Targeted: arm-resources.probe.mjs (cell 2 → 404), resourcegraph.probe.mjs (cell 3 → 400), keyvault+secrets.probe.mjs (cell 5 → pass), recording-proxy header audit (cell 1 → 0 violations). Regression: `mix test test/data_plane/ test/arm/ test/wire/ test/azsim/`.

Effort: ≈1.5-2h solo. Alternative (declare control 500s out of scope + header plug only) not recommended — weakens the parity claim; the mount is idempotent and cheap.
