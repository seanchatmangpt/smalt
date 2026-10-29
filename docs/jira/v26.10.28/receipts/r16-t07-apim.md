# r16 — T-07: API Management resource model + policy execution

- window: v26.10.28 · ticket: `tickets/T07-apim-policy-execution.md` · date: 2026-10-29
- verdict-at-open: **PARTIAL** (adjacent primitives shipped) · verdict-at-close: **CODE-COMPLETE — awaiting integration run** (court written, NOT yet executed; compile-freeze SLA)
- deps note (r16 lane): **`sweet_xml` and `finch` are TRANSITIVE deps today** — present and compiled in `deps/` (`sweet_xml 0.7.5` via ex4pm/sparql; `finch 0.24.0` via req/tesla, `mix.lock` verified) but NOT direct entries in `mix.exs`. Promotion patch below; the integrator applies it before the integration run. Do NOT hand-roll policy XML parsing or use `:httpc` — the user scope directive (2026-10-29: "prefer established Elixir-ecosystem libraries") pins SweetXml + Finch.

## landed

| file | what |
|---|---|
| `lib/smalt/data_plane/apim.ex` | `Smalt.DataPlane.Apim` — ARM `Microsoft.ApiManagement/service(+apis/operations/policies)` CRUD over `Smalt.Store` `:smalt_resources` (downcased id keys, 201/200 create/update, parent-missing typed 404s, DELETE cascades the child tree, LIST via `list_prefix/2` filtered by `type`) + real-dialect policy XML parsing via SweetXml (`dtd: :none`, `quiet: true`): inbound `rate-limit` (calls / renewal-period / retry-after), `set-header` (name / value / exists-action), `validate-jwt` (header-name / failed-validation-httpcode / failed-validation-error-message / required-claims values+match), backend `forward-request` presence+timeout; `<base/>` no-op tolerated; ANY other inbound element, a non-`<policies>` root, or malformed XML (xmerl fatal / throw / exit) is a typed `{:error, 400, "InvalidPolicyXml", msg}`. Accepts both wire forms: ARM JSON body (`properties.value`, the az CLI face) and raw XML (`format=raw` face). |
| `lib/smalt/data_plane/apim_gateway.ex` | `Smalt.DataPlane.ApimGateway` — pass-through Plug serving two path families: (1) ARM data-plane `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{svc}/apis/{api}/{rest}` (fixed segments case-insensitive), (2) configured gateway base `Application.get_env(:smalt, :apim_gateway_base, "/api-gw")` → `/{base}/{svc}/{api}/{rest}` (api segment matches resource NAME, then `properties.path` alias; no subscription context — service located by downcased id suffix). Everything else passes through with the conn untouched. Executes policies service → api → operation (APIM inheritance order), document order within each doc. |
| `test/integration/apim_test.exs` | ExUnit court (in-process `Plug.Test` conns against `ApimGateway`, real Store, real Bandit backend on an OS-reserved port — ja5/sj4 pattern, real Finch TCP hop, real STS mint via `Smalt.Auth.StsKey.mint/1`). **WRITTEN, NOT RUN** — the authoring lane is compile-frozen. |

## DoD mapping (the Azure developer's view)

- **`az apim create`, add API + operation backed by a smalt service, attach real policy XML** → PUT the service/apis/operations/policies records through the ARM routes (wiring patch below) or the module API directly. Records echo real ARM shapes: `type` strings, `id`, `properties.provisioningState`/`gatewayUrl`, `sku`, `urlTemplate` with derived `templateParameters`.
- **`<rate-limit calls="5" renewal-period="60"/>`, requests 1–5 forward, request 6 gets 429 + Retry-After** → fixed-window counter in the `:smalt_apim_rate` ETS table (mirrors `:arm_rate_limit`: named table, heir to `:init`, `:ets.update_counter/4`, previous window pruned). The court runs exactly this matrix (5×200, 6th = 429, `Retry-After: 7` from the policy's `retry-after` attr, body `{"statusCode":429,"message":"Rate limit is exceeded"}` — the real gateway's breach face).
- **`set-header` additions visible on the backend side** → `put_req_header` with `exists-action` semantics (overwrite default / append / skip / delete); the court backend echoes `req_headers` and asserts `x-forwarded-slice = smalt-apim` arrived.
- **Swap in `<validate-jwt>`; tokenless → 401 with the WWW-Authenticate shape; missing claim → 403** → token extracted from the policy's `header-name` (default Authorization), verified through `Smalt.Auth.Bearer.verify_bearer/1` (signature/exp/nbf/aud/iss — full STS, zero relaxed crypto), then `required-claims` value checks against the SIGNED payload. 401s carry `WWW-Authenticate: Bearer ...` via `Smalt.Auth.Bearer.challenge_value/2` (house shape) + ARM envelope; claim failures default 403 (no challenge); `failed-validation-httpcode` / `failed-validation-error-message` overrides honored. Forgery court: a valid token with a broken signature refuses 401.
- **`az apim show` lists it like the real service** → LIST routes return the Store records filtered by ARM `type`; policy records stay ARM-exact (`properties.format = "xml"`, `properties.value` = raw XML) — parsed form is recomputed per request, no derived state.

## court list (`test/integration/apim_test.exs`)

1. ARM CRUD: service/api/operation PUT/GET/LIST/DELETE-cascade shapes + parent-missing 404 + 200-on-update.
2. Policy scopes: service/api/operation all store ARM-exact records (raw-XML and ARM-JSON PUT forms).
3. Malformed policy PUT: 8 refusal shapes (unclosed, mismatched close, wrong root, unsupported element, missing attr, non-integer calls, nameless set-header, empty doc) → all `{:error, 400, "InvalidPolicyXml", msg}`, nothing stored, subsequent valid PUT still works.
4. Gateway forwarding + set-header visible on the real backend conn.
5. Rate-limit window: 5 forwards, 6th 429 + Retry-After + real body; per-operation window scoping.
6. validate-jwt tokenless/malformed/garbage-scheme → 401 + `WWW-Authenticate: Bearer` challenge.
7. validate-jwt claim matrix: no claim → 403 (configured message, no challenge), `match="any"` reader/contributor → forwarded.
8. Forgery: broken signature on a signed-looking token → 401 (claims read the VERIFIED payload only).
9. ARM data-plane family serves the gateway (downcased provider segments) + typed 404 on unknown api.
10. No-backend operation → typed 502 `BackendUnavailable`.
11. Pass-through: non-APIM paths leave `conn` with `state == :unset`, `halted == false`.

## EXACT wiring patch (integrator applies)

### 1. `mix.exs` — promote the transitive deps (versions match `mix.lock`: sweet_xml 0.7.5, finch 0.24.0)

```diff
       {:jason, "~> 1.4"},
       {:joken, "~> 2.6"},
+      # T-07 (r16): promoted from transitive — sweet_xml rides ex4pm/sparql,
+      # finch rides req/tesla; versions pinned to the mix.lock entries.
+      {:sweet_xml, "~> 0.7"},
+      {:finch, "~> 0.24"},
```

### 2. `lib/smalt/arm_gateway/router.ex` — mount the gateway plug + alias

After line 76 (`plug(Smalt.Egress.ThrottlePlug)`), before `plug(:match)`:

```diff
   plug(:arm_request_id)
   plug(:arm_throttle)
   # AZURE-FIDELITY lane 18: control-plane throttling realism — DEFAULT-OFF
   # (rate/burst nil). Gate-off the plug passes the conn through untouched.
   plug(Smalt.Egress.ThrottlePlug)
+  # T-07 (r16): APIM policy-execution gateway. Matches the ARM data-plane
+  # shape .../providers/Microsoft.ApiManagement/service/{svc}/apis/{api}/...
+  # plus the configured gateway base (default "/api-gw"). Passes through
+  # untouched (no send, no halt) for every other path, so every route below
+  # is unaffected.
+  plug(Smalt.DataPlane.ApimGateway)
   plug(:match)
   plug(:dispatch)
```

With the other aliases (after `alias Smalt.Policy`):

```diff
   alias Smalt.ArmGateway.ResourceHealth
   alias Smalt.Policy
+  alias Smalt.DataPlane.Apim
```

### 3. `lib/smalt/arm_gateway/router.ex` — resource routes, inserted immediately BEFORE the catch-all (`# -- Catch-all (proper ARM envelope) ------` / `match _ do`, line ~8400)

```elixir
  # ===========================================================================
  # T-07 (r16): Microsoft.ApiManagement family — handlers delegate to
  # Smalt.DataPlane.Apim. NOTE: NO check_api_version gate on this family —
  # Microsoft.ApiManagement is not in Smalt.Registry, so a Registry-backed
  # gate would couple the routes to a strict-mode refusal (divergence #8
  # below). az/azurerm always send api-version; it is accepted verbatim.
  # ===========================================================================

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc" do
    case Apim.put_service(sub_id, rg_name, svc, conn.body_params) do
      {:ok, status, record} -> send_json(conn, status, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc" do
    case Apim.get_service(sub_id, rg_name, svc) do
      {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc" do
    case Apim.delete_service(sub_id, rg_name, svc) do
      {:ok, _, _} -> send_json(conn, 200, "{}")
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api" do
    case Apim.put_api(sub_id, rg_name, svc, api, conn.body_params) do
      {:ok, status, record} -> send_json(conn, status, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api" do
    case Apim.get_api(sub_id, rg_name, svc, api) do
      {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api" do
    case Apim.delete_api(sub_id, rg_name, svc, api) do
      {:ok, _, _} -> send_json(conn, 200, "{}")
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis" do
    send_list(conn, Apim.list_apis(sub_id, rg_name, svc))
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op" do
    case Apim.put_operation(sub_id, rg_name, svc, api, op, conn.body_params) do
      {:ok, status, record} -> send_json(conn, status, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op" do
    case Apim.get_operation(sub_id, rg_name, svc, api, op) do
      {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op" do
    case Apim.delete_operation(sub_id, rg_name, svc, api, op) do
      {:ok, _, _} -> send_json(conn, 200, "{}")
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations" do
    send_list(conn, Apim.list_operations(sub_id, rg_name, svc, api))
  end

  # Policies exist at three scopes. PUT accepts the ARM JSON body
  # (properties.value — what az CLI sends) OR raw XML (format=raw). Raw XML
  # bodies are not JSON-parsed by Plug.Parsers; the raw bytes ride
  # conn.private[:smalt_raw_body] (Auth.BodyCache).

  defp apim_policy_input(conn) do
    case conn.body_params do
      %{"properties" => %{"value" => _}} -> conn.body_params
      _ -> conn.private[:smalt_raw_body] || ""
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/policies/:name" do
    apim_policy_route(conn, :put, sub_id, rg_name, svc, :service, nil, nil, name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/policies/:name" do
    apim_policy_route(conn, :put, sub_id, rg_name, svc, :api, api, nil, name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op/policies/:name" do
    apim_policy_route(conn, :put, sub_id, rg_name, svc, :operation, api, op, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/policies/:name" do
    apim_policy_route(conn, :get, sub_id, rg_name, svc, :service, nil, nil, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/policies/:name" do
    apim_policy_route(conn, :get, sub_id, rg_name, svc, :api, api, nil, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op/policies/:name" do
    apim_policy_route(conn, :get, sub_id, rg_name, svc, :operation, api, op, name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/policies/:name" do
    apim_policy_route(conn, :delete, sub_id, rg_name, svc, :service, nil, nil, name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/policies/:name" do
    apim_policy_route(conn, :delete, sub_id, rg_name, svc, :api, api, nil, name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ApiManagement/service/:svc/apis/:api/operations/:op/policies/:name" do
    apim_policy_route(conn, :delete, sub_id, rg_name, svc, :operation, api, op, name)
  end

  defp apim_policy_route(conn, :put, sub_id, rg_name, svc, scope, api, op, name) do
    case Apim.put_policy(sub_id, rg_name, svc, scope, api, op, name, apim_policy_input(conn)) do
      {:ok, status, record} -> send_json(conn, status, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  defp apim_policy_route(conn, :get, sub_id, rg_name, svc, scope, api, op, name) do
    case Apim.get_policy(sub_id, rg_name, svc, scope, api, op, name) do
      {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end

  defp apim_policy_route(conn, :delete, sub_id, rg_name, svc, scope, api, op, name) do
    case Apim.delete_policy(sub_id, rg_name, svc, scope, api, op, name) do
      {:ok, _, _} -> send_json(conn, 200, "{}")
      {:error, status, code, msg} -> send_arm_error(conn, status, code, msg)
    end
  end
```

(INTEGRATOR NOTE: the `@apim_policy_scopes` for-comprehension block in the middle is DEAD DRAFT TEXT left visible intentionally for review — the integrator should apply ONLY the literal nine policy routes + `apim_policy_route/9` + `apim_policy_input/1` helpers below it, and skip that block entirely. Literal routes are the house pattern; Plug.Router matches them all.)

### 4. Optional config (`config/*.exs`)

```elixir
# T-07 (r16): gateway base prefix for family 2; default in code is "/api-gw".
config :smalt, :apim_gateway_base, "/api-gw"
```

## documented divergences (honest, all deterministic)

1. **429 body** is the REAL APIM gateway face (`{"statusCode":429,...}`), not the ARM envelope — the ARM-wide `:arm_rate_limit` envelope stays untouched on its own surface.
2. **403 carries no `WWW-Authenticate`** (the token authenticated; the policy refused the claim). Only 401s challenge.
3. **`validate-jwt` verifies against the substrate STS** (same keys/issuer contract as every plane) rather than an APIM-external IdP — the mounted STS IS the IdP in smalt.
4. **Finch lifecycle**: no supervised instance exists (and `application.ex` is off-limits this window), so `ApimFinch` is started lazily in the first requesting process (`already_started`-tolerant); a dead keep-alive connection task takes the pool with it and the next request re-arms. Rate windows are ETS-side and unaffected. Integrator may move `Finch.start_link(name: :smalt_apim_finch)` into `Smalt.Application` when wiring.
5. **Backend resolution**: operation `properties.backendUrl` (smalt extension) overrides api `properties.serviceUrl` (the real ARM field). Missing backend → typed 502 `BackendUnavailable` (real APIM's dead-backend face).
6. **Cross-type policy order**: within one document, execution is document order; across scopes it is the fixed service → api → operation inheritance order (real APIM composes `<base/>` the same way).
7. **`rate-limit-by-key` / `set-body`** are NOT in this slice (ticket non-goals name the four policies; the map's CLOSE names the resource model). Unknown inbound elements are refused at PUT, so a future slice can add them without silent-policy drift.
8. **No api-version gate on the APIM routes** (Microsoft.ApiManagement is absent from `Smalt.Registry` — a `check_api_version/2` mount would 400 under `strict_version_validation`). az/azurerm always send api-version; registering the provider in the Registry is the follow-up if strict-mode parity is wanted.

## verdict

CODE-COMPLETE at r16: resource model + policy dialect + gateway execution + court all authored; awaiting the integrator run (`mix test test/integration/apim_test.exs` + `az`/SDK ARM probe after the wiring patch). A CLOSE without a receipt is not a CLOSE — the integration run is the receipt's second half.
