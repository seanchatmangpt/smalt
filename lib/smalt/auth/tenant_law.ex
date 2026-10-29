defmodule Smalt.Auth.TenantLaw do
  @moduledoc """
  G4 multi-tenant fence law (CZ2: cross-tenant read/query/DELETE witnessed on
  the cosmos plane). Shared helper for the fence lanes: every tenant-scoped
  surface derives its caller identity the same way and namespaces its storage
  keys the same way.

  ## Identity (extract/resolve)

  `extract_tenant/1` reads the `tid` claim off the `Authorization: Bearer`
  JWT on the conn. It MUST be called downstream of `Smalt.Auth.Bearer` — in
  `:enforce` mode the plug has already verified the signature, `exp`, `aud`
  and `iss` on this same conn before dispatch, so the payload read here is
  the VERIFIED bearer's claim, not a client-asserted one. Returns
  `{:ok, tid}` | `:no_tenant` (typed: anonymous/dev tokens without `tid`,
  non-JWT bearer forms, or no Authorization header at all).

  ## Back-compat law (the fence must not move single-tenant courts)

  Tokens without `tid` resolve to the legacy home tenant
  (`config :smalt, :home_tenant`, default "smalt-home"), and the home
  tenant's storage keys are byte-identical to the pre-fence legacy keys
  (`tenant_scoped_key(home, key) == key`). Every existing single-tenant court
  keeps its exact key layout and passes unchanged — the fence only adds a
  namespace for bearers that actually carry a foreign `tid`.

  ## Namespacing (tenant_scoped_key)

  `tenant_scoped_key(tenant, key)`: home tenant -> `key` (legacy byte-compat);
  foreign tenant -> `"<tenant>/<key>"`. Doc keys on the cosmos plane become
  `{tenant, db, coll, doc_id}` in this form; queries and feeds scan ONLY the
  caller's namespace.

  ## Cross-tenant refusal (typed 403)

  A point operation addressed at a key that exists only under ANOTHER
  tenant's namespace is refused `403 Forbidden` with the real-Azure Cosmos
  error envelope — documented on Microsoft Learn, "HTTP status codes for
  Azure Cosmos DB" (REST), 403: `{"code": "Forbidden", "message": ...}`
  (Azure AD data-plane access denied answers the same `Forbidden` envelope,
  never 401 and never a silent 404):

      {"code": "Forbidden", "message": "Given request does not authorize
       access to the resource under the caller's tenant."}
  """

  import Plug.Conn

  # The LEGACY mint tenants of this substrate: every pre-fence dev identity
  # must resolve HOME (byte-identical legacy keys), never into the fence.
  # "smalt-tenant" — the substrate's own token endpoint and the athena
  # StsClient/SmaltCosmosClient default (/smalt-tenant/oauth2/v2.0/token);
  # "common" — the substrate.ts @azure/cosmos SDK credential default
  # (DEFAULT_TENANT, /common/oauth2/v2.0/token). The court witness: S7.1
  # seeded via the SDK (tid="common") while the S7.2-S7.5 wire probes minted
  # tid="smalt-tenant" — one namespace divergence, four wrong statuses.
  # Overridable via config :smalt, :legacy_tenants / :home_tenant.
  @home_default "smalt-tenant"
  @legacy_default ["smalt-tenant", "common"]
  @tenant_header "x-smalt-tenant"

  @doc "Legacy home tenant: the namespace of every token WITHOUT a `tid`."
  def home_tenant do
    Application.get_env(:smalt, :home_tenant, @home_default)
  end

  @doc """
  The legacy dev mint tenants: tids that name THIS substrate's own pre-fence
  identities. All of them resolve to `home_tenant/0` — one shared legacy
  namespace, byte-identical keys.
  """
  def legacy_tenants do
    Application.get_env(:smalt, :legacy_tenants, @legacy_default)
  end

  # tid normalization: a legacy dev tid is HOME; anything else is itself.
  defp normalize_tid(tid) do
    if tid == home_tenant() or tid in legacy_tenants(), do: home_tenant(), else: tid
  end

  @doc """
  `{:ok, tid}` | `:no_tenant` — the `tid` claim of the VERIFIED bearer on
  `conn` (call downstream of `Smalt.Auth.Bearer`; the plug verifies the
  signature/claims on the same conn in `:enforce` mode). Typed `:no_tenant`
  for anonymous/dev tokens without `tid` — those keep legacy (home-tenant)
  behavior.
  """
  def extract_tenant(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] -> tenant_from_auth_value(value)
      _ -> :no_tenant
    end
  end

  @doc "`extract_tenant/1` with the home-tenant default applied (legacy tids normalized to home)."
  def resolve_tenant(conn) do
    case extract_tenant(conn) do
      {:ok, tid} -> normalize_tid(tid)
      :no_tenant -> home_tenant()
    end
  end

  @doc """
  Header-map face for the data plane: data-plane functions receive a plain
  header map (EgressRouter.header_map/1), not the conn. Resolution order:
  an explicit `x-smalt-tenant` stamp (set by the egress route layer from
  `resolve_tenant/1`) wins; otherwise the `authorization` bearer in the map
  is parsed the same way (`tenant_from_token/1`); otherwise home.
  """
  def tenant_from_headers(headers) when is_map(headers) do
    case Map.get(headers, @tenant_header) do
      tid when is_binary(tid) and tid != "" ->
        tid

      _ ->
        case Map.get(headers, "authorization") do
          value when is_binary(value) ->
            case tenant_from_auth_value(value) do
              {:ok, tid} -> normalize_tid(tid)
              :no_tenant -> home_tenant()
            end

          _ ->
            home_tenant()
        end
    end
  end

  @doc """
  Stamp the tenant onto a header map for data-plane calls whose egress route
  already resolved the conn. `stamp(header_map(conn), conn)`.
  """
  def stamp(headers, conn) when is_map(headers) do
    Map.put(headers, @tenant_header, resolve_tenant(conn))
  end

  @doc """
  Storage-key namespacing. Home tenant -> `key` UNCHANGED (legacy byte-compat
  with every pre-fence single-tenant court); any other tenant ->
  `"<tenant>/<key>"`.
  """
  def tenant_scoped_key(tenant, key) do
    if tenant == home_tenant(), do: key, else: "#{tenant}/#{key}"
  end

  @doc """
  True when `legacy_key` exists in `table` ONLY under a namespace that is NOT
  `tenant`'s: the key is either the legacy (home) key itself or a
  another tenant's scoped key. Backed by a real `Smalt.Store.keys/1`
  scan — no mocks.
  """
  def foreign_doc?(table, tenant, legacy_key) do
    own = tenant_scoped_key(tenant, legacy_key)
    legacy = legacy_key

    Enum.any?(Smalt.Store.keys(table), fn k ->
      k != own and (k == legacy or String.ends_with?(k, "/#{legacy}"))
    end)
  end

  @doc """
  The real-Azure typed 403 body for a cross-tenant point access: the Cosmos
  `Forbidden` envelope (Microsoft Learn, HTTP status codes for Azure Cosmos
  DB; Azure AD data-plane denial answers `{"code": "Forbidden", ...}`).
  Wrapped into `{:ok, 403, headers, body}` by the data plane via
  `error_response/5` so the wire face (session/etag headers, correlation-id
  site log) matches every other typed cosmos refusal.
  """
  def mismatch_response do
    %{
      "code" => "Forbidden",
      "message" =>
        "Given request does not authorize access to the resource under the caller's tenant."
    }
  end

  @doc "Message body for the typed 403 (also used by bulk-resource faces)."
  def mismatch_message, do: mismatch_response()["message"]

  # -- internals --------------------------------------------------------------

  # V21: the @azure/cosmos SDK does not send `Authorization: Bearer <jwt>` —
  # its AAD pipeline sends the Cosmos wire form
  # `type=aad&ver=1.0&sig=<base64url jwt>`. The tid lives in the SAME jwt
  # (the `sig` parameter), so both transports must resolve to one caller
  # namespace (V21 regression court: a Bearer-created container was invisible
  # to the SDK transport after the D3 registry namespacing — the aad form
  # resolved home and the container read 404'd "Entity with id ... not
  # found"). Typed `:no_tenant` for anything unparseable (dev face unchanged).
  defp tenant_from_auth_value("Bearer " <> token) when is_binary(token),
    do: tenant_from_token(token)

  defp tenant_from_auth_value("type=aad&ver=" <> rest) do
    case Enum.find(String.split(rest, "&"), &String.starts_with?(&1, "sig=")) do
      "sig=" <> token when token != "" -> tenant_from_token(token)
      _ -> :no_tenant
    end
  end

  defp tenant_from_auth_value(_other), do: :no_tenant

  # Unverified PAYLOAD read. Lawful because every production call path sits
  # downstream of Smalt.Auth.Bearer, which verified the JWS signature, exp,
  # aud and iss on the same conn in :enforce mode; in :anonymous mode (test
  # config) there is no verification anywhere and tenant extraction is
  # transport-asserted — the disclosed dev-mode face, same trust level as
  # anonymous mode itself.
  defp tenant_from_token(token) when is_binary(token) do
    case String.split(token, ".") do
      [_h, payload, _s] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"tid" => tid}} when is_binary(tid) and tid != "" -> {:ok, tid}
              _ -> :no_tenant
            end

          _ ->
            :no_tenant
        end

      _ ->
        :no_tenant
    end
  end
end
