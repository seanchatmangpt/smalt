defmodule PopcornDemo.LiveCerts do
  @moduledoc """
  Key Vault certificate full-lifecycle walk (Fortune-5 cert lifecycle leg):
  CREATE a self-signed certificate on `popcorn-cert` (real request body per
  the Azure KV API), GET the create-LRO pending operation (wire-shape assert),
  LIST (>= 1 row carrying the cert), GET the cert, DELETE (soft delete),
  GET the deletedCertificate bundle, RECOVER it, then DELETE + PURGE to leave
  the vault clean. Chicago school — the only collaborators are the live smalt
  substrate (data plane 8443, STS 9443) and the wire.

  REST face (Smalt.DataPlane.Certificates; KD-104):

  - KD-15 KV challenge handshake (repo convention, same as LiveKV): the FIRST
    request is sent TOKENLESS; the server answers 401 with
    `www-authenticate: Bearer authorization="..." resource="..."`; the walk
    parses that header, mints a bearer at the STS named by the challenge's
    `authorization=` authority, and RESENDS with the bearer.
  - Create: POST /certificates/:name/create?api-version=7.4
      body {"policy":{"x509_props":{"subject":"CN=...","validity_months":12}}}
    -> 201 {id, cer(base64 DER), attributes, policy}
  - Pending LRO: GET /certificates/:name/pending -> 200
      {id, name, status: "completed", target, request_id, attributes}
  - List: GET /certificates -> 200 {"value":[{id,name,attributes}...]}
  - Get: GET /certificates/:name -> 200 (same shape as create)
  - Delete: DELETE /certificates/:name -> 200 deletedCertificate bundle
      {recoveryId, deletedDate, scheduledPurgeDate, ...}
  - Deleted get: GET /deletedcertificates/:name -> 200 bundle
  - Recover: POST /deletedcertificates/:name/recover -> 200 (live again)
  - Purge: POST /deletedcertificates/:name/purge -> 204 (permanent)

  Transport (ERRC-E2 dedupe, CLOSED — same calculus as `PopcornDemo.LiveMatrix`):
  all HTTP rides `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`). Caller content-type pins are preserved (Httpc honors a
  caller-set content-type). `decode_body/1` decodes best-effort at THIS
  module's edge; the base64-DER assertions are body-based and port cleanly.

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
  defp run_name, do: Process.get({__MODULE__, :resname}) || cert()
  defp cert, do: "popcorn-cert-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  @api_version "7.4"
  @retention_label "scheduledPurgeDate"

  @doc """
  Runs the walk. Returns:

  - `{:ok, "certs=OK(popcorn-cert:<last-stage>)"}`
  - `{:skip, "certs=SKIP(<loud reason>)"}`
  - `{:error, "certs=FAIL(<step>:<reason>)"}`
  """
  def run do
    Process.put({__MODULE__, :resname}, run_name())
    with {:ok, _} <- health(),
         {:ok, token} <- kv_challenge_token(),
         :ok <- preflight_clean(token) do
      stages =
        with :ok <- create_cert(token),
             :ok <- pending_completed(token),
             :ok <- list_has_cert(token),
             :ok <- get_cert(token),
             :ok <- delete_cert(token),
             :ok <- deleted_bundle(token),
             :ok <- recover_cert(token),
             :ok <- delete_cert(token),
             :ok <- purge_cert(token) do
          [
            :create,
            :pending,
            :list,
            :get,
            :delete,
            :"deleted-get",
            :recover,
            :"re-delete",
            :purge
          ]
        else
          {:error, _} = err -> err
        end

      case stages do
        stages when is_list(stages) -> {:ok, "certs=OK(#{run_name()}:#{List.last(stages)})"}
        {:error, _} = err -> err
      end
    else
      {:skip, reason} ->
        {:skip, "certs=SKIP(#{reason})"}

      {:error, {step, reason}} when is_binary(step) ->
        if fmt(reason) =~ "eprotonosupport" or fmt(reason) =~ "tcp_connect" do
          {:skip, "certs=SKIP(wasm-transport:#{step})"}
        else
          {:error, "certs=FAIL(#{step}:#{fmt(reason)})"}
        end
    end
  end

  # -- KD-15 challenge handshake ---------------------------------------------
  # KD-15 GAP CLOSED (W10-B): the 401's `www-authenticate` header comes
  # straight from the Transport response map (lowercase-string-keyed tuples).
  # No raw :gen_tcp remains in this module.

  # Send tokenless, take the 401 + WWW-Authenticate, resend with the bearer.
  defp kv_challenge_token do
    url = "#{@base}/certificates?api-version=#{@api_version}"
    req = %{method: "GET", url: url, headers: [], body: nil}

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

  # -- preflight: leave-over from a previous run would 409 the create -------

  defp preflight_clean(token) do
    case delete_req(token) do
      {:ok, %{status: 200}} ->
        # soft-deleted leftover: purge it so create can win
        purge_req(token)
        :ok

      {:ok, %{status: 404}} ->
        # maybe a soft-deleted leftover without a live row: purge best-effort
        _ = purge_req(token)
        :ok

      {:ok, %{status: st, body: body}} ->
        {:error, {"preflight", "http-#{st}:#{slice(body)}"}}

      {:error, reason} ->
        {:error, {"preflight", fmt(reason)}}
    end
  end

  # -- lifecycle steps -------------------------------------------------------

  defp create_cert(token) do
    req = %{
      method: "POST",
      url: "#{@base}/certificates/#{run_name()}/create?api-version=#{@api_version}",
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "policy" => %{
            "x509_props" => %{"subject" => "CN=popcorn-demo.smalt.local", "validity_months" => 12}
          }
        })
    }

    with {:ok, %{body: body}} <- step_req("create", req, 201) do
      case body do
        %{"cer" => cer, "attributes" => %{"recoveryLevel" => "Purgeable"}} = rec
        when is_binary(cer) and byte_size(cer) > 0 and is_map_key(rec, "id") ->
          # the DER must really be DER: structurally an ASN.1 SEQUENCE.
          # (was: :public_key.pem_encode framing check — replaced by a direct
          # 0x30 SEQUENCE tag + length assert, no :public_key/:crypto needed.)
          case Base.decode64(cer) do
            {:ok, der} ->
              if der_starts_sequence?(der),
                do: :ok,
                else: {:error, {"create", "cer-not-der-sequence"}}

            :error ->
              {:error, {"create", "cer-not-base64"}}
          end

        _ ->
          {:error, {"create", "wire-shape-missing-cer-or-attributes:#{slice(body)}"}}
      end
    end
  end

  defp pending_completed(token) do
    req = %{
      method: "GET",
      url: "#{@base}/certificates/#{run_name()}/pending?api-version=#{@api_version}",
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{body: body}} <- step_req("pending", req, 200) do
      case body do
        %{"status" => "completed", "target" => target, "request_id" => rid}
        when is_binary(target) and is_binary(rid) ->
          :ok

        %{"status" => other} ->
          {:error, {"pending", "expected-completed-got-#{inspect(other)}"}}

        _ ->
          {:error, {"pending", "wire-shape-missing-status-or-target:#{slice(body)}"}}
      end
    end
  end

  defp list_has_cert(token) do
    req = %{
      method: "GET",
      url: "#{@base}/certificates?api-version=#{@api_version}",
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{body: body}} <- step_req("list", req, 200) do
      case body do
        %{"value" => rows} when is_list(rows) ->
          if Enum.any?(rows, fn r -> r["name"] == run_name() end),
            do: :ok,
            else: {:error, {"list", "value-has-no-#{run_name()}:#{slice(body)}"}}

        _ ->
          {:error, {"list", "no-value-array:#{slice(body)}"}}
      end
    end
  end

  defp get_cert(token) do
    req = %{method: "GET", url: cert_url(), headers: auth_headers(token), body: nil}

    with {:ok, %{body: body}} <- step_req("get", req, 200) do
      case body do
        %{"cer" => cer} when is_binary(cer) and byte_size(cer) > 0 -> :ok
        _ -> {:error, {"get", "no-cer-field:#{slice(body)}"}}
      end
    end
  end

  defp delete_cert(token) do
    case delete_req(token) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: st, body: body}} -> {:error, {"delete", "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {"delete", fmt(reason)}}
    end
  end

  defp deleted_bundle(token) do
    req = %{
      method: "GET",
      url: "#{@base}/deletedcertificates/#{run_name()}?api-version=#{@api_version}",
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{body: body}} <- step_req("deleted-get", req, 200) do
      case body do
        %{"recoveryId" => rid, @retention_label => spd}
        when is_binary(rid) and is_integer(spd) ->
          now = System.system_time(:second)

          if spd > now,
            do: :ok,
            else: {:error, {"deleted-get", "scheduledPurgeDate-#{spd}-not-in-future"}}

        _ ->
          {:error, {"deleted-get", "no-recoveryId-or-scheduledPurgeDate:#{slice(body)}"}}
      end
    end
  end

  defp recover_cert(token) do
    req = %{
      method: "POST",
      url: "#{@base}/deletedcertificates/#{run_name()}/recover?api-version=#{@api_version}",
      headers: auth_headers(token) ++ [{"content-type", "application/json"}],
      body: "{}"
    }

    case step_req("recover", req, 200) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp purge_cert(token) do
    case purge_req(token) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: st, body: body}} -> {:error, {"purge", "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {"purge", fmt(reason)}}
    end
  end

  # -- request helpers --------------------------------------------------------

  defp cert_url, do: "#{@base}/certificates/#{run_name()}?api-version=#{@api_version}"

  defp delete_req(token),
    do: request(%{method: "DELETE", url: cert_url(), headers: auth_headers(token), body: nil})

  defp purge_req(token),
    do:
      request(%{
        method: "POST",
        url: "#{@base}/deletedcertificates/#{run_name()}/purge?api-version=#{@api_version}",
        headers: auth_headers(token) ++ [{"content-type", "application/json"}],
        body: "{}"
      })

  defp step_req(step, req, want) do
    case request(req) do
      {:ok, %{status: ^want} = resp} -> {:ok, resp}
      {:ok, %{status: st, body: body}} -> {:error, {step, "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {step, fmt(reason)}}
    end
  end

  # -- shared helpers ---------------------------------------------------------

  defp health do
    case request(%{method: "GET", url: @base <> "/healthz", headers: [], body: nil}) do
      {:ok, %{status: 200}} ->
        {:ok, :ready}

      {:ok, %{status: st}} ->
        {:error, {"health", "http-#{st}"}}

      {:error, {:httpc, reason}} ->
        {:skip, "data-plane-8443-unreachable:#{inspect(reason)}"}

      {:error, _} = err ->
        err
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  # Structural DER check: X.509 Certificate = ASN.1 SEQUENCE (tag 0x30) with a
  # short-form (< 128 bytes) or long-form (0x81..) definite length. Pure binary
  # pattern-matching — no :public_key / :crypto.
  defp der_starts_sequence?(<<0x30, len, rest::binary>>) when len < 0x80,
    do: byte_size(rest) == len

  defp der_starts_sequence?(<<0x30, 0x81, len, rest::binary>>), do: byte_size(rest) == len

  defp der_starts_sequence?(<<0x30, 0x82, hi, lo, rest::binary>>),
    do: byte_size(rest) == hi * 256 + lo

  defp der_starts_sequence?(_), do: false

  defp fmt(reason) when is_binary(reason), do: reason
  defp fmt(reason), do: inspect(reason)

  # Bodies may be raw binaries (non-JSON payloads) or best-effort-decoded
  # JSON terms (decode_body/1); slice renders either safely.
  defp slice(bin) when is_binary(bin) do
    if byte_size(bin) > 160, do: binary_part(bin, 0, 160) <> "...", else: bin
  end

  defp slice(other), do: inspect(other)

  # -- transport dispatch (single calculus, mirrors PopcornDemo.LiveMatrix) ----

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
