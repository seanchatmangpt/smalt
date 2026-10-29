defmodule Smalt.Auth.Imds do
  @moduledoc """
  Azure IMDS / managed-identity token face (wave-6 lane w6r).

  GET /metadata/identity/oauth2/token?api-version=2018-02-01&resource=<aud>
  with `Metadata: true` — the shape @azure/identity ManagedIdentityCredential
  sends. Also admits the App Service variant (api-version=2019-08-01,
  X-IDENTITY-HEADER present). Unknown api-version, missing identity header,
  and missing `resource` are typed 400s. `resource` value is tolerated and
  becomes the minted token audience. Bootstrap-exempt in Bearer (disclosed
  additive change). Mint reuses Smalt.Auth.StsKey - no duplicated crypto.

  Config `:smalt, :imds`: `:client_id` (default
  "00000000-0000-0000-0000-000000000002"), `:identity_header_secret`
  (X-IDENTITY-HEADER must match when set; any non-empty admits when unset).
  """

  @default_client_id "00000000-0000-0000-0000-000000000002"
  @known_api_versions ["2018-02-01", "2019-08-01"]

  import Plug.Conn

  @doc """
  GET /metadata/identity/oauth2/token handler (leaf route in
  Smalt.ArmGateway.Router). Sends the response, returns the conn.
  """
  @spec handle_token(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_token(conn) do
    cond do
      conn.query_params["api-version"] not in @known_api_versions ->
        imds_error(conn, "invalid api-version (known: 2018-02-01 | 2019-08-01)")

      not identity_admitted?(conn) ->
        imds_error(conn, "Metadata header required")

      blank?(conn.query_params["resource"]) ->
        imds_error(conn, "resource query parameter required")

      true ->
        respond(conn)
    end
  end

  # -- admission -----------------------------------------------------------------

  defp identity_admitted?(conn) do
    metadata? = header_true?(get_req_header(conn, "metadata"))
    metadata? or x_identity_admitted?(get_req_header(conn, "x-identity-header"))
  end

  defp header_true?([v | _]), do: String.downcase(String.trim(v)) == "true"
  defp header_true?([]), do: false

  defp x_identity_admitted?([v | _]) when v != "" do
    case Application.get_env(:smalt, :imds, [])[:identity_header_secret] do
      secret when is_binary(secret) and secret != "" ->
        Plug.Crypto.secure_compare(v, secret)

      _ ->
        true
    end
  end

  defp x_identity_admitted?(_), do: false

  # -- mint + response -----------------------------------------------------------

  defp respond(conn) do
    now = System.system_time(:second)
    ttl = Keyword.get(Smalt.Config.sts(), :token_ttl_seconds, 3600)
    resource = conn.query_params["resource"]
    client_id = client_id()

    # Sibling-seat acceptance: same trusted-authority registration the tenant
    # STS does at mint time, so the MI token verifies on data-plane endpoints
    # too (server-side membership at mint, never client-asserted).
    authority = Smalt.Auth.Bearer.request_authority(conn)
    Smalt.Auth.Bearer.register_trusted_authority(authority)

    claims = %{
      "aud" => resource,
      "iss" => "#{authority}/smalt-imds/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => now + ttl,
      "appid" => client_id,
      "azp" => client_id,
      "oid" => "00000000-0000-0000-0000-000000000003",
      "sub" => "00000000-0000-0000-0000-000000000003",
      "tid" => "smalt",
      "roles" => ["Contributor", "Owner"]
    }

    {:ok, token} = Smalt.Auth.StsKey.mint(claims)

    # Wire parity with real IMDS: the seconds fields are STRINGS on the wire.
    body =
      Jason.encode!(%{
        "access_token" => token,
        "client_id" => client_id,
        "expires_in" => Integer.to_string(ttl),
        "expires_on" => Integer.to_string(now + ttl),
        "ext_expires_in" => Integer.to_string(ttl),
        "not_before" => Integer.to_string(now),
        "resource" => resource
      })

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp client_id do
    case Application.get_env(:smalt, :imds, [])[:client_id] do
      cid when is_binary(cid) and cid != "" -> cid
      _ -> @default_client_id
    end
  end

  defp imds_error(conn, msg) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => "invalid_request", "error_description" => msg}))
  end

  defp blank?(v), do: not is_binary(v) or v == ""
end
