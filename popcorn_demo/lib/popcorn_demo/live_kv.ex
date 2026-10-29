defmodule PopcornDemo.LiveKV do
  @moduledoc """
  Key Vault secret full-lifecycle walk (ERRC-R5): SET a unique payload on
  `popcorn-secret`, GET it back, assert byte equality, DELETE it, and verify
  404 on re-GET. Chicago school — the only collaborators are the live smalt
  substrate (data plane 8443, STS 9443) and the wire.

  REST face (verified with curl against the live substrate BEFORE this module
  existed, 2026-10-20):

  - KD-15 KV challenge handshake (corpus premise pin, repo convention): the
    FIRST secret request is sent TOKENLESS; the server answers 401 with a
    `www-authenticate: Bearer authorization="..." resource="..."` header; the
    walk parses that header, mints a bearer at the STS named by the
    challenge's `authorization=` authority, and RESENDS the same request with
    the bearer. This is the real Azure KV SDK first-touch contract.
  - Set Secret: PUT /secrets/:name?api-version=7.4 body {"value": ...} ->
    201 on first create, 200 on update/re-set (KD-149).
  - Get Secret: GET /secrets/:name?api-version=7.4 -> 200 {"value": ...}.
  - Delete Secret: DELETE /secrets/:name?api-version=7.4 -> 200 (soft delete).
    Re-GET then 404s {"error":{"code":"SecretNotFound"}}.

  Transport (ERRC-E2 dedupe, CLOSED — same calculus as `PopcornDemo.LiveMatrix`):
  all HTTP rides `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`). Caller content-type pins are preserved (Httpc honors a
  caller-set content-type). `Transport` returns RAW binary bodies and does not
  JSON-decode, so `decode_body/1` decodes best-effort at THIS module's edge
  (walk steps pattern-match on decoded JSON).

  KD-15 GAP CLOSED (W10-B): `PopcornDemo.Transport`'s response map now carries
  the 401's response HEADERS as lowercase-string-keyed `{name, value}` tuples,
  so the KD-15 challenge consumes the 401's `www-authenticate` header directly
  from the Transport response. The former raw `:gen_tcp` 401-probe block is
  deleted wholesale per the documented close condition ("Transport's resp type
  gains a `headers` field — then this module's `:gen_tcp` block deletes
  wholesale"). The challenge GET is now an ordinary tokenless Transport
  request; `www_authenticate_authority/1` and the STS mint are unchanged.
  """

  @base "http://127.0.0.1:8443"
  defp run_name, do: Process.get({__MODULE__, :resname}) || secret()
  defp secret, do: "popcorn-secret-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  @api_version "7.4"

  @doc """
  Runs the walk. Returns:

  - `{:ok, "kv=OK(popcorn-secret:<n>-bytes-lifecycle)"}`
  - `{:skip, "kv=SKIP(<loud reason>)"}`
  - `{:error, "kv=FAIL(<step>:<reason>)"}`
  """
  def run do
    Process.put({__MODULE__, :resname}, secret())
    with {:ok, _} <- health(),
         {:ok, token} <- kv_challenge_token() do
      payload = payload()
      n = byte_size(payload)

      with :ok <- set_secret(token, payload),
           :ok <- get_and_compare(token, payload, n),
           :ok <- delete_secret(token),
           :ok <- reget_404(token) do
        {:ok, "kv=OK(#{run_name()}:#{n}-bytes-lifecycle)"}
      end
    else
      {:error, {step, reason}} when is_binary(step) ->
        {:error, "kv=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  # -- KD-15 challenge handshake -------------------------------------------
  # KD-15 GAP CLOSED (W10-B): the 401's `www-authenticate` header comes
  # straight from the Transport response map (lowercase-string-keyed tuples).
  # No raw :gen_tcp remains in this module.

  # Send tokenless, take the 401 + WWW-Authenticate, resend with the bearer.
  defp kv_challenge_token do
    req = %{method: "GET", url: secret_url(), headers: [], body: nil}

    case request(req) do
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

  # Parse `www-authenticate: Bearer authorization="..." resource="..."`.
  defp www_authenticate_authority(headers) do
    case List.keyfind(headers, "www-authenticate", 0) do
      nil ->
        {:error, {"challenge", "401-without-www-authenticate-header"}}

      {_, value} ->
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
        case body do
          %{"access_token" => tok} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"token", fmt(reason)}}
    end
  end

  # -- lifecycle steps ------------------------------------------------------

  defp set_secret(token, payload) do
    req = %{
      method: "PUT",
      url: secret_url(),
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: Jason.encode!(%{"value" => payload})
    }

    # KD-149: real Azure answers 201 on FIRST create, 200 on update/re-set
    # for PUT /secrets (7.4 contract). Accept both; anything else is typed.
    case step_req_any("set-secret", req, [200, 201]) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp get_and_compare(token, payload, n) do
    req = %{method: "GET", url: secret_url(), headers: auth_headers(token), body: nil}

    with {:ok, %{body: body}} <- step_req("get-secret", req, 200) do
      case body do
        %{"value" => ^payload} ->
          :ok

        %{"value" => got} ->
          {:error,
           {"compare", "byte-mismatch(put=#{n},got=#{byte_size(got || "")})"}}

        _ ->
          {:error, {"compare", "no-value-field-in-get-body"}}
      end
    end
  end

  defp delete_secret(token) do
    req = %{method: "DELETE", url: secret_url(), headers: auth_headers(token), body: nil}

    case step_req("delete-secret", req, 200) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # Full lifecycle proof: after the soft delete the live path 404s.
  defp reget_404(token) do
    req = %{method: "GET", url: secret_url(), headers: auth_headers(token), body: nil}

    case step_req("reget-after-delete", req, 404) do
      {:ok, %{body: body}} ->
        case body do
          %{"error" => %{"code" => "SecretNotFound"}} -> :ok
          _ -> {:error, {"reget-after-delete", "http-404-but-not-SecretNotFound:#{slice(body)}"}}
        end

      err ->
        err
    end
  end

  defp secret_url, do: @base <> "/secrets/#{run_name()}?api-version=#{@api_version}"

  defp step_req(step, req, want), do: step_req_any(step, req, [want])

  # Accept any of `wants` statuses; the first match wins. A non-matching 2xx
  # is still a typed error (never silently accepted).
  defp step_req_any(step, req, wants) do
    case request(req) do
      {:ok, %{status: st} = resp} ->
        if st in wants do
          {:ok, resp}
        else
          {:error, {step, "http-#{st}:#{slice(body_of(resp))}"}}
        end

      {:error, reason} ->
        {:error, {step, fmt(reason)}}
    end
  end

  defp body_of(%{body: body}), do: body
  defp body_of(_), do: ""

  # -- shared helpers -------------------------------------------------------

  defp health do
    case request(%{method: "GET", url: @base <> "/healthz", headers: [], body: nil}) do
      {:ok, %{status: 200}} -> {:ok, :ready}
      {:ok, %{status: st}} -> {:error, {"health", "http-#{st}"}}
      {:error, _} = err -> err
    end
  end

  defp payload do
    uniq = System.system_time(:nanosecond)
    "popcorn-kv-#{uniq}"
  end

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp fmt(reason) when is_binary(reason), do: reason
  defp fmt(reason), do: inspect(reason)

  # Bodies may be raw binaries (non-JSON payloads) or best-effort-decoded
  # JSON terms (decode_body/1); slice renders either safely.
  defp slice(bin) when is_binary(bin) do
    if byte_size(bin) > 160, do: binary_part(bin, 0, 160) <> "...", else: bin
  end

  defp slice(other), do: inspect(other)

  # -- transport dispatch (single calculus, mirrors PopcornDemo.LiveMatrix) --

  # Browser transport when the Popcorn JS bridge is up; host requests ride
  # Transport.Httpc — same request/response map shape either way.
  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp request(%{method: method, url: url, headers: headers, body: body}) do
    # Browsers reject GET/HEAD with a body (even ""); omit body on GET.
    request = %{method: method, url: url, headers: headers, body: body}

    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  # PopcornDemo.Transport returns raw binary bodies; the walk steps
  # pattern-match on decoded JSON. Decode best-effort at THIS edge (the
  # transport deliberately does not decode).
  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other
end
