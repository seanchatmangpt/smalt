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

  defp exempt?(path) when path in @exempt_exact, do: true

  defp exempt?(path) do
    Enum.any?(@exempt_prefixes, fn prefix -> String.starts_with?(path, prefix) end)
  end

  # -- token extraction ----------------------------------------------------------

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:refuse, "AuthenticationFailed", "MissingBearerToken"}

      [value | _] ->
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

  defp verify_signature(token, signer) do
    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} ->
        {:refuse, "InvalidAuthenticationToken", "SignatureVerificationFailed"}
    end
  end

  defp validate_claims(claims, conn) do
    now = System.system_time(:second)
    audiences = Application.get_env(:smalt, :token_audiences, @default_audiences)

    cond do
      expired?(claims["exp"], now) ->
        {:refuse, "InvalidAuthenticationToken", "TokenExpired"}

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

  # Issuer contract (lane 105 made the STS request-authority-derived): the
  # token iss must be "{this-request's authority}/{tid}/v2.0" — the same
  # derivation the discovery doc advertises — OR the legacy AAD prefix
  # (compat for tokens minted against the public-cloud form).
  defp issuer_ok?(iss, conn) when is_binary(iss) do
    String.starts_with?(iss, @iss_prefix) or
      String.starts_with?(iss, "#{request_authority(conn)}/")
  end

  defp issuer_ok?(_iss, _conn), do: false

  # Mirrors ArmGateway.Router.request_authority/1 derivation (scheme/host/port
  # with x-forwarded-* honor) so the plug and the STS agree on any seat.
  defp request_authority(conn) do
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
              # Malformed forwarded port must degrade to the direct-request
              # authority, never raise out of the auth plug (500 crash).
              case Integer.parse(p) do
                {int, ""} when int > 0 -> {host, int}
                _ -> {conn.host, conn.port}
              end
          end

        [] ->
          {conn.host, conn.port}
      end

    default_port? = port in [80, 443] and port == default_port(scheme)
    if default_port?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  # -- refusal -------------------------------------------------------------------

  defp refuse(conn, code, reason) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => reason}})

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token", error_description="#{reason}"))
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
