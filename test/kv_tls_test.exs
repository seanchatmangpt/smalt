defmodule KvTlsTest do
  @moduledoc """
  TLS twin Key Vault mounting (lane 91/90 defect): the https twin (9444) must
  serve the Key Vault data-plane surface (/keys/*) in addition to the ARM
  gateway, because real Key Vault SDKs (python `azure-keyvault-keys`,
  `azure-security-keyvault-*`) refuse plaintext http.

  Real TLS round trips only. The `:ssl` client cannot anchor a self-signed
  server cert through its default verify path (erlang/otp#8057), so the client
  here performs the equivalent trust decision explicitly in a `verify_fun`:
  exact DER pin against the dev cert + `pkix_verify` RSA signature check +
  `pkix_verify_hostname` HTTPS name match. Real SDK clients (openssl-backed,
  e.g. python azure-core) do this natively: pass the dev cert via the SDK's
  `connection_verify=<dev-cert.pem>` keyword (the `AZURE_CORE_VERIFY` /
  `REQUESTS_CA_BUNDLE` env vars do not reach azure-identity's credential
  chain).
  """

  use ExUnit.Case, async: false

  @cert "tmp/dev-cert.pem"
  @key "tmp/dev-key.pem"

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(l)
    :ok = :gen_tcp.close(l)
    port
  end

  # Boot a per-test TLS twin on a freshly probed port using the same
  # Smalt.TLS.bandit_opts dev-cert path the application's twin uses, dispatching
  # through the same Smalt.Application.TlsTwinDispatch plug. The shared app tree
  # stays up (it owns the Store ETS tables the egress handlers write through).
  setup_all do
    {:ok, cert, _key} =
      case Smalt.TLS.ensure_dev_cert() do
        {:ok, c, k} -> {:ok, c, k}
        {:error, _} -> Smalt.TLS.write_dev_cert(@cert, @key)
      end

    [cert: Path.expand(cert)]
  end

  # A private twin per test on a freshly probed port (never a reused one): the
  # shared app tree may be stopped/restored by concurrent suites, which takes
  # any long-lived listener down with it; a per-test listener plus a
  # wait-for-ready loop removes the liveness race entirely.
  setup do
    {:ok, cert, _key} =
      case Smalt.TLS.ensure_dev_cert() do
        {:ok, c, k} -> {:ok, c, k}
        {:error, _} -> Smalt.TLS.write_dev_cert(@cert, @key)
      end

    {port, opts} = boot_twin(10)
    {:ok, sup} = Supervisor.start_link([{Bandit, opts}], strategy: :one_for_one)
    :persistent_term.put({__MODULE__, :twin}, %{port: port, opts: opts})
    :persistent_term.put({__MODULE__, :twin_sup}, sup)
    wait_twin(port, 50)

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 1000)
      catch
        _, _ -> Process.exit(sup, :kill)
      end
    end)

    [port: port, cert: Path.expand(cert)]
  end

  # Probe a fresh ephemeral port per attempt; retry on bind collision with a
  # concurrent lane's free-port window (the listener is closed before Bandit
  # binds it, so the port is only "free" until someone claims it).
  defp boot_twin(0), do: raise("could not bind a free TLS twin port after 10 attempts")

  defp boot_twin(tries) do
    port = free_port()
    opts = Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, port)

    if opts[:scheme] != :https, do: raise("dev TLS cert unavailable: #{inspect(opts)}")

    if port_free?(port), do: {port, opts}, else: boot_twin(tries - 1)
  end

  defp port_free?(port) do
    case :gen_tcp.listen(port, []) do
      {:ok, l} ->
        :gen_tcp.close(l)
        true

      {:error, _} ->
        false
    end
  end

  defp twin_alive?(port) do
    match?({:ok, _}, :gen_tcp.connect(~c"localhost", port, [], 250)) and
      (case :gen_tcp.connect(~c"localhost", port, [], 250) do
         {:ok, s} ->
           :gen_tcp.close(s)
           true

         _ ->
           false
       end)
  end

  defp wait_twin(_port, 0), do: :ok

  defp wait_twin(port, n) do
    if twin_alive?(port), do: :ok, else: (Process.sleep(100) && wait_twin(port, n - 1))
  end

  # -- real-TLS HTTP client ------------------------------------------------------

  defp https(ctx, method, path, body \\ nil, headers \\ []) do
    {:ok, pem} = File.read(ctx.cert)
    [{:"Certificate", pinned_der, :not_encrypted}] = :public_key.pem_decode(pem)
    pinned_cert = :public_key.pkix_decode_cert(pinned_der, :otp)
    match_fun = :public_key.pkix_verify_hostname_match_fun(:https)
    self_signed? = rsa_self_verify(pinned_der)

    verify_fun =
      {fn
         cert, {:bad_cert, :selfsigned_peer}, acc ->
           # OTP #8057: self-signed anchors are not matched by the default
           # verify path. Verify the peer ourselves. ssl hands the cert to the
           # fun as an already-decoded :otp tuple (re-encoding it for
           # pkix_verify fails ASN.1, so the signature check runs on the
           # pinned DER outside the fun).
           verified? =
             pkix_equal?(cert, pinned_cert) and self_signed? and
               :public_key.pkix_verify_hostname(cert, dns_id: ~c"localhost", match_fun: match_fun)

           if verified?, do: {:valid, acc}, else: {:fail, :untrusted_dev_cert}

         _cert, {:extension, _}, acc ->
           {:unknown, acc}

         _cert, :valid, acc ->
           {:valid, acc}
       end, :init}

    {:ok, sock} = connect_with_heal(ctx, pinned_der, verify_fun, match_fun, 5)

    req =
      [
        "#{method} #{path} HTTP/1.1",
        "Host: localhost",
        "Connection: close",
        "Content-Type: application/json"
      ] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end) ++
        case body do
          nil -> ["Content-Length: 0"]
          b -> ["Content-Length: #{byte_size(b)}"]
        end ++
        ["", body || ""]

    :ok = :ssl.send(sock, IO.iodata_to_binary(Enum.join(req, "\r\n")))
    data = recv_all(sock, [])
    :ssl.close(sock)

    parse_response(data)
  end

  # Concurrent suites stop/restore the shared tree, which can transiently kill
  # the private twin listener; heal and retry on connection refusal.
  defp connect_with_heal(ctx, pinned_der, verify_fun, match_fun, tries) do
    case ssl_connect(ctx, pinned_der, verify_fun, match_fun) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, reason} when reason in [:econnrefused, :eaddrnotavail, :closed] and tries > 1 ->
        restart_twin(ctx)
        Process.sleep(200)
        connect_with_heal(ctx, pinned_der, verify_fun, match_fun, tries - 1)

      {:error, reason} ->
        raise "tls connect failed: #{inspect(reason)}"
    end
  end

  defp ssl_connect(ctx, pinned_der, verify_fun, match_fun) do
    :ssl.connect(
      ~c"localhost",
      current_port(),
      [
        verify: :verify_peer,
        cacerts: [pinned_der],
        verify_fun: verify_fun,
        depth: 2,
        customize_hostname_check: [match_fun: match_fun],
        active: false
      ],
      5000
    )
  end

  # Heal by re-probing a fresh port, never reusing the failed listener's port.
  defp restart_twin(_ctx) do
    case :persistent_term.get({__MODULE__, :twin_sup}, nil) do
      sup when is_pid(sup) ->
        try do
          Supervisor.stop(sup, :normal, 5000)
        catch
          _, _ -> Process.exit(sup, :kill)
        end

      _ ->
        :ok
    end

    {port, opts} = boot_twin(10)
    {:ok, sup} = Supervisor.start_link([{Bandit, opts}], strategy: :one_for_one)
    :persistent_term.put({__MODULE__, :twin}, %{port: port, opts: opts})
    :persistent_term.put({__MODULE__, :twin_sup}, sup)
    wait_twin(port, 50)
  end

  defp current_port, do: :persistent_term.get({__MODULE__, :twin})[:port]

  # ssl may hand verify_fun the peer cert as a decoded :otp tuple or DER
  # binary; normalize to :otp. Pin by structural equality (subject RDN
  # sequence + SPKI key), not byte equality.
  defp cert_as_otp(otp) when elem(otp, 0) == :OTPCertificate, do: otp
  defp cert_as_otp(der) when is_binary(der), do: :public_key.pkix_decode_cert(der, :otp)

  defp pkix_equal?(cert, pinned_otp) do
    otp = cert_as_otp(cert)
    elem(otp, 1) |> elem(3) == elem(pinned_otp, 1) |> elem(3) and
      spki_key(otp) == spki_key(pinned_otp)
  rescue
    _ -> false
  end

  defp spki_key(otp) do
    {:RSAPublicKey, n, e} = elem(elem(otp, 1), 7) |> then(&elem(&1, 2))
    {n, e}
  end

  defp rsa_self_verify(der) when is_binary(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    {:RSAPublicKey, n, e} = elem(elem(otp, 1), 7) |> then(&elem(&1, 2))
    :public_key.pkix_verify(der, {:"RSAPublicKey", n, e})
  rescue
    _ -> false
  end

  defp recv_all(sock, acc) do
    case :ssl.recv(sock, 0, 5000) do
      {:ok, data} -> recv_all(sock, [acc | data])
      {:error, _} -> IO.iodata_to_binary(acc)
    end
  end

  defp parse_response(data) do
    # Pin the failure root: an empty/malformed response is the twin dying
    # mid-request (shared-tree churn), not a protocol result — say so.
    [header_block | rest] =
      String.split(data, "\r\n\r\n", parts: 2)
      |> case do
        ["" | _] ->
          raise "twin returned no HTTP response (#{byte_size(data)} bytes: #{inspect(data)})"

        parts ->
          parts
      end

    ["HTTP/1.1", status_code, _reason] = String.split(header_block, " ", parts: 3)

    body =
      case rest do
        [raw] -> strip_chunked_framing(raw)
        [] -> ""
      end

    {String.to_integer(status_code), body}
  end

  # Bandit answers with chunked transfer encoding; unwrap chunk sizes.
  defp strip_chunked_framing(raw) do
    if String.match?(raw, ~r/^[0-9a-fA-F]+\r\n/) do
      dechunk(raw)
    else
      raw
    end
  end

  defp dechunk(raw, acc \\ []) do
    case String.split(raw, "\r\n", parts: 2) do
      [size_line, rest] ->
        case Integer.parse(size_line, 16) do
          {0, _} ->
            IO.iodata_to_binary(Enum.reverse(acc))

          {n, _} ->
            <<chunk::binary-size(n), "\r\n", remainder::binary>> = rest
            dechunk(remainder, [chunk | acc])
        end

      _ ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end

  # Concurrent suites may stop/restore the shared app tree (docs/TEST_ISOLATION
  # contract), transiently racing Store.list's keys-then-get scan; retry 5xx.
  defp https_with_retry(ctx, method, path, tries) when is_integer(tries) do
    retry_5xx(ctx, method, path, nil, [], tries)
  end

  defp https_with_retry(ctx, method, path, body, headers, tries)
       when is_list(headers) and is_integer(tries) do
    retry_5xx(ctx, method, path, body, headers, tries)
  end

  defp retry_5xx(_ctx, _method, _path, _body, _headers, 0) do
    flunk("request kept returning 5xx after retries")
  end

  defp retry_5xx(ctx, method, path, body, headers, tries) do
    case https(ctx, method, path, body, headers) do
      {status, _} = result when status < 500 ->
        result

      {status, failure_body} ->
        Process.sleep(250)

        case retry_5xx(ctx, method, path, body, headers, tries - 1) do
          {ok_status, ok_body} when ok_status < 500 ->
            {ok_status, ok_body}

          {later_status, later_body} ->
            flunk(
              "twin kept failing: first #{status}: #{inspect(failure_body)}, " <>
                "final #{later_status}: #{inspect(later_body)}"
            )
        end
    end
  end

  # -- tests ----------------------------------------------------------------------

  test "key create + get + release over verified https", ctx do
    name = "kv-tls-#{System.unique_integer([:positive])}"

    {status, body} =
      https(ctx, "POST", "/keys/#{name}/create",
        Jason.encode!(%{
          "kty" => "RSA-HSM",
          "release_policy" => %{"claim" => "azure-compliant-cvm"}
        })
      )

    assert status == 200, "create returned #{status}: #{inspect(body)}"

    created = Jason.decode!(body)
    assert created["key"]["kty"] == "RSA-HSM"
    assert created["attributes"]["enabled"] == true

    {gstatus, gbody} = https(ctx, "GET", "/keys/#{name}")
    assert gstatus == 200, "get returned #{gstatus}: #{inspect(gbody)}"
    assert Jason.decode!(gbody)["key"]["kid"] == created["key"]["kid"]

    # Release is attestation-bound (MAA bearer): attest a baseline measurement,
    # then release with the signed token — over the same verified TLS channel.
    measurement = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    Smalt.Store.put(:smalt_attestation_baseline, measurement, measurement)

    {:ok, maa_token, _claims} =
      Smalt.Security.Attestation.attest_enclave(%{"measurement" => measurement})

    {status, body} =
      https_with_retry(ctx, "POST", "/keys/#{name}/release", Jason.encode!(%{}), [
        {"authorization", "Bearer " <> maa_token}
      ], 10)

    assert status == 200, "release returned #{status}: #{inspect(body)}"
    assert Jason.decode!(body)["status"] == "Released"
  end

  test "unknown key returns 404 envelope over verified https", ctx do
    {status, body} = https(ctx, "GET", "/keys/never-created-#{System.unique_integer()}")
    assert status == 404, "unknown key returned #{status}: #{inspect(body)}"
    assert Jason.decode!(body)["error"]["code"] == "KeyNotFound"
  end

  test "list keys over verified https includes the created key", ctx do
    name = "kv-tls-list-#{System.unique_integer([:positive])}"

    {cstatus, cbody} = https(ctx, "POST", "/keys/#{name}/create", Jason.encode!(%{"kty" => "oct"}))
    assert cstatus == 200, "create returned #{cstatus}: #{inspect(cbody)}"

    {status, body} = https_with_retry(ctx, "GET", "/keys", 10)
    assert status == 200, "list returned #{status}: #{inspect(body)}"
    decoded = Jason.decode!(body)
    names = if is_list(decoded), do: decoded, else: decoded["value"] || []
    assert Enum.any?(names, fn rec -> is_map(rec) and rec["kid"] =~ name end)
  end

  test "ARM routes still served by the same TLS twin (dispatch does not shadow ARM)", ctx do
    # arm-gateway lens cycle-7 landed the api-version gate on ARM verbs; the
    # stale row predated it. Real Azure form: /subscriptions?api-version=...
    {status, body} = https_with_retry(ctx, "GET", "/subscriptions?api-version=2021-04-01", 5)
    assert status == 200, "subscriptions returned #{status}: #{inspect(body)}"
    assert Jason.decode!(body)["value"]
  end

  test "metadata envelope still served by the TLS twin", ctx do
    {status, body} = https(ctx, "GET", "/metadata/endpoints")
    assert status in 200..299
    assert Jason.decode!(body)
  end

  test "handshake fails when the peer cert does not match the pinned identity", ctx do
    # Same pin + signature + name checks as the positive path, but the required
    # DNS name is one the dev cert does not carry — the client must refuse the
    # very same server cert the positive tests accept.
    match_fun = :public_key.pkix_verify_hostname_match_fun(:https)

    [{:"Certificate", pinned_der, :not_encrypted}] = :public_key.pem_decode(File.read!(ctx.cert))
    pinned_cert = :public_key.pkix_decode_cert(pinned_der, :otp)
    self_signed? = rsa_self_verify(pinned_der)

    verify_fun =
      {fn
         cert, {:bad_cert, :selfsigned_peer}, acc ->
           verified? =
             pkix_equal?(cert, pinned_cert) and self_signed? and
               :public_key.pkix_verify_hostname(cert, dns_id: ~c"evil.example.com",
                 match_fun: match_fun
               )

           if verified?, do: {:valid, acc}, else: {:fail, :untrusted_dev_cert}

         _cert, {:extension, _}, acc ->
           {:unknown, acc}

         _cert, :valid, acc ->
           {:valid, acc}
       end, :init}

    assert {:error, _} =
             :ssl.connect(
               ~c"localhost",
               ctx.port,
               [
                 verify: :verify_peer,
                 verify_fun: verify_fun,
                 cacerts: [pinned_der],
                 depth: 2,
                 customize_hostname_check: [match_fun: match_fun],
                 active: false
               ],
               5000
             )
  end
end
