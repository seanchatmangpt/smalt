defmodule Smalt.Auth.Bearer do
  @moduledoc """
  Bearer-token verification plug (S4 defect fix: 8x P1 — no plug verified
  Authorization anywhere; anonymous ARM/Cosmos/Blob returned 200/201 and
  exp/sig/aud/iss/cross-secret were ignored).

  `call/2` behaviour is driven by `Application.get_env(:smalt, :auth_mode)`:

  - `:enforce` (default) — every non-exempt route requires a valid Bearer
    token: HS256 signature verified with `Application.get_env(:smalt,
    :sts_signing_secret)` — the SAME secret the ARM STS signs with (when the
    env is unset, the ARM gateway's generated dev secret cached in
    `:persistent_term` is used, so dev mode stays self-consistent) — plus
    `exp > now`, `aud` in `:smalt, :token_audiences`, and `iss` prefix
    `https://login.microsoftonline.com/`.
  - `:anonymous` — explicit opt-out (config/test.exs sets it so the existing
    suite stays green); the plug passes through.

  Exempt paths (bootstrap/discovery, before any token can exist):
  `/oauth2/*`, `/.well-known/*`, `/metadata/endpoints`, `/common/discovery/*`,
  `/tenant(s)`, `/attest/*` (MAA is its own auth).

  On failure: 401 with an ARM error envelope and
  `WWW-Authenticate: Bearer error="invalid_token"`.
  """

  @behaviour Plug
  import Plug.Conn

  @default_audiences ["https://management.azure.com"]
  @iss_prefix "https://login.microsoftonline.com/"
  @exempt_prefixes ["/oauth2/", "/.well-known/", "/common/discovery/", "/attest/"]
  @exempt_exact ["/metadata/endpoints", "/tenant", "/tenants"]

  @doc """
  Records `authority` (e.g. `"https://arm.internal:19081"`) as an issuer
  authority this substrate has actually minted tokens for. Called by the ARM
  gateway at token-mint time, so a token minted on one seat/port is still
  valid on a sibling seat (e.g. Cosmos on :8443) WITHOUT loosening the
  contract to accept client-asserted issuers: membership can only be added by
  the server-side mint path, after signature verification has already bound
  the token to this substrate's signing secret.

  Concurrency (lens-2 cycle 1): one `:persistent_term` key PER authority.
  The previous single-MapSet read-modify-write lost updates under concurrent
  mints (50-parallel court): two mints could both read the old set and each
  write back a set missing the other's authority. `:persistent_term.put/2`
  is atomic per key and distinct authorities use distinct keys, so there is
  no read-modify-write window. Reads (`minted_authority?/1`) stay lock-free.

  Retention contract (lens-3 cycle 1, corrected from the lens-2 "a handful"
  claim — measured 1000/1000 keys under a 1000-distinct-authority stress):
  keys accumulate per DISTINCT mint-time request authority and never shrink
  for the life of the VM. The mint-time request authority is the CLIENT
  route to us — under a trusted proxy, `x-forwarded-host` is client-supplied,
  so distinct-authority count is attacker-INFLUENCEABLE up to the cap below.
  `@max_trusted_authorities` bounds the set: registration past the cap is a
  no-op (the mint still succeeds and the token still verifies at its OWN
  seat via the request-authority leg; only cross-SEAT acceptance of the
  capped-out authority is withheld). It is NOT per-tenant or per-token:
  tenant ids live in the iss PATH below the authority and do not create keys.
  """
  @max_trusted_authorities 1024

  def register_trusted_authority(authority) when is_binary(authority) do
    key = {__MODULE__, :trusted, issuer_authority(authority)}

    # lens-4 cycle 2 fence: a scheme-less authority collapses to "" in
    # issuer_authority/1 — registering under "" would let ANY scheme-less iss
    # ride the registry leg from ANY seat (fail-open). "" is never a registry
    # key: scheme-less registration is a no-op and the verify-side lookup
    # below never matches "".
    if elem(key, 2) == "" do
      :ok
    else
      if :persistent_term.get(key, false) do
        :ok
      else
        # Soft cap (lens-3 fence): the count is re-read per NEW authority, so
        # concurrent new authorities can overshoot the cap by the concurrency
        # width — a bounded overshoot is accepted; the fence kills unbounded
        # growth, not last-key exactness.
        if trusted_authority_count() < @max_trusted_authorities do
          :persistent_term.put(key, true)
        else
          :ok
        end
      end
    end
  end

  defp trusted_authority_count do
    :persistent_term.get()
    |> Enum.count(fn
      {{__MODULE__, :trusted, _}, true} -> true
      _ -> false
    end)
  end

  @doc """
  Erases every recorded mint authority. The mechanical surface of the restart
  contract (restart => re-authentication): a fresh VM starts empty; tests use
  this to simulate the restart boundary. Not called by any request path.
  """
  def reset_trusted_authorities! do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, :trusted, authority}, true} ->
        :persistent_term.erase({__MODULE__, :trusted, authority})

      _other_key ->
        :ok
    end)

    :ok
  end

  @doc """
  Request authority (`scheme://host[:port]`) as the CLIENT reached us — the
  single derivation shared by the auth plug and the ARM gateway (STS mint,
  discovery envelope).

  Forwarded headers (`x-forwarded-proto`/`x-forwarded-host`) are honored ONLY
  when the direct peer is a configured trusted proxy
  (`Application.get_env(:smalt, :trusted_proxies)` — exact `{a,b,c,d}` tuples
  or IPv4 CIDR strings like `"10.0.0.0/8"`). On a direct connection those
  headers are client-spoofable and are IGNORED (fail-closed): the direct
  request authority is used.
  """
  def request_authority(conn) do
    if trusted_proxy?(conn.remote_ip) do
      forwarded_authority(conn)
    else
      direct_authority(conn)
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if anonymous_mode?() or exempt?(conn.request_path) do
      conn
    else
      case verify_bearer(conn) do
        :ok -> conn
        {:refuse, code, reason} -> refuse(conn, code, reason)
      end
    end
  end

  @doc """
  Verifies the `Authorization: Bearer` header on `conn`:
  `:ok | {:refuse, code, reason}`. Also exported for direct use by tests.
  """
  def verify_bearer(conn) do
    with {:ok, token} <- extract_token(conn),
         {:ok, signer} <- signer(),
         {:ok, claims} <- verify_signature(token, signer),
         :ok <- validate_claims(claims, conn) do
      :ok
    end
  end

  # -- mode --------------------------------------------------------------------

  defp anonymous_mode? do
    Application.get_env(:smalt, :auth_mode, :enforce) == :anonymous
  end

  defp exempt?("/metadata/endpoints" <> _rest = path) do
    # exact-match the endpoint itself; a longer path is NOT the endpoint
    path == "/metadata/endpoints"
  end

  # Exact-match list: "/metadata/endpoints" matches ONLY the endpoint
  # itself; a longer path is NOT the endpoint (no prefix relaxation).
  defp exempt?(path) do
    # KD-COVERS: KD-87 (canonical row in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md)
    # KD-87: leading "//{tid}/..." tolerated — azurerm joins the metadata
    # loginEndpoint (trailing slash) with the tenant (leading slash); real
    # Azure tolerates the double slash. Leading empty segment ONLY (one
    # normalization pass); interior double slashes still fail the [^/]+
    # segment guard, and any suffix fails the `$` anchor.
    path = String.replace_leading(path, "//", "/")

    # Tenant-scoped STS mint endpoint (C6 row 5: /{tid}/oauth2/v2.0/token).
    # Bootstrap class — the client cannot hold a token yet. The shape is a
    # bounded 4-segment form: it canNOT collide with egress routes (max 3
    # segments; the blob catch-all is additionally x-ms-version-guarded),
    # and %-encoded suffixes fail the `$` anchor fail-closed.
    path in @exempt_exact or
      Enum.any?(@exempt_prefixes, fn prefix -> String.starts_with?(path, prefix) end) or
      Regex.match?(~r{^/[^/]+/oauth2/v2\.0/token$}, path)
  end

  # Public read of the exempt-path predicate (egress-dispatch lens-4 cross-lane
  # seam, disclosed): the blob catch-all in Smalt.EgressRouter must fail-closed
  # refuse blob-reachable paths that sit in the auth-exempt namespace — the
  # exemption composes with the splat (account=".well-known"/"oauth2"/"attest"/
  # "metadata") and x-ms-version is client-supplied, not authentication. One
  # canonical predicate here; the router consumes it, never re-lists prefixes.
  def auth_exempt_path?(path), do: exempt?(path)

  # -- token extraction ----------------------------------------------------------

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:refuse, "AuthenticationFailed", "MissingBearerToken"}

      [_, _ | _] ->
        # Lens-5 typed decision (M-L5-3): RFC 7230 §3.2.2 / RFC 9110 §5.3 —
        # Authorization is NOT a list-combinable field; a request carrying two
        # Authorization headers is an invalid message. Previous first-wins
        # selection silently chose one interpretation of an ambiguous
        # message; fail-closed refusal removes the ambiguity. (First-wins was
        # not exploitable to displace a valid token — the attacker cannot
        # reorder proxy-preserved header lists — but "which header wins"
        # should not be a security-relevant question at all.)
        {:refuse, "InvalidAuthenticationToken", "MalformedBearerHeader"}

      [value] ->
        case parse_cosmos_aad(value) do
          # KD-COVERS: KD-94
          # KD-94: @azure/cosmos AAD token-provider wire shape — the SDK's
          # TokenCredential policy sends
          #   Authorization: type=aad&ver=1.0&sig=<jwt>
          # (no "Bearer " scheme prefix). Real Azure accepts this form; the
          # previous extractor required `Bearer <jwt>` and refused it 401.
          # The sig= value is verified through the SAME HS256/claims path as
          # any Bearer token — no relaxation: a garbage or foreign-signed sig
          # refuses SignatureVerificationFailed exactly as before, and the
          # `Bearer <jwt>` form is unaffected.
          {:ok, jwt} ->
            {:ok, jwt}

          :not_aad ->
            case String.split(value, " ", parts: 2) do
              [scheme, token] ->
                # RFC 7235 §2.1: the auth-scheme is case-insensitive; real AAD
                # accepts "bearer"/"BEARER". Trim handles multi-space padding.
                token = String.trim(token)

                if String.downcase(scheme) == "bearer" and byte_size(token) > 0 do
                  {:ok, token}
                else
                  {:refuse, "InvalidAuthenticationToken", "MalformedBearerHeader"}
                end

              _ ->
                {:refuse, "InvalidAuthenticationToken", "MalformedBearerHeader"}
            end
        end
    end
  end

  # KD-COVERS: KD-94
  # `type=aad&ver=1.0&sig=<jwt>` — the @azure/cosmos AAD token-provider
  # Authorization value. Returns {:ok, jwt} only on the exact prefix AND a
  # non-empty sig; anything else is :not_aad (fall through to the Bearer
  # parser, which refuses fail-closed). ver is pinned to "1.0" — any other
  # ver is :not_aad.
  defp parse_cosmos_aad(value) when is_binary(value) do
    case String.split(value, "sig=", parts: 2) do
      [prefix, sig] ->
        type_ok = String.starts_with?(prefix, "type=aad&")
        ver_ok = String.contains?(prefix, "&ver=1.0&") or prefix == "type=aad&ver=1.0&"
        sig_ok = byte_size(sig) > 0

        if type_ok and ver_ok and sig_ok and not String.contains?(sig, " ") do
          {:ok, sig}
        else
          :not_aad
        end

      _ ->
        :not_aad
    end
  end

  defp parse_cosmos_aad(_), do: :not_aad

  # -- signing secret ------------------------------------------------------------

  defp signer do
    case Application.get_env(:smalt, :sts_signing_secret) do
      secret when is_binary(secret) ->
        {:ok, Joken.Signer.create("HS256", secret)}

      _ ->
        # No env secret: fall back to the ARM gateway's generated dev secret
        # (same :persistent_term key the gateway caches under) so that dev
        # substrates that mint tokens without a configured secret can still
        # verify them. Refuse if nothing has been generated yet.
        case :persistent_term.get({Smalt.ArmGateway.Router, :sts_signing_secret}, :missing) do
          :missing -> {:refuse, "AuthenticationFailed", "NoSigningSecretConfigured"}
          secret -> {:ok, Joken.Signer.create("HS256", secret)}
        end
    end
  end

  # -- signature + claims ----------------------------------------------------------

  # JWS header fence (lens-4 cycle 4): Joken.verify/2 verifies the signature
  # but IGNORES JWS header parameters. RFC 7515 §4.1.11: a JWS verifier MUST
  # reject a token whose `crit` header lists an extension it does not
  # understand (we understand none), and `b64: false` (RFC 7797 unencoded
  # payload) rides `crit` — both measured as ACCEPTED by Joken.verify before
  # the fence. Fail-closed: any `crit` or `b64` header member refuses.
  defp verify_signature(token, signer) do
    with {:ok, claims} <- verify_sig(token, signer),
         :ok <- header_fence(token) do
      {:ok, claims}
    end
  end

  defp verify_sig(token, signer) do
    case Joken.verify(token, signer) do
      {:ok, claims} ->
        {:ok, claims}

      {:error, _reason} ->
        {:refuse, "InvalidAuthenticationToken", "SignatureVerificationFailed"}
    end
  end

  # Refusal class matches the signature family (the token's JWS envelope is
  # invalid for this verifier), ARM-plausible, deterministic position: header
  # fence runs only AFTER signature verification succeeded.
  #
  # Lens-5 header fence v2 (three typed decisions on the lens-4 fence):
  # 1. `crit: []` — RFC 7515 §4.1.11 says the empty array is legal and
  #    conveys "no critical extensions". Previous fence refused it
  #    (over-strict); now accepts exact `[]` and still refuses non-list and
  #    non-empty crit (we implement no extension).
  # 2. `b64` — ANY presence refuses (we implement no RFC 7797 unencoded
  #    payload; even `b64: true` is a 7797-grammar member and unimplemented).
  # 3. `typ` — RFC 8725 §3.11: the verifier should explicitly type-check.
  #    Absent typ accepts (the mint signs %{} headers); present typ must be
  #    "JWT" case-insensitively; anything else ("at+jwt", "JWS", numbers)
  #    refuses fail-closed.
  defp header_fence(token) do
    case Joken.peek_header(token) do
      {:ok, header} when is_map(header) ->
        cond do
          Map.has_key?(header, "b64") ->
            {:refuse, "InvalidAuthenticationToken", "UnsupportedCriticalHeader"}

          Map.has_key?(header, "crit") and header["crit"] != [] ->
            {:refuse, "InvalidAuthenticationToken", "UnsupportedCriticalHeader"}

          Map.has_key?(header, "typ") and not valid_typ?(header["typ"]) ->
            {:refuse, "InvalidAuthenticationToken", "UnsupportedTokenHeader"}

          true ->
            :ok
        end

      # peek failure on a token that just verified: refuse fail-closed.
      _ ->
        {:refuse, "InvalidAuthenticationToken", "SignatureVerificationFailed"}
    end
  end

  defp valid_typ?(typ) when is_binary(typ), do: String.downcase(typ) == "jwt"
  defp valid_typ?(_), do: false

  defp validate_claims(claims, conn) do
    now = System.system_time(:second)

    # Env normalization: a bare-binary (or other non-list) :token_audiences
    # value must not crash `in/2` into a 500 out of the auth plug. nil falls
    # back to the default audience set.
    audiences =
      case Application.get_env(:smalt, :token_audiences, @default_audiences) do
        list when is_list(list) -> list
        nil -> @default_audiences
        other -> List.wrap(other)
      end

    cond do
      expired?(claims["exp"], now) ->
        {:refuse, "InvalidAuthenticationToken", "TokenExpired"}

      not nbf_ok?(claims["nbf"], now) ->
        # lens-3 cycle 4 (fuzz finding): nbf was never validated — a token
        # minted with a FUTURE nbf was accepted before its window opened.
        # Fail-closed: present-and-integer nbf must be <= now; a non-integer
        # present nbf refuses too (same catch-all policy as non-integer exp).
        {:refuse, "InvalidAuthenticationToken", "TokenNotYetValid"}

      claims["aud"] not in audiences ->
        {:refuse, "InvalidAuthenticationTokenAudience", "AudienceMismatch"}

      not issuer_ok?(claims["iss"], conn) ->
        {:refuse, "InvalidAuthenticationTokenIssuer", "IssuerMismatch"}

      true ->
        :ok
    end
  end

  defp expired?(exp, now) when is_integer(exp), do: exp <= now
  defp expired?(_exp, _now), do: true

  # nbf contract (lens-3 cycle 4 fuzz finding): a PRESENT nbf must be an
  # integer <= now. Absent nbf is a valid JWT and accepts; a future or
  # non-integer nbf refuses (fail-closed, same policy as non-integer exp).
  defp nbf_ok?(nbf, now) when is_integer(nbf), do: nbf <= now
  defp nbf_ok?(nil, _now), do: true
  defp nbf_ok?(_nbf, _now), do: false

  # Issuer contract (lane 105 made the STS request-authority-derived): the
  # token iss must be "{this-request's authority}/{tid}/v2.0" — the same
  # derivation the discovery doc advertises — OR an authority this substrate
  # actually minted a token for (cross-seat acceptance) — OR the legacy AAD
  # prefix (compat for tokens minted against the public-cloud form).
  defp issuer_ok?(iss, conn) when is_binary(iss) do
    String.starts_with?(iss, @iss_prefix) or
      String.starts_with?(iss, "#{request_authority(conn)}/") or
      minted_authority?(iss)
  end

  defp issuer_ok?(_iss, _conn), do: false

  # True when `iss` carries the authority of a token this substrate actually
  # minted (see register_trusted_authority/1). This is the cross-port leg: a
  # fresh valid token minted at the ARM authority is accepted on the Cosmos/
  # egress seat even though that request's own authority differs.
  defp minted_authority?(iss) do
    # lens-4 fence (cycle 2): "" can never be a registry key — the register
    # side no-ops scheme-less authorities — so the lookup below can never
    # match one. No verify-side guard needed (M-L4-6: redundant guard was
    # deleted as subsumed; the single fence is the register-side no-op).
    :persistent_term.get({__MODULE__, :trusted, issuer_authority(iss)}, false)
  end

  # "https://arm.internal:19081/tid/v2.0" -> "https://arm.internal:19081"
  defp issuer_authority(iss) do
    case String.split(iss, "://", parts: 2) do
      [scheme, rest] -> "#{scheme}://" <> hd(String.split(rest, "/", parts: 2))
      _ -> ""
    end
  end

  # -- request-authority derivation (single source: plug + ARM gateway) ---------

  defp direct_authority(conn) do
    "#{conn.scheme}://#{conn.host}#{port_part(conn.scheme, conn.port)}"
  end

  defp forwarded_authority(conn) do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        [p | _] -> if String.downcase(p) == "https", do: :https, else: :http
        [] -> conn.scheme
      end

    {host, port} =
      case get_req_header(conn, "x-forwarded-host") do
        [h | _] ->
          case String.split(h, ":", parts: 2) do
            [host] ->
              {host, default_port(scheme)}

            [host, p] ->
              # Malformed forwarded port degrades to the direct-request
              # authority, never raises out of the auth plug (500 crash).
              case Integer.parse(p) do
                {int, ""} when int > 0 -> {host, int}
                _ -> {conn.host, conn.port}
              end
          end

        [] ->
          {conn.host, conn.port}
      end

    port_part = if port == default_port(scheme), do: "", else: ":#{port}"
    "#{scheme}://#{host}#{port_part}"
  end

  # Scheme-aware: strip only the scheme's default port (parity with
  # forwarded_authority). Blind [80, 443] stripping collided http:443 /
  # https:80 onto the default authority (iss-leg collision across seats).
  # SHIM-COURT (lane R32 minimal unblock, compile-freeze SLA): a function
  # call is not legal in a defp guard — moved the default-port comparison to
  # the body. Semantics unchanged from the authoring lane's intent.
  defp port_part(scheme, port) do
    if port == default_port(scheme), do: "", else: ":#{port}"
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  # -- trusted-proxy gating (fail-closed) ---------------------------------------

  defp trusted_proxy?(ip) do
    Enum.any?(Application.get_env(:smalt, :trusted_proxies, []), fn
      t when is_tuple(t) -> t == ip
      cidr when is_binary(cidr) -> cidr_match?(ip, cidr)
      _ -> false
    end)
  end

  defp cidr_match?(ip, cidr) when is_tuple(ip) and is_binary(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [base, len_s] ->
        with {len, ""} <- Integer.parse(len_s),
             true <- len in 0..32,
             {:ok, ip_int} <- ipv4_int(ip),
             {:ok, base_int} <- ipv4_string_int(base) do
          mask = encode_mask(len)
          Bitwise.band(ip_int, mask) == Bitwise.band(base_int, mask)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp cidr_match?(_ip, _cidr), do: false

  defp encode_mask(0), do: 0
  defp encode_mask(len), do: Bitwise.band(0xFFFFFFFF, Bitwise.bsl(0xFFFFFFFF, 32 - len))

  defp ipv4_int({a, b, c, d}), do: {:ok, a * 16_777_216 + b * 65_536 + c * 256 + d}
  defp ipv4_int(_), do: :error

  defp ipv4_string_int(s) do
    case String.split(s, ".") do
      [a, b, c, d] ->
        with {ai, ""} <- Integer.parse(a),
             {bi, ""} <- Integer.parse(b),
             {ci, ""} <- Integer.parse(c),
             {di, ""} <- Integer.parse(d),
             true <- ai in 0..255 and bi in 0..255 and ci in 0..255 and di in 0..255 do
          {:ok, ai * 16_777_216 + bi * 65_536 + ci * 256 + di}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # -- refusal -------------------------------------------------------------------

  defp refuse(conn, code, reason) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => reason}})

    conn
    |> put_resp_header("www-authenticate", challenge_value(conn, reason))
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  # KD-COVERS: KD-15
  # -- KD-15: Key Vault challenge enrichment (RFC 6750 §3 + ADAL/azure-core
  # ChallengeAuthPolicy grammar) -----------------------------------------------

  @doc """
  The enriched `WWW-Authenticate: Bearer` challenge value for `conn`.

  Grammar constraint (KD-15, E-3a): the @azure SDK whitelist
  (keyvault-common parseWWWAuthenticate.js) accepts `authorization` (it
  derives tenantId from the URL PATH — so the value MUST carry a tenant
  segment) and `resource` (keyVaultAuthenticationPolicy.js verifies the
  resource HOSTNAME equals the vault endpoint hostname — so resource MUST
  echo the request origin). `authorization_uri` is NOT in the whitelist and
  would be silently dropped.

  Values:
  - `authorization` — the STS authority URL with a tenant path segment
    (`:smalt, :sts_authority_url` override, else `<scheme>://<host>:<arm_port>/organizations`).
  - `resource` — the request origin `scheme://host:port` as the client reached us.
  """
  def challenge_value(conn, reason) do
    reason = String.replace(reason, "\"", "")

    authorization =
      Application.get_env(:smalt, :sts_authority_url) ||
        "#{conn.scheme}://#{conn.host}:#{Application.get_env(:smalt, :arm_port, 9443)}/organizations"

    resource = "#{conn.scheme}://#{conn.host}:#{conn.port}"

    ~s(Bearer authorization="#{authorization}", resource="#{resource}", error="invalid_token", error_description="#{reason}")
  end

  @doc """
  Sends the KD-15 401 challenge (enriched `WWW-Authenticate` + ARM error
  envelope) and halts. Mode-blind: called by the egress router's /keys guard
  in BOTH auth modes when the Authorization header is missing or empty.
  """
  def send_challenge(conn, reason) do
    body = Jason.encode!(%{"error" => %{"code" => "AuthenticationFailed", "message" => reason}})

    conn
    |> put_resp_header("www-authenticate", challenge_value(conn, reason))
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
