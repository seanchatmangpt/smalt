
defmodule Smalt.ArmGateway.Plug.OidcSts do
  @moduledoc """
  Route-family plug (T06, v26.10.29): STS/OAuth2 token issuance + OIDC discovery faces.

  Pass-through dispatch: routes were extracted verbatim from the monolithic
  router; a conn no route claims returns UNCHANGED (not halted) via the
  trailing pass-through match, so the front pipeline composes unchanged.
  """
  import Smalt.ArmGateway.Plug.Common


  use Plug.Router
  require Logger
  plug(:match)
  plug(:dispatch)

  # T06 dispatch law: a family route that ANSWERED (state :sent) must halt, or
  # the front pipeline would keep piping and the front catch-all would
  # re-dispatch on a sent conn (Plug.Conn.AlreadySentError). Answered conns
  # halt here; unclaimed conns (state :unset) pass through untouched.
  def call(conn, opts) do
    case super(conn, opts) do
      %Plug.Conn{state: :sent, halted: false} = c -> halt(c)
      c -> c
    end
  end


  defp handle_token(conn, tenant_id) do
    # AZB-15 identity-plane DR gate: when the identity subtree booted in this
    # VM and was then killed, NEW mints answer a typed 503 (retryable). A
    # control-only boot (split profile / wire tree, no identity plane) keeps
    # minting — the marker is set only by StsGate.init in a booted identity
    # subtree.
    if Smalt.Plane.Identity.StsGate.mint_allowed?() do
      case validate_token_request(conn) do
        :ok ->
          issue_token(conn, tenant_id)

        {:error, code} ->
          token_error(conn, code)
      end
    else
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "StsUnavailable"}))
      |> halt()
    end
  end

  # RFC 6749 §5.2 error responses; §5.1 requires Cache-Control: no-store +
  # Pragma: no-cache on ALL token endpoint responses (success AND error).

  # RFC 6749 §5.2 error responses; §5.1 requires Cache-Control: no-store +
  # Pragma: no-cache on ALL token endpoint responses (success AND error).
  defp token_error(conn, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => code}))
  end

  # RFC 6749 §5.2 request validation:
  # - unparseable/missing grant_type -> invalid_request
  # - wrong grant_type              -> unsupported_grant_type
  # - missing client_id/secret      -> invalid_client

  # RFC 6749 §5.2 request validation:
  # - unparseable/missing grant_type -> invalid_request
  # - wrong grant_type              -> unsupported_grant_type
  # - missing client_id/secret      -> invalid_client
  defp validate_token_request(conn) do
    params = conn.body_params

    # Duplicate form parameters are refused (OAuth 2.1 draft security
    # considerations / AAD parity): Plug's last-wins decoding would let a
    # later client-controlled key overwrite an earlier fixed one. Detected
    # on the RAW body via the BodyCache reader, not the decoded map.
    dup? =
      case conn.private[:smalt_raw_body] do
        body when is_binary(body) ->
          # Exact-key duplicate detection on &-separated pairs: substring
          # neighbors (e.g. xgrant_type=) must NOT false-positive.
          body
          |> String.split("&")
          |> Enum.count(fn
            "grant_type=" <> _ -> true
            "grant_type" -> true
            _ -> false
          end) > 1

        _ ->
          false
      end

    cond do
      dup? ->
        {:error, "invalid_request"}

      not is_map(params) or not is_binary(params["grant_type"]) or params["grant_type"] == "" ->
        {:error, "invalid_request"}

      params["grant_type"] != "client_credentials" ->
        {:error, "unsupported_grant_type"}

      blank?(params["client_id"]) or blank?(params["client_secret"]) ->
        {:error, "invalid_client"}

      true ->
        :ok
    end
  end


  defp blank?(v), do: not is_binary(v) or v == ""


  defp issue_token(conn, tenant_id) do
    now = System.system_time(:second)

    # AZB-08 config read site: the identity-plane profile
    # `config :smalt, :sts, token_ttl_seconds: 3600` names the mint TTL.
    # Default 3600 keeps the pinned STS mint contract (exp - iat == 3600,
    # expires_in == 3600) byte-identical on a plain `:all` boot.
    ttl = Keyword.get(Smalt.Config.sts(), :token_ttl_seconds, 3600)

    # Cross-seat issuer acceptance (F4 v3 finding 1): record the authority the
    # token is minted under so sibling seats (Cosmos :8443, blob, kv) accept
    # it. Server-side only — membership is added at mint time, never from
    # client-asserted claims, so the check stays tamper-resistant.
    authority = mint_authority(conn)
    Smalt.Auth.Bearer.register_trusted_authority(authority)

    # OIDC Discovery: the token iss must EXACTLY equal the discovery issuer for
    # the same request authority — both derive from request_authority/1.
    claims = %{
      "aud" => "https://management.azure.com",
      "iss" => "#{authority}/#{tenant_id}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => now + ttl,
      "appid" => "00000000-0000-0000-0000-000000000000",
      "azp" => "00000000-0000-0000-0000-000000000000",
      "oid" => "00000000-0000-0000-0000-000000000001",
      "sub" => "00000000-0000-0000-0000-000000000001",
      "tid" => tenant_id,
      "roles" => ["Contributor", "Owner"]
    }

    # Mint via the mode's key: RS256 emits {"typ":"JWT","alg":"RS256",
    # "kid":<thumbprint>} (JOSE-direct — Joken's JWS.compact strips custom JWS
    # header members); :hs256_dev stays on the legacy Joken path, wire
    # byte-identical to pre-StsKey.
    {:ok, token} = Smalt.Auth.StsKey.mint(claims)

    # AF-L14-GAP-1 closure: every successful mint feeds the sign-in logs ring
    # (GET /v1.0/auditLogs/signIns). Recording failure never fails the mint.
    Smalt.Egress.SignIns.record_mint(tenant_id, claims["appid"], conn)

    body =
      Jason.encode!(%{
        "token_type" => "Bearer",
        "expires_in" => ttl,
        "ext_expires_in" => ttl,
        "scope" => "https://management.azure.com/.default",
        "access_token" => token
      })

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_json(200, body)
  end

  # STS signing key: RS256 via Smalt.Auth.StsKey (env-PEM-first precedence,
  # :global-locked once-per-VM generation, :persistent_term-cached with the
  # mode stamped). The legacy HS256 secret logic moved into
  # Smalt.Auth.StsKey.hs_signer/0 / generate_and_cache_dev_secret/0.

  # Lane R9 (JWT issuer configurability): when `config :smalt, :issuer_host`
  # is set, the STS mint + OIDC discovery authority is `https://<issuer_host>`
  # instead of the request-derived loopback authority. Default (nil) is
  # byte-identical to the legacy mint. The configured authority is registered
  # as a trusted mint authority so tokens still verify on every seat via the
  # existing cross-seat leg (JWKS/kid binding untouched).

  # STS signing key: RS256 via Smalt.Auth.StsKey (env-PEM-first precedence,
  # :global-locked once-per-VM generation, :persistent_term-cached with the
  # mode stamped). The legacy HS256 secret logic moved into
  # Smalt.Auth.StsKey.hs_signer/0 / generate_and_cache_dev_secret/0.

  # Lane R9 (JWT issuer configurability): when `config :smalt, :issuer_host`
  # is set, the STS mint + OIDC discovery authority is `https://<issuer_host>`
  # instead of the request-derived loopback authority. Default (nil) is
  # byte-identical to the legacy mint. The configured authority is registered
  # as a trusted mint authority so tokens still verify on every seat via the
  # existing cross-seat leg (JWKS/kid binding untouched).
  defp mint_authority(conn) do
    case Smalt.Config.issuer_host() do
      nil ->
        request_authority(conn)

      host when is_binary(host) ->
        authority = issuer_host_authority!(host)
        Smalt.Auth.Bearer.register_trusted_authority(authority)
        authority
    end
  end

  # Fail-closed validation: bare host or full HTTPS URL with NO path. The
  # issuer must stay a well-formed HTTPS-shape URL string; anything else
  # (http scheme, embedded path, empty) refuses the mint with ArgumentError.

  # Fail-closed validation: bare host or full HTTPS URL with NO path. The
  # issuer must stay a well-formed HTTPS-shape URL string; anything else
  # (http scheme, embedded path, empty) refuses the mint with ArgumentError.
  defp issuer_host_authority!(host) do
    cond do
      not String.contains?(host, "://") ->
        case String.trim_trailing(host, "/") do
          "" -> raise ArgumentError, "smalt :issuer_host must be a non-empty host or HTTPS URL"
          trimmed -> "https://#{trimmed}"
        end

      true ->
        case URI.parse(host) do
          %URI{scheme: "https", host: h, path: p} when is_binary(h) and p in [nil, ""] ->
            String.trim_trailing(host, "/")

          _ ->
            raise ArgumentError,
                  "smalt :issuer_host must be a bare host or an HTTPS URL with no path " <>
                    "(got #{inspect(host)})"
        end
    end
  end

  # Request-derived authority: scheme://host[:port] as the CLIENT reached us
  # (lane 90 TS court: advertising login.smalt.local — an NXDOMAIN — made
  # msal-node/azidentity follow the envelope and never reach the substrate
  # STS: endpoints_resolution_error). Single derivation shared with the auth
  # plug: forwarded headers honored ONLY from trusted proxies (fail-closed).

  # "https://arm.internal:19081" -> "arm.internal" (scheme + port stripped):
  # the instance-discovery alias for THIS substrate's authority.
  defp instance_alias_host(base) do
    case String.split(base, "://", parts: 2) do
      [_scheme, rest] -> hd(String.split(rest, ":", parts: 2))
      _ -> base
    end
  end


  defp openid_envelope(conn, tenant_id) do
    base = "#{mint_authority(conn)}/#{tenant_id}"

    %{
      "issuer" => "#{base}/v2.0",
      "token_endpoint" => "#{base}/oauth2/v2.0/token",
      "authorization_endpoint" => "#{base}/oauth2/v2.0/authorize",
      "jwks_uri" => "#{base}/discovery/v2.0/keys",
      # Mode-conditional: AAD advertises ["RS256"]; the HS256 dev pin
      # advertises what it actually uses (self-consistent with the mint).
      "id_token_signing_alg_values_supported" =>
        case Smalt.Auth.StsKey.mode() do
          :rs256 -> ["RS256"]
          :hs256_dev -> ["HS256"]
        end,
      # OIDC Discovery 3.0 REQUIRED members.
      "response_types_supported" => ["token"],
      "subject_types_supported" => ["public"]
    }
  end

  # C1-TENANT closure (divergence lane D2): the STS mints tokens for ARBITRARY
  # tenants (/:tenant_id/oauth2/v2.0/token), so /tenants must reflect what the
  # identity plane actually minted, not only the home tenant. Registry = the
  # sign-ins mint ring (Smalt.Egress.SignIns): every successful token-endpoint
  # mint already records its tenant there, so /tenants renders home + every
  # distinct minted tenant. Documented ARM TenantListResult shape
  # (learn.microsoft.com/rest/api/resources/tenants/list): id is the
  # "/tenants/{tenantId}" URI, tenantCategory "Home" on the home row only.
  # Routes (first-match-wins: deeper/collection routes precede shallower ones)
  # ===========================================================================

  # -- STS / OAuth2 Token Issuance --------------------------------------------
  post "/oauth2/v2.0/token" do
    handle_token(conn, "00000000-0000-0000-0000-000000000000")
  end

  post "/:tenant_id/oauth2/v2.0/token" do
    handle_token(conn, tenant_id)
  end

  # -- IMDS / managed identity (w6r) -------------------------------------------
  get "/common/discovery/instance" do
    tid = "00000000-0000-0000-0000-000000000000"
    base = request_authority(conn)

    body =
      Jason.encode!(%{
        "tenantId" => tid,
        "name" => "smalt-sovereign",
        "authorization_endpoint" => "#{base}/#{tid}/oauth2/v2.0/authorize",
        "token_endpoint" => "#{base}/#{tid}/oauth2/v2.0/token",
        "issuer" => "#{base}/#{tid}/v2.0",
        "tenant_discovery_endpoint" => "#{base}/#{tid}/v2.0/.well-known/openid-configuration",
        # msal instance discovery (the envelope that unblocks
        # ClientSecretCredential): AAD-shape metadata array. Each entry MUST
        # carry tenant_discovery_endpoint (msal-common's
        # CloudInstanceDiscoveryResponse validates it per-entry — a flat
        # top-level one alone answers invalid_instance). The request
        # authority's HOST (scheme+port stripped) rides the aliases so the
        # emulator's own authority is admitted as an instance alias.
        "metadata" => [
          %{
            "preferred_network" => "login.microsoftonline.com",
            "preferred_cache" => "login.windows.net",
            "aliases" =>
              ["login.microsoftonline.com", "login.windows.net", "login.microsoft.com"] ++
                [instance_alias_host(base)],
            "tenant_discovery_endpoint" => "#{base}/#{tid}/v2.0/.well-known/openid-configuration"
          }
        ]
      })

    send_json(conn, 200, body)
  end

  get "/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, "organizations")))
  end

  get "/:tenant_id/v2.0/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, tenant_id)))
  end

  # JWKS endpoint: under :rs256 the STS public key is published (kty/n/e/use/
  # alg/kid); under :hs256_dev the shared secret is never published, so the
  # key set stays honestly empty (an OIDC-compliant doc must not advertise a
  # jwks_uri that 404s).
  get "/:tenant_id/discovery/v2.0/keys" do
    keys =
      case Smalt.Auth.StsKey.mode() do
        :rs256 -> [Smalt.Auth.StsKey.jwk_map()]
        :hs256_dev -> []
      end

    send_json(conn, 200, Jason.encode!(%{"keys" => keys}))
  end


  # Pass-through tail (T06): a conn no route above claimed returns UNCHANGED
  # (not halted) so the next plug in the front pipeline complies unchanged.
  match _ do
    conn
  end
end
