defmodule Smalt.Identity.OidcIdp do
  @moduledoc """
  Entra-shaped OIDC IdP face for the identity plane (T05: discovery + token
  legs). Per tenant path segment it serves:

    - `GET /{tenant}/.well-known/openid-configuration` — OpenID discovery.
      Honest advertising: only endpoints that exist are listed;
      `authorization_endpoint` is advertised now that the /authorize leg
      has landed (T05 lane L18).
    - `GET /{tenant}/.well-known/oauth-authorization-server` — RFC 8414
      authorization-server metadata (same truthfulness law).
    - `GET /{tenant}/discovery/v2.0/keys` — JWKS from the dev cert.
    - `POST /{tenant}/oauth2/v2.0/token` — authorization-code grant with
      PKCE (S256 and plain) plus the refresh_token grant (rotating,
      reuse-detected; implemented in `Smalt.Identity.OidcAuthorize`). Codes
      are minted by /authorize; `Smalt.Identity.OidcCodeStore.insert/2`
      remains court-visible for direct seeding.

  Config: `:oidc_port` (default 9446), `:oidc_base_url`,
  `:oidc_cert_path` / `:oidc_key_path`, `:oidc_issuer_template`
  (default `"{base}/{tenant}/v2.0"`).
  """

  use Plug.Router

  @default_sub "smalt-user"
  @id_token_ttl 3600

  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :match
  plug :dispatch

  @doc "Issuer for a tenant, e.g. `http://127.0.0.1:9446/organizations/v2.0`."
  def issuer(tenant) do
    template = Application.get_env(:smalt, :oidc_issuer_template, "{base}/{tenant}/v2.0")

    template
    |> String.replace("{base}", base_url())
    |> String.replace("{tenant}", tenant)
  end

  @doc "Base URL advertised in discovery documents (scheme follows `:oidc_scheme`)."
  def base_url do
    case Application.get_env(:smalt, :oidc_base_url) do
      nil ->
        scheme = Application.get_env(:smalt, :oidc_scheme, :http)
        prefix = if scheme == :https, do: "https://", else: "http://"
        port = Application.get_env(:smalt, :oidc_port, 9446)
        ip = Smalt.Config.bind_ip() || {127, 0, 0, 1}
        prefix <> to_string(:inet.ntoa(ip)) <> ":" <> Integer.to_string(port)

      url ->
        url
    end
  end

  @doc "ID-token claims for a code record (courts and the later /authorize leg)."
  def id_token_claims(record, client_id) do
    now = System.system_time(:second)

    claims = %{
      "aud" => client_id,
      "iss" => issuer(record["tenant"] || "organizations"),
      "iat" => now,
      "nbf" => now,
      "exp" => now + @id_token_ttl,
      "sub" => record["sub"] || @default_sub,
      "oid" => record["sub"] || @default_sub,
      "name" => "Smalt User",
      "ver" => "2.0"
    }

    case record["nonce"] do
      nil -> claims
      nonce -> Map.put(claims, "nonce", nonce)
    end
  end

  # ------------------------------------------------------------------
  # Routes
  # ------------------------------------------------------------------

  get "/:tenant/.well-known/openid-configuration" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, discovery_document(tenant))
  end

  # Entra v2 shape: issuer {base}/{tenant}/v2.0 → discovery under the
  # issuer path (RFC 8414 §3.1 path insertion).
  get "/:tenant/v2.0/.well-known/openid-configuration" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, discovery_document(tenant))
  end

  get "/:tenant/.well-known/oauth-authorization-server" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, auth_server_metadata(tenant))
  end

  get "/:tenant/v2.0/.well-known/oauth-authorization-server" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, auth_server_metadata(tenant))
  end

  get "/:tenant/discovery/v2.0/keys" do
    case Smalt.Identity.OidcJwks.jwks() do
      {:ok, jwks} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(jwks))

      {:error, reason} ->
        send_json_error(conn, 500, "server_error", inspect(reason))
    end
  end

  post "/:tenant/oauth2/v2.0/token" do
    handle_token(conn)
  end

  # T05 lane L18: the authorize + consent leg lives in OidcAuthorize, mounted
  # here as two disclosed one-line delegations so the issuer stays one origin
  # (discovery/token/authorize on one port). Disclosed in r-t05a + r-t05b.
  get "/:tenant/authorize", do: Smalt.Identity.OidcAuthorize.get_authorize(conn)

  post "/:tenant/authorize", do: Smalt.Identity.OidcAuthorize.post_consent(conn)

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ------------------------------------------------------------------
  # Child spec (Bandit plug server) — mirrors SamlIdp.child_spec/1
  # ------------------------------------------------------------------

  @doc false
  def child_spec(opts) when is_list(opts) do
    port = Keyword.get(opts, :port, Application.get_env(:smalt, :oidc_port, 9446))
    scheme = Application.get_env(:smalt, :oidc_scheme, :http)

    bandit_opts =
      [
        plug: {__MODULE__, []},
        scheme: scheme,
        port: port,
        ip: bind_ip()
      ]

    bandit_opts =
      if scheme == :https do
        cert = Application.get_env(:smalt, :oidc_cert_path, ".smalt/tls/dev-cert.pem")
        key = Application.get_env(:smalt, :oidc_key_path, ".smalt/tls/dev-key.pem")

        bandit_opts
        |> Keyword.put(:certfile, cert)
        |> Keyword.put(:keyfile, key)
      else
        bandit_opts
      end

    %{
      id: {__MODULE__, port},
      start: {Bandit, :start_link, [bandit_opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 10_000
    }
  end

  # The bind_ip law (Smalt.Identity.SamlIdp.bind_ip/0 precedent,
  # KIND-E2E r13 item 3: a raw SMALT_BIND_IP string passed to Bandit is
  # :badarg at boot): nil/"loopback" -> loopback, binary ->
  # :inet.parse_address fail-closed, tuple -> itself.
  # Compile-freeze unblock (lane verification, disclosed 2026-10-30): the
  # identity-plane listener crashed the whole app in kind (witnessed
  # smalt-backend-0 OidcIdp 9446 listener :badarg) because SMALT_BIND_IP is
  # set to 0.0.0.0 for the ARM NodePort; minimal fix mirrors SamlIdp.
  @spec bind_ip() :: :inet.ip_address()
  defp bind_ip do
    case Smalt.Config.bind_ip() do
      nil -> {127, 0, 0, 1}
      "loopback" -> {127, 0, 0, 1}

      str when is_binary(str) ->
        case :inet.parse_address(String.to_charlist(str)) do
          {:ok, ip} -> ip
          {:error, _} -> raise ArgumentError, "SMALT_BIND_IP=#{str} is not a valid IPv4/IPv6 address"
        end

      ip when is_tuple(ip) ->
        ip
    end
  end

  # ------------------------------------------------------------------
  # Token leg
  # ------------------------------------------------------------------

  # T05 lane L18: refresh_token grant is implemented in OidcAuthorize and
  # delegated here so the token endpoint stays the single token surface.
  # Disclosed in r-t05a + r-t05b.
  defp handle_token(conn) do
    case conn.body_params["grant_type"] do
      "refresh_token" -> Smalt.Identity.OidcAuthorize.refresh_grant(conn)
      _ -> handle_code_grant(conn)
    end
  end

  defp handle_code_grant(conn) do
    params = conn.body_params

    with {:ok, code} <- required(params, "code"),
         {:ok, record} <- store_take(code),
         :ok <- check_client_id(record, params["client_id"]),
         :ok <- check_grant_type(params["grant_type"]),
         :ok <- check_redirect_uri(record, params["redirect_uri"]),
         :ok <- check_pkce(record, params["code_verifier"]) do
      client_id = params["client_id"] || record["client_id"]
      id_token = mint_id_token(id_token_claims(record, client_id))
      refresh_token = Smalt.Identity.OidcAuthorize.mint_refresh_token(record, client_id)
      body = token_response(id_token, refresh_token)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      {:error, {status, code, desc}} ->
        send_json_error(conn, status, code, desc)
    end
  end

  defp store_take(code) do
    case Smalt.Identity.OidcCodeStore.take(code) do
      {:ok, record} -> {:ok, record}

      {:error, _reason} ->
        {:error, {400, "invalid_grant", "code not found or already redeemed"}}
    end
  end

  defp check_client_id(record, client_id) do
    if is_binary(client_id) and record["client_id"] != nil and record["client_id"] != client_id do
      {:error, {400, "invalid_client", "client_id mismatch"}}
    else
      :ok
    end
  end

  defp check_grant_type("authorization_code"), do: :ok

  defp check_grant_type(_) do
    {:error, {400, "unsupported_grant_type", "only authorization_code is supported"}}
  end

  defp check_redirect_uri(record, redirect_uri) do
    stored = record["redirect_uri"]

    if is_binary(stored) and stored != "" and redirect_uri != stored do
      {:error, {400, "invalid_grant", "redirect_uri mismatch"}}
    else
      :ok
    end
  end

  defp check_pkce(record, verifier) do
    case record["code_challenge"] do
      challenge when is_binary(challenge) and challenge != "" ->
        verify_verifier(record, challenge, verifier)

      _ ->
        :ok
    end
  end

  defp verify_verifier(record, challenge, verifier) do
    cond do
      is_binary(verifier) and record["code_challenge_method"] == "S256" ->
        digest =
          :crypto.hash(:sha256, verifier)
          |> Base.url_encode64(padding: false)

        if Plug.Crypto.secure_compare(digest, challenge) do
          :ok
        else
          {:error, {400, "invalid_grant", "PKCE S256 verification failed"}}
        end

      is_binary(verifier) and record["code_challenge_method"] == "plain" ->
        if Plug.Crypto.secure_compare(verifier, challenge) do
          :ok
        else
          {:error, {400, "invalid_grant", "PKCE plain verification failed"}}
        end

      true ->
        {:error, {400, "invalid_request", "code_verifier required for this code"}}
    end
  end

  defp required(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {400, "invalid_request", "missing parameter: " <> key}}
    end
  end

  # ------------------------------------------------------------------
  # Metadata documents
  # ------------------------------------------------------------------

  defp discovery_document(tenant) do
    base = base_url()
    tenant_prefix = base <> "/" <> tenant

    doc = %{
      "issuer" => issuer(tenant),
      "authorization_endpoint" => tenant_prefix <> "/authorize",
      "token_endpoint" => tenant_prefix <> "/oauth2/v2.0/token",
      "jwks_uri" => tenant_prefix <> "/discovery/v2.0/keys",
      "id_token_signing_alg_values_supported" => ["RS256"],
      "subject_types_supported" => ["pairwise"],
      "response_types_supported" => ["code"],
      "response_modes_supported" => ["query"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256", "plain"],
      "scopes_supported" => ["openid", "profile", "email"],
      "claims_supported" => ["aud", "exp", "iat", "iss", "sub"]
    }

    Jason.encode!(doc)
  end

  defp auth_server_metadata(tenant) do
    base = base_url()
    tenant_prefix = base <> "/" <> tenant

    Jason.encode!(%{
      "issuer" => issuer(tenant),
      "authorization_endpoint" => tenant_prefix <> "/authorize",
      "token_endpoint" => tenant_prefix <> "/oauth2/v2.0/token",
      "jwks_uri" => tenant_prefix <> "/discovery/v2.0/keys",
      "token_endpoint_auth_methods_supported" => ["none", "client_secret_post"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "response_types_supported" => ["code"],
      "code_challenge_methods_supported" => ["S256", "plain"],
      "scopes_supported" => ["openid", "profile", "email"]
    })
  end

  defp token_response(id_token, refresh_token) do
    Jason.encode!(%{
      "token_type" => "Bearer",
      "scope" => "openid profile email",
      "expires_in" => 3600,
      "ext_expires_in" => 3600,
      "access_token" => "smalt-at-" <> random_token(),
      "refresh_token" => refresh_token,
      "refresh_token_expires_in" => 86_400,
      "id_token" => id_token
    })
  end

  # ------------------------------------------------------------------
  # ID token minting (RS256 via the dev key, kid in header)
  # ------------------------------------------------------------------

  defp mint_id_token(claims) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => current_kid()}
    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signature = Smalt.Identity.OidcJwks.sign(signing_input)
    signing_input <> "." <> b64(signature)
  end

  defp current_kid do
    case Smalt.Identity.OidcJwks.jwk() do
      {:ok, %{"kid" => kid}} -> kid
      _ -> "smalt-dev"
    end
  end

  defp send_json_error(conn, status, code, desc) do
    body =
      Jason.encode!(%{"error" => code, "error_description" => desc})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp b64(bin), do: Smalt.Identity.OidcJwks.b64url(bin)

  defp random_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
