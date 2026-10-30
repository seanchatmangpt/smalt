defmodule Smalt.Identity.AcaIdentity do
  @moduledoc """
  Azure Container Apps managed-identity token surface (lane S3, r16; task b,
  census R10-adjacent): the `IDENTITY_ENDPOINT` (`:17001` identity proxy)
  shape ACA injects into every container, so a workload obtains Entra tokens
  from smalt exactly the way @azure/identity `ManagedIdentityCredential` asks
  for them.

  Two wire forms served by the same handler:

    * `GET /?api-version=2019-08-01&resource=<aud>` with header
      `x-identity-header: <IDENTITY_HEADER>` - the ACA / App Service
      2019-08-01 MSI shape (env: IDENTITY_ENDPOINT/IDENTITY_HEADER).
    * `GET /metadata/identity/oauth2/token?api-version=2018-02-01&resource=<aud>`
      with header `Metadata: true` - the IMDS shape (same mint).

  Unknown api-version and missing identity proof are typed 400s (the
  `Smalt.Auth.Imds` admission law). The mint is `Smalt.Auth.StsKey`
  RS256-first with Entra-realistic managed-identity claims (tid = the Entra
  tenant GUID from `Smalt.Identity.EntraClaims`, xms_mirid, string
  expires_on - the real MSI wire shape). Config `config :smalt,
  :aca_identity, ...`: `:identity_header_secret` (exact-match when set; any
  non-empty header admits when unset - the Imds disclosed divergence),
  `:client_id`, `:mi_resource_id`. Port: `config :smalt, :aca_identity_port`
  (default 17001).

  Mounting note (r16): the face is child_spec-ready (Bandit, contained
  port bind NOT yet required - see child_spec/1) but is NOT yet in the
  application supervision tree; courts boot it directly. The one-line
  application.ex child add is the disclosed integration follow-up.
  """

  use Plug.Router

  import Plug.Conn

  alias Smalt.Identity.EntraClaims

  @default_client_id "00000000-0000-0000-0000-000000000004"
  @known_api_versions ["2018-02-01", "2019-08-01"]
  @default_ttl 3600

  plug :fetch_query_params
  plug :match
  plug :dispatch

  get "/" do
    handle_token(conn)
  end

  get "/metadata/identity/oauth2/token" do
    handle_token(conn)
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not_found"}))
  end

  # ------------------------------------------------------------------
  # Child spec (Bandit plug server)
  # ------------------------------------------------------------------

  @doc false
  def child_spec(opts) when is_list(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:smalt, :aca_identity_port, 17_001))

    %{
      id: {__MODULE__, port},
      start:
        {Bandit, :start_link,
         [
           [
             plug: {__MODULE__, []},
             scheme: :http,
             port: port,
             ip: Smalt.Config.bind_ip() || {127, 0, 0, 1}
           ]
         ]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  # ------------------------------------------------------------------
  # Token handler (both wire forms)
  # ------------------------------------------------------------------

  def handle_token(conn) do
    cond do
      conn.query_params["api-version"] not in @known_api_versions ->
        msi_error(conn, "invalid api-version (known: 2018-02-01 | 2019-08-01)")

      not identity_admitted?(conn) ->
        msi_error(conn, "x-identity-header required")

      blank?(conn.query_params["resource"]) ->
        msi_error(conn, "resource query parameter required")

      true ->
        respond(conn)
    end
  end

  defp identity_admitted?(conn) do
    identity_header_admitted?(get_req_header(conn, "x-identity-header")) or
      metadata_header_admitted?(get_req_header(conn, "metadata"))
  end

  defp identity_header_admitted?([v | _]) when v != "" do
    case Application.get_env(:smalt, :aca_identity, [])[:identity_header_secret] do
      secret when is_binary(secret) and secret != "" ->
        Plug.Crypto.secure_compare(v, secret)

      _ ->
        true
    end
  end

  defp identity_header_admitted?(_), do: false

  defp metadata_header_admitted?([v | _]), do: String.downcase(String.trim(v)) == "true"
  defp metadata_header_admitted?([]), do: false

  # ------------------------------------------------------------------
  # Mint + response (real MSI wire shape: epoch fields are STRINGS)
  # ------------------------------------------------------------------

  @doc "Mints the managed-identity access token map for `resource` (public for courts)."
  def mint_token(resource, now \\ System.system_time(:second)) do
    ttl = Application.get_env(:smalt, :aca_identity, []) |> Keyword.get(:token_ttl_seconds, @default_ttl)
    claims = identity_claims(resource, now, ttl)
    {:ok, token} = Smalt.Auth.StsKey.mint(claims)
    %{token: token, claims: claims, ttl: ttl, now: now}
  end

  defp identity_claims(resource, now, ttl) do
    entra = EntraClaims.resolve()
    client_id = client_id()

    %{
      "aud" => resource,
      "iss" => "https://sts.windows.net/#{entra.tenant_id}/",
      "iat" => now,
      "nbf" => now,
      "exp" => now + ttl,
      "appid" => client_id,
      "azp" => client_id,
      "oid" => object_id(),
      "sub" => object_id(),
      "tid" => entra.tenant_id,
      "uti" => Base.encode32(:crypto.strong_rand_bytes(10), padding: false),
      "xms_mirid" => mi_resource_id(),
      "idtyp" => "app"
    }
  end

  defp respond(conn) do
    resource = conn.query_params["resource"]
    minted = mint_token(resource)
    client_id = client_id()

    body =
      Jason.encode!(%{
        "access_token" => minted.token,
        "token_type" => "Bearer",
        "expires_in" => Integer.to_string(minted.ttl),
        "expires_on" => Integer.to_string(minted.now + minted.ttl),
        "ext_expires_in" => Integer.to_string(minted.ttl),
        "not_before" => Integer.to_string(minted.now),
        "resource" => resource,
        "client_id" => client_id
      })

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp client_id do
    case Application.get_env(:smalt, :aca_identity, [])[:client_id] do
      cid when is_binary(cid) and cid != "" -> cid
      _ -> @default_client_id
    end
  end

  defp object_id do
    case Application.get_env(:smalt, :aca_identity, [])[:object_id] do
      oid when is_binary(oid) and oid != "" -> oid
      _ -> "33333333-3333-4333-8333-333333333301"
    end
  end

  defp mi_resource_id do
    case Application.get_env(:smalt, :aca_identity, [])[:mi_resource_id] do
      rid when is_binary(rid) and rid != "" -> rid
      _ ->
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/courtroom-rg/" <>
          "providers/Microsoft.ManagedIdentity/userAssignedIdentities/smalt-mi"
    end
  end

  defp msi_error(conn, msg) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => "invalid_request", "error_description" => msg}))
  end

  defp blank?(v), do: not is_binary(v) or v == ""
end
