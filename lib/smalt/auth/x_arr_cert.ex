defmodule Smalt.Auth.XArrCert do
  @moduledoc """
  X-ARR-ClientCert mTLS gateway-termination verification plug (Sovereign
  Midnight G2: APIM-style front-door client-certificate authentication).

  Azure API Management fronted by ARR delivers the TLS client certificate it
  terminated as the `X-ARR-ClientCert` header: base64 DER, URL-encoded. This
  plug reproduces the gateway-termination trust boundary: the header is only
  trustworthy when the gateway did the TLS handshake, so when the feature is
  enabled the plug treats the header as a CLAIM to verify, never as identity:

  - absent header -> 401 challenge-shaped refusal (AuthenticationFailed /
    ClientCertificateMissing)
  - present but not URL-decodable / not valid base64 / not parseable DER ->
    401 InvalidAuthenticationToken / MalformedClientCertificate
  - parses but outside its validity window (expired OR not-yet-valid, at the
    verify clock) -> 401 InvalidAuthenticationToken / ClientCertExpired or
    ClientCertNotYetValid
  - parses, in-window, but does NOT chain to the configured CA
    (`config :smalt, :x_arr_cert, ca_certfile:`) -> 403
    AuthenticationFailed / ClientCertUntrustedRoot

  **Spoof-injector falsifier**: a SELF-SIGNED certificate with a SPOOFED
  friendly CN (e.g. `/CN=sovereign-client`) is REFUSED with
  ClientCertUntrustedRoot — the CN string carries zero trust; only pkix path
  validation against the configured CA mints identity. Any change that makes
  this plug accept a self-signed cert with an unknown issuer is the failure.

  On success, resolves identity and attaches it to
  `conn.private[:x_arr_identity]`:

      %{thumbprint: hex_sha1, thumbprint256: hex_sha256, subject: cn}

  The thumbprints are the SHA-1 and SHA-256 pkix digest hashes of the raw DER
  (the values Azure portal/clickstream surfaces as the cert thumbprint), and
  the subject is the certificate CN.

  Config (`config :smalt, :x_arr_cert, ...`):

  - `require: true | false` (default **false**) — when false the plug is
    byte-identical to absent (pass-through); when true, protected routes
    require a verified client certificate.
  - `ca_certfile: "/path/to/ca-cert.pem"` — the trusted CA (PEM or DER).
    Required when `require: true`; without it every presented cert refuses
    fail-closed (ClientCertUntrustedRoot) — never an accept.

  Bootstrap/discovery paths (the same exempt set `Smalt.Auth.Bearer`
  publishes via `auth_exempt_path?/1`) pass through: a client cannot present
  a certificate before discovery exists to tell it how to.

  Refusals follow the `Smalt.Auth.Bearer` ARM error-envelope shape
  (`{"error": {"code": ..., "message": ...}}`, halted).
  """

  @behaviour Plug
  import Plug.Conn

  require Logger

  @header "x-arr-clientcert"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if enabled?() and not Smalt.Auth.Bearer.auth_exempt_path?(conn.request_path) do
      case verify_client_cert(conn) do
        {:ok, conn} ->
          conn

        {:refuse, status, code, reason} ->
          refuse(conn, status, code, reason)
      end
    else
      conn
    end
  end

  @doc """
  Verifies the `X-ARR-ClientCert` header on `conn`:
  `{:ok, conn} | {:refuse, status, code, reason}` — the conn carries
  `:x_arr_identity` on success. Also exported for direct use by
  tests/witnesses.
  """
  def verify_client_cert(conn) do
    with {:ok, der} <- extract_der(conn),
         {:ok, otp_cert} <- parse_der(der),
         :ok <- validate_window(otp_cert),
         :ok <- validate_chain(der, otp_cert) do
      identity = %{
        thumbprint: hex(:crypto.hash(:sha, der)),
        thumbprint256: hex(:crypto.hash(:sha256, der)),
        subject: subject_cn(otp_cert)
      }

      {:ok, Plug.Conn.put_private(conn, :x_arr_identity, identity)}
    end
  end

  @doc """
  Resolved client identity after a successful `call/2`
  (`conn.private[:x_arr_identity]`): `%{thumbprint, thumbprint256, subject}`
  or `nil`.
  """
  def identity(conn), do: conn.private[:x_arr_identity]

  # -- config -------------------------------------------------------------------

  # Lane-unblock helper (was referenced by verify_client_cert/1 but not yet
  # defined when this file was first compiled on the shared tree).
  defp hex(d), do: Base.encode16(d, case: :lower)

  defp enabled? do
    :smalt
    |> Application.get_env(:x_arr_cert, [])
    |> Keyword.get(:require, false)
  end

  defp ca_certs do
    case Application.get_env(:smalt, :x_arr_cert, []) |> Keyword.get(:ca_certfile) do
      f when is_binary(f) ->
        # Cache on file mtime: re-read only when the CA file changed; the
        # request path never touches the filesystem.
        case File.stat(f) do
          {:ok, %{mtime: mtime}} ->
            cached = :persistent_term.get({__MODULE__, :ca, f}, nil)

            case cached do
              {^mtime, certs} when is_list(certs) and certs != [] ->
                certs

              _ ->
                certs = decode_ca_file(f)
                :persistent_term.put({__MODULE__, :ca, f}, {mtime, certs})
                certs
            end

          _ ->
            Logger.error(
              "x_arr_cert: CA certfile stat failed (missing or unreadable): #{inspect(f)} — " <>
                "every client certificate will refuse ClientCertUntrustedRoot while require: true"
            )

            []
        end

      _ ->
        Logger.error(
          "x_arr_cert: no :ca_certfile configured under config :smalt, :x_arr_cert — " <>
            "every client certificate will refuse ClientCertUntrustedRoot while require: true"
        )

        []
    end
  end

  # Trusted store entries stay DER binaries — pkix_path_validation/3 takes
  # TrustedCerts = [der_encoded()].
  defp decode_ca_file(f) do
    case File.read(f) do
      {:ok, pem} ->
        case :public_key.pem_decode(pem) do
          [] ->
            # Not PEM — accept a raw DER CA file only if it parses as a cert.
            try do
              _ = :public_key.pkix_decode_cert(pem, :otp)
              [pem]
            rescue
              e ->
                Logger.error(
                  "x_arr_cert: CA file #{inspect(f)} is neither PEM nor a decodable DER cert: " <>
                    Exception.format(:error, e)
                )

                []
            end

          entries ->
            for {:Certificate, der, :not_encrypted} <- entries, do: der
        end

      {:error, reason} ->
        Logger.error("x_arr_cert: CA file read failed for #{inspect(f)}: #{inspect(reason)}")
        []
    end
  end

  # -- extraction ----------------------------------------------------------------

  # APIM delivers the header URL-encoded base64 DER. Multiple header
  # instances are an ambiguous message — refuse fail-closed (same policy as
  # the Bearer plug's duplicate-Authorization fence).
  defp extract_der(conn) do
    case get_req_header(conn, @header) do
      [] ->
        {:refuse, 401, "AuthenticationFailed", "ClientCertificateMissing"}

      [_, _ | _] ->
        {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}

      [value] ->
        decoded = URI.decode(value)

        if String.valid?(decoded) do
          case Base.decode64(decoded) do
            {:ok, der} -> {:ok, der}
            :error -> {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}
          end
        else
          {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}
        end
    end
  end

  defp parse_der(der) do
    try do
      # :otp form (records) — the :plain form is a plain map and does NOT
      # match the :OTPCertificate tuple; the tuple match below is the gate.
      case :public_key.pkix_decode_cert(der, :otp) do
        {:OTPCertificate, _, _, _} = cert -> {:ok, cert}
        _ -> {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}
      end
    rescue
      _ -> {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}
    catch
      _ -> {:refuse, 401, "InvalidAuthenticationToken", "MalformedClientCertificate"}
    end
  end

  # -- validity window ------------------------------------------------------------

  defp validate_window(otp_cert) do
    # tbs element 5 is :validity (record positions: tag, version, serial,
    # signature, issuer, validity, subject, ...).
    {:Validity, from, to} = otp_cert |> elem(1) |> elem(5)
    now = calendar_time()

    cond do
      clock_compare(from, now) == :gt ->
        {:refuse, 401, "InvalidAuthenticationToken", "ClientCertNotYetValid"}

      clock_compare(to, now) != :gt ->
        {:refuse, 401, "InvalidAuthenticationToken", "ClientCertExpired"}

      true ->
        :ok
    end
  end

  defp calendar_time do
    case Application.get_env(:smalt, :sts_clock) do
      now when is_integer(now) ->
        # Pinned verify clock (same pin the Bearer plug honors): convert the
        # epoch-seconds override to UTC calendar time so TTL moves in tests.
        :calendar.gregorian_seconds_to_datetime(now + 62_167_219_200)

      _ ->
        :calendar.universal_time()
    end
  end

  # ASN.1 UTCTime/GeneralizedTime charlists ("YYMMDDHHMMSSZ" / "YYYYMMDDHHMMSSZ")
  # are NOT term-order comparable to calendar tuples — normalize both sides.
  # These clauses MUST precede the tuple/tuple fallback (a tagged time IS a
  # tuple and would otherwise hit the raw term-order compare).
  defp clock_compare({:utcTime, cs}, now), do: clock_compare(asn1_time_to_dt(cs), now)
  defp clock_compare({:generalizedTime, cs}, now), do: clock_compare(asn1_time_to_dt(cs), now)
  defp clock_compare(a, {:utcTime, cs}), do: clock_compare(a, asn1_time_to_dt(cs))
  defp clock_compare(a, {:generalizedTime, cs}), do: clock_compare(a, asn1_time_to_dt(cs))

  defp clock_compare(a, b) when is_tuple(a) and is_tuple(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  # Unparseable cert time refuses fail-closed (never accept on parse failure).
  defp clock_compare(bad, _), do: raise(ArgumentError, "uncomparable cert time: #{inspect(bad)}")

  defp asn1_time_to_dt(cs) do
    s = to_string(cs)

    {year, rest} =
      if byte_size(s) == 13 do
        # UTCTime: YY — >=50 rolls to 19xx, else 20xx (RFC 5280 §4.1.2.5.1)
        y = String.to_integer(binary_part(s, 0, 2))
        {if(y >= 50, do: 1900 + y, else: 2000 + y), binary_part(s, 2, 10)}
      else
        {String.to_integer(binary_part(s, 0, 4)), binary_part(s, 4, 10)}
      end

    with {mo, _} <- Integer.parse(binary_part(rest, 0, 2)),
         {d, _} <- Integer.parse(binary_part(rest, 2, 2)),
         {h, _} <- Integer.parse(binary_part(rest, 4, 2)),
         {mi, _} <- Integer.parse(binary_part(rest, 6, 2)),
         {se, ""} <- Integer.parse(binary_part(rest, 8, 2)) do
      {{year, mo, d}, {h, mi, se}}
    end
  end

  # -- chain validation -------------------------------------------------------------

  defp validate_chain(der, _otp_cert) do
    trusted = ca_certs()

    if trusted == [] do
      # No trusted CA configured: fail-closed, never accept.
      {:refuse, 403, "AuthenticationFailed", "ClientCertUntrustedRoot"}
    else
      # pkix_path_validation(TrustedCert, CertChain, Options) takes ONE
      # trusted cert (DER) + the leaf DER as the chain — a LIST as TrustedCert
      # crashes :public_key's combined_cert/1. Multiple configured CAs are
      # tried in turn; any success validates (accept-class, deterministic).
      result =
        Enum.find_value(trusted, fn ca_der ->
          case :public_key.pkix_path_validation(ca_der, [der], []) do
            {:ok, _} -> :ok
            {:error, _} -> nil
          end
        end)

      result || {:refuse, 403, "AuthenticationFailed", "ClientCertUntrustedRoot"}
    end
  end

  # -- subject ---------------------------------------------------------------------

  defp subject_cn(otp_cert) do
    # {:OTPCertificate, tbs, sig_alg, signature}; tbs element 6 is :subject
    # (record positions: tag, version, serial, signature, issuer, validity,
    # subject, ...). Subject is {:rdnSequence, rdn_sets}.
    tbs = elem(otp_cert, 1)

    case elem(tbs, 6) do
      {:rdnSequence, rdn_sets} ->
        rdn_sets
        |> List.flatten()
        |> Enum.find_value(fn
          # DirectoryString: CN arrives tagged ({:utf8String, cn} for modern
          # issuers, {:printableString, cn} for legacy) — unwrap the tag.
          # OTP ASN.1 decodes printableString to a charlist; normalize it.
          {:AttributeTypeAndValue, {2, 5, 4, 3}, {_tag, cn}} when is_binary(cn) -> cn
          {:AttributeTypeAndValue, {2, 5, 4, 3}, {:printableString, cn}} when is_list(cn) ->
            List.to_string(cn)
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # -- refusal ---------------------------------------------------------------------

  defp refuse(conn, status, code, reason) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => reason}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
