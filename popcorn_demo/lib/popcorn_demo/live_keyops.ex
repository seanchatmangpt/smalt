defmodule PopcornDemo.LiveKeyops do
  @moduledoc """
  Key Vault key-operations walk (W4-4): create-or-reuse an EC key
  `popcorn-key`, sign a FIXED payload (ES256), verify via KV verify (valid),
  then verify a TAMPERED payload (typed negative: HTTP 200 with
  `value: false` — the real KeyVerifyResult contract, never an error).

  Chicago school — the only collaborators are the live smalt substrate (data
  plane 8443, STS 9443) over real `:gen_tcp` sockets. Same transport law as
  `PopcornDemo.LiveKV` (inets beams are broken under the popcorn_demo mix
  env — witnessed 2026-10-20).

  KD-15 KV challenge handshake (corpus premise pin): the FIRST key request is
  sent TOKENLESS; the 401's `www-authenticate` header names the STS authority
  (`authorization="..."`); the bearer is minted there and the request resent.

  DISJUNCTIVE LAW (tested against the LIVE substrate 2026-10-21): the HTTP
  key-create seam (`POST /keys/:name/create`, `Smalt.Egress.KvRoutes.jwk_for_kty/3`)
  refuses `kty: "EC"` with a typed `400 UnsupportedKeyType` while the library
  seam (`KeyVaultActions.create_key/2`) supports EC/ES256 — the wire ES256
  face is therefore UNREACHABLE on the current substrate. The walk is honest
  about this:

  - EC create 200  -> full ES256 walk -> `{:ok, "keyops=OK(ES256:verified)"}`
  - EC create 400 UnsupportedKeyType -> the walk still witnesses the KV
    crypto contract for real over the wire (RS256 on `popcorn-key`: sign 200,
    verify valid, tampered verify invalid) and returns
    `{:skip, "keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)"}` —
    SKIP is loud, never a faked pass.
  - any other create outcome -> `{:error, "keyops=FAIL(<step>:<reason>)"}`

  Candidate KD row for the coordinator: HTTP create seam lacks EC dispatch
  (KvRoutes.jwk_for_kty/3 arms: RSA/RSA-HSM, oct, oct-HSM only); close
  condition — an EC arm projecting crv/x/y JWK + private DER onto the row,
  after which this walk flips SKIP -> OK(ES256:verified) with no edit.
  """

  @base "http://127.0.0.1:8443"
  @key "popcorn-key"
  @fixed_payload "popcorn-keyops-fixed-payload"
  @api_version "7.4"

  @doc """
  Runs the walk. Returns:

  - `{:ok, "keyops=OK(ES256:verified)"}`
  - `{:skip, "keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)"}`
  - `{:error, "keyops=FAIL(<step>:<reason>)"}`
  """
  def run do
    with {:ok, _} <- health(),
         {:ok, token} <- kv_challenge_token(),
         ec_create <- ec_create(token) do
      case ec_create do
        {:ok, _bundle} ->
          with :ok <- es256_walk(token) do
            {:ok, "keyops=OK(ES256:verified)"}
          end

        {:unsupported_key_type, _body} ->
          with :ok <- rs256_fallback_walk(token) do
            {:skip, "keyops=SKIP(es256:UnsupportedKeyType;rs256-witnessed-ok)"}
          end

        {:error, {step, reason}} ->
          {:error, "keyops=FAIL(#{step}:#{fmt(reason)})"}
      end
    else
      {:error, {step, reason}} when is_binary(step) ->
        {:error, "keyops=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  # -- KD-15 challenge handshake (same shape as LiveKV) ----------------------

  defp kv_challenge_token do
    url = key_url()

    case request(%{method: "GET", url: url, body: ""}) do
      {:ok, %{status: 401, headers: headers}} ->
        with {:ok, authority} <- www_authenticate_authority(headers),
             {:ok, token} <- sts_token(authority) do
          {:ok, token}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"challenge", "expected-401-got-http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"challenge", fmt(reason)}}
    end
  end

  defp www_authenticate_authority(headers) do
    case header(headers, "www-authenticate") do
      nil ->
        {:error, {"challenge", "401-without-www-authenticate-header"}}

      value ->
        case Regex.run(~r/authorization="([^"]+)"/i, value) do
          [_, authority] -> {:ok, authority}
          nil -> {:error, {"challenge", "www-authenticate-missing-authorization:#{slice(value)}"}}
        end
    end
  end

  defp sts_token(authority) do
    req = %{
      method: "POST",
      url: authority <> "/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"token", fmt(reason)}}
    end
  end

  # -- key create / reuse ----------------------------------------------------

  # The create-or-reuse attempt: POST /keys/:name/create with kty EC. The
  # current substrate answers a typed 400 UnsupportedKeyType (witnessed
  # 2026-10-21); the walk classifies that refusal instead of dying on it.
  defp ec_create(token) do
    req = %{
      method: "POST",
      url: key_create_url(),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"kty" => "EC", "crv" => "P-256"})
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"key" => %{"kty" => "EC"}}} -> {:ok, body}
          {:ok, _} -> {:error, {"ec-create", "200-without-EC-kty:#{slice(body)}"}}
          _ -> {:error, {"ec-create", "200-with-unparseable-body"}}
        end

      {:ok, %{status: 400, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => %{"code" => "UnsupportedKeyType"}}} ->
            {:unsupported_key_type, body}

          _ ->
            {:error, {"ec-create", "http-400-not-UnsupportedKeyType:#{slice(body)}"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"ec-create", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"ec-create", fmt(reason)}}
    end
  end

  # -- ES256 walk (taken when the EC create succeeds) ------------------------

  defp es256_walk(token) do
    digest = digest()

    with {:ok, sig} <- sign(token, "ES256", digest) do
      with :ok <- verify(token, "ES256", digest, sig, true),
           :ok <- verify(token, "ES256", tampered_digest(), sig, false) do
        :ok
      end
    end
  end

  # -- RS256 fallback walk (current substrate) — same wire contract, real ----

  defp rs256_fallback_walk(token) do
    with :ok <- create_or_reuse_rsa(token) do
      digest = digest()

      with {:ok, sig} <- sign(token, "RS256", digest) do
        with :ok <- verify(token, "RS256", digest, sig, true),
             :ok <- verify(token, "RS256", tampered_digest(), sig, false) do
          :ok
        end
      end
    end
  end

  defp create_or_reuse_rsa(token) do
    req = %{
      method: "POST",
      url: key_create_url(),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"kty" => "RSA"})
    }

    case step_req("rsa-create", req, 200) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # -- sign / verify steps ---------------------------------------------------

  defp sign(token, alg, digest) do
    req = %{
      method: "POST",
      url: key_op_url("sign"),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"alg" => alg, "digest" => digest})
    }

    with {:ok, %{body: body}} <- step_req("sign-#{alg}", req, 200) do
      case Jason.decode(body) do
        {:ok, %{"value" => sig}} when is_binary(sig) and sig != "" -> {:ok, sig}
        _ -> {:error, {"sign-#{alg}", "200-without-signature-value-field"}}
      end
    end
  end

  # Typed negative: a wrong digest verifies to HTTP 200 with value:false
  # (KeyVerifyResult) — the walk asserts the boolean, not just the status.
  defp verify(token, alg, digest, sig, want_valid) do
    req = %{
      method: "POST",
      url: key_op_url("verify"),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"alg" => alg, "digest" => digest, "value" => sig})
    }

    with {:ok, %{body: body}} <- step_req("verify-#{alg}", req, 200) do
      case Jason.decode(body) do
        {:ok, %{"value" => ^want_valid}} ->
          :ok

        {:ok, %{"value" => got}} ->
          {:error,
           {"verify-#{alg}",
            "valid-mismatch(want=#{want_valid},got=#{inspect(got)}:tampered-negative-must-be-false)"}}

        _ ->
          {:error, {"verify-#{alg}", "200-without-boolean-value-field:#{slice(body)}"}}
      end
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp key_url, do: @base <> "/keys/#{@key}?api-version=#{@api_version}"
  defp key_create_url, do: @base <> "/keys/#{@key}/create"
  defp key_op_url(action), do: @base <> "/keys/#{@key}/#{action}?api-version=#{@api_version}"

  defp step_req(step, req, want) do
    case request(req) do
      {:ok, %{status: ^want} = resp} -> {:ok, resp}
      {:ok, %{status: st, body: body}} -> {:error, {step, "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {step, fmt(reason)}}
    end
  end

  defp health do
    case request(%{method: "GET", url: @base <> "/healthz", body: ""}) do
      {:ok, %{status: 200}} -> {:ok, :ready}
      {:ok, %{status: st}} -> {:error, {"health", "http-#{st}"}}
      {:error, _} = err -> err
    end
  end

  # FIXED payload — the walk signs the same bytes every run (the signature
  # differs per run only because the key material differs, not the payload).
  # BK-46: the payload is a compile-time constant, so its SHA-256 digest is a
  # constant too — precomputed at host build time (openssl) and embedded as a
  # literal, replacing the runtime `:crypto.hash(:sha256, ...)` call (wasm has
  # no :crypto; BK-40 fixed-payload constant-digest precedent).
  #   echo -n "popcorn-keyops-fixed-payload" | openssl dgst -sha256 -binary \
  #     | base64 | tr '+/' '-_' | tr -d '='
  @fixed_digest "vCjfx6cQjufOnU90Zcz63-ok76Ib3sFPUyScC1_v2Dw"

  # The tampered negative: same signature, digest of DIFFERENT bytes.
  #   echo -n "TAMPERED-popcorn-keyops-fixed-payload" | openssl dgst -sha256 -binary \
  #     | base64 | tr '+/' '-_' | tr -d '='
  @tampered_digest "XOv47u-0TIsu3Kr0K-2bhhenTKsMc2U0R61UEbsuDKI"

  defp digest, do: @fixed_digest
  defp tampered_digest, do: @tampered_digest

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp fmt(reason) when is_binary(reason), do: reason
  defp fmt(reason), do: inspect(reason)

  defp slice(bin, max \\ 160) when is_binary(bin) do
    if byte_size(bin) > max, do: binary_part(bin, 0, max) <> "...", else: bin
  end


  # -- transport dispatch (single calculus, mirrors PopcornDemo.LiveCerts) -----
  # BK-46: replaces the raw :gen_tcp HTTP/1.1 client (the leg's primary wasm
  # blocker — `{:tcp_connect, :eprotonosupport}`). Browser requests ride
  # PopcornDemo.Transport.Fetch; host requests ride Transport.Httpc (a real
  # degraded collaborator, same request/response map shape either way).

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp request(%{method: method, url: url} = req) do
    headers = Map.get(req, :headers, [])

    # Browsers reject fetch() GET/HEAD with a body (even ""); omit body on GET.
    # BK-15b unblock (disclosed): the KV challenge step passes `body: ""` on
    # GET — fetch() refuses it outright ("Failed to fetch") in the browser.
    body =
      case method do
        m when m in ["GET", "HEAD"] -> nil
        _ -> Map.get(req, :body)
      end

    request = %{method: method, url: url, headers: headers, body: body}

    if browser?() do
      PopcornDemo.Transport.Fetch.request(request)
    else
      PopcornDemo.Transport.Httpc.request(request)
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
