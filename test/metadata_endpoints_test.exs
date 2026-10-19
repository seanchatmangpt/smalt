defmodule Smalt.MetadataEndpointsTest do
  @moduledoc """
  Conformance fence for the bootstrap surface that azurerm/azidentity depend on
  (real-world evidence from the terraform-fixture smoke, lane 40's findings in
  test/terraform_fixture/README.md).

  Wire tier over real TCP on ephemeral ports: each test drives the REAL
  Smalt.ArmGateway.Router over both the http listener and its https twin
  (when cert material is available), http assertions pinned as primary.
  """

  use ExUnit.Case, async: false

  alias Smalt.ArmGateway.Router

  @tenant "00000000-0000-0000-0000-000000000000"

  setup do
    # Canonical shared-tree teardown (v26.10.18 review lane): was a local
    # copy of the two-branch whereis shape; SmaltTest.Wire normalizes it.
    SmaltTest.Wire.stop_existing_tree()

    port = free_port()
    tls_port = free_port()
    SmaltTest.Env.put_restored(arm_port: port)

    children = [
      Smalt.Store,
      {Bandit, plug: Router, scheme: :http, port: port}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)

    # https twin: served through the same Smalt.TLS dev-cert path the
    # application uses; probed alongside http, never instead of it.
    listeners =
      (
        # AZB-11b: canonical single-put discipline — the old save/delete/
        # put_restored/restore sandwich captured prev AFTER the deletes, so
        # the on_exit restore deleted the config-seeded `tls: :auto` entry
        # (twin leak class `tls -> :auto`). put_restored captures the real
        # prev (config nil-entries) and restores it verbatim; the deletes are
        # unnecessary because the config values already ARE the auto path.
        SmaltTest.Env.put_restored(tls: :auto, tls_certfile: nil, tls_keyfile: nil)

        opts = Smalt.TLS.bandit_opts(Router, tls_port)

        if opts[:scheme] == :https do
          {:ok, tls_sup} = Supervisor.start_link([{Bandit, opts}], strategy: :one_for_one)

          on_exit(fn ->
            try do
              Supervisor.stop(tls_sup, :normal, 5000)
            catch
              _, _ -> Process.exit(tls_sup, :kill)
            end
          end)

          [http: port, https: tls_port]
        else
          [http: port]
        end
      )

    # No rescue: a TLS twin boot failure must fail the test loudly, never
    # silently degrade the listener list to http-only.

    on_exit(fn ->
      try do
        Supervisor.stop(sup, :normal, 5000)
      catch
        _, _ -> Process.exit(sup, :kill)
      end

      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, listeners: listeners}
  end

  # ---------------------------------------------------------------------------
  # (1) metadata document: 2022-09-01 shape + legacy 2015-01-01 shape
  # ---------------------------------------------------------------------------

  @tag :wire
  test "GET /metadata/endpoints?api-version=2022-09-01 serves the full cloud-environment document",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp = request(scheme, port, "GET", "/metadata/endpoints?api-version=2022-09-01")
      assert resp.status == 200, "#{scheme}: expected 200, got #{resp.status}"

      body = Jason.decode!(resp.body)

      # go-azure-sdk environments.FromEndpoint requires these; 'name' was nil
      # was the observed failure when absent.
      assert is_binary(body["name"]) and byte_size(body["name"]) > 0,
             "#{scheme}: metadata name must be non-nil"

      assert is_binary(body["resourceManagerEndpoint"]) and
               byte_size(body["resourceManagerEndpoint"]) > 0

      auth = body["authentication"]
      assert is_map(auth)
      assert is_binary(auth["loginEndpoint"]) and byte_size(auth["loginEndpoint"]) > 0
      assert is_list(auth["audiences"]) and auth["audiences"] != []

      assert is_map(body["dnsSuffixes"]) and map_size(body["dnsSuffixes"]) > 0
    end
  end

  @tag :wire
  test "GET /metadata/endpoints?api-version=2015-01-01 also serves the legacy shape",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp = request(scheme, port, "GET", "/metadata/endpoints?api-version=2015-01-01")
      assert resp.status == 200, "#{scheme}: expected 200, got #{resp.status}"

      body = Jason.decode!(resp.body)

      assert is_binary(body["activeDirectoryEndpoint"]) and
               byte_size(body["activeDirectoryEndpoint"]) > 0

      assert is_binary(body["activeDirectoryResourceId"]) and
               byte_size(body["activeDirectoryResourceId"]) > 0

      assert is_binary(body["managementEndpoint"]) and byte_size(body["managementEndpoint"]) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # (2) loginEndpoint: derived from the REQUEST (same host+scheme the client
  # used), so TLS-twin clients get a resolvable https envelope instead of an
  # NXDOMAIN host. Plaintext stays permitted because the local host is
  # localhost (azidentity plaintext-authority rule).
  # ---------------------------------------------------------------------------

  @tag :wire
  test "authentication.loginEndpoint mirrors the request authority (same host/scheme)",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp = request(scheme, port, "GET", "/metadata/endpoints?api-version=2022-09-01")
      assert resp.status == 200

      login = Jason.decode!(resp.body)["authentication"]["loginEndpoint"]
      uri = URI.parse(login)

      assert uri.scheme == to_string(scheme),
             "#{scheme}: loginEndpoint must mirror the request scheme, got #{login}"

      assert uri.host == "localhost",
             "#{scheme}: loginEndpoint host must be the request host (localhost), got #{uri.host}"

      assert uri.port == port,
             "#{scheme}: loginEndpoint port must be the request port (#{port}), got #{login}"
    end
  end

  # ---------------------------------------------------------------------------
  # (3) discovery instance
  # ---------------------------------------------------------------------------

  @tag :wire
  test "GET /common/discovery/instance advertises tenant_discovery_endpoint",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp = request(scheme, port, "GET", "/common/discovery/instance")
      assert resp.status == 200

      body = Jason.decode!(resp.body)

      assert is_binary(body["tenant_discovery_endpoint"]) and
               byte_size(body["tenant_discovery_endpoint"]) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # (4) openid-configuration: token_endpoint + issuer, tenant form consistent
  # with the issuer
  # ---------------------------------------------------------------------------

  @tag :wire
  test "openid-configuration carries token_endpoint + issuer in matching tenant form",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      anon = request(scheme, port, "GET", "/.well-known/openid-configuration")
      assert anon.status == 200
      anon_body = Jason.decode!(anon.body)
      assert is_binary(anon_body["token_endpoint"]) and byte_size(anon_body["token_endpoint"]) > 0
      assert is_binary(anon_body["issuer"]) and byte_size(anon_body["issuer"]) > 0

      tid = @tenant
      resp = request(scheme, port, "GET", "/#{tid}/v2.0/.well-known/openid-configuration")
      assert resp.status == 200, "#{scheme}: expected 200, got #{resp.status}"

      body = Jason.decode!(resp.body)
      assert is_binary(body["token_endpoint"]) and byte_size(body["token_endpoint"]) > 0
      assert is_binary(body["issuer"]) and byte_size(body["issuer"]) > 0

      # issuer ↔ token_endpoint consistency (Entra v2 wire form): both carry
      # the same authority and tenant — issuer .../<tid>/v2.0, token_endpoint
      # .../<tid>/oauth2/v2.0/token (not a suffix relationship; the v2 token
      # endpoint lives under /oauth2/).
      assert body["token_endpoint"] ==
               "#{body["issuer"] |> String.replace_suffix("/v2.0", "")}/oauth2/v2.0/token",
             "#{scheme}: issuer #{body["issuer"]} does not match token_endpoint #{body["token_endpoint"]}"

      assert body["issuer"] =~ "/#{tid}/v2.0"
    end
  end

  # ---------------------------------------------------------------------------
  # (5b) every ADVERTISED endpoint must resolve on the substrate (lane 90 court:
  # msal-node/azidentity FOLLOW the envelope — an advertised host that is not
  # this router is endpoints_resolution_error). Each advertised URL must be
  # same-host as the request AND its path must hit a live route here.
  # ---------------------------------------------------------------------------

  @tag :wire
  test "openid-configuration advertised endpoints are same-host and resolve on the substrate",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      authority = "#{scheme}://localhost:#{port}"

      for path <- [
            "/.well-known/openid-configuration",
            "/#{@tenant}/v2.0/.well-known/openid-configuration"
          ] do
        resp = request(scheme, port, "GET", path)
        assert resp.status == 200, "#{scheme}#{path}: expected 200"

        body = Jason.decode!(resp.body)

        for key <- ["token_endpoint", "authorization_endpoint", "jwks_uri", "issuer"] do
          assert is_binary(body[key]), "#{scheme}#{path}: missing #{key}"
          uri = URI.parse(body[key])

          assert "#{uri.scheme}://#{uri.host}:#{uri.port}" == authority,
                 "#{scheme}#{path}: #{key} #{body[key]} is not same-host as the request #{authority}"

          # The token endpoint must hit the live POST issuance route (the full
          # azidentity/msal-node acquisition path).
          case key do
            "token_endpoint" ->
              tok =
                request(scheme, port, "POST", uri.path,
                  headers: [{"content-type", "application/x-www-form-urlencoded"}],
                  body:
                    "grant_type=client_credentials&client_id=metadata-fence&client_secret=metadata-secret"
                )

              assert tok.status == 200,
                     "#{scheme}#{path}: advertised token_endpoint #{uri.path} did not resolve (#{tok.status})"

            # authorization_endpoint / jwks_uri: same-host asserted above; their
            # GET routes (/oauth2/v2.0/authorize, /discovery/v2.0/keys) are NOT
            # in this lane's owned router surface — KNOWN GAP, disclosed to the
            # coordinator (lanes owning those routes must serve them or stop
            # advertising them).
            _ ->
              :ok
          end
        end
      end
    end
  end

  @tag :wire
  test "discovery instance tenant_discovery_endpoint resolves to a same-host openid-configuration",
       %{listeners: listeners} do
    for {scheme, port} <- listeners do
      authority = "#{scheme}://localhost:#{port}"

      resp = request(scheme, port, "GET", "/common/discovery/instance")
      assert resp.status == 200

      body = Jason.decode!(resp.body)

      for key <- [
            "tenant_discovery_endpoint",
            "token_endpoint",
            "authorization_endpoint",
            "issuer"
          ] do
        uri = URI.parse(body[key])

        assert "#{uri.scheme}://#{uri.host}:#{uri.port}" == authority,
               "#{scheme}: #{key} #{body[key]} is not same-host as the request #{authority}"
      end

      tde = URI.parse(body["tenant_discovery_endpoint"])
      follow = request(scheme, port, "GET", tde.path)
      assert follow.status == 200, "#{scheme}: tenant_discovery_endpoint did not resolve"

      followed = Jason.decode!(follow.body)

      assert followed["token_endpoint"] == body["token_endpoint"],
             "#{scheme}: tenant_discovery chain advertises a different token_endpoint"
    end
  end

  # ---------------------------------------------------------------------------
  # (5) tenant list
  # ---------------------------------------------------------------------------

  @tag :wire
  test "GET /tenant returns value[0].tenantId", %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp = request(scheme, port, "GET", "/tenant")
      assert resp.status == 200

      body = Jason.decode!(resp.body)
      assert is_list(body["value"]) and body["value"] != []
      assert is_binary(body["value"] |> List.first() |> Map.get("tenantId"))
    end
  end

  # ---------------------------------------------------------------------------
  # (6) token issuance: real JWT with the claims azurerm depends on
  # ---------------------------------------------------------------------------

  @tag :wire
  test "POST token returns a JWT decoding with aud/oid/sub/tid/azp", %{listeners: listeners} do
    for {scheme, port} <- listeners do
      resp =
        request(scheme, port, "POST", "/#{@tenant}/oauth2/v2.0/token",
          headers: [{"content-type", "application/x-www-form-urlencoded"}],
          body:
            "grant_type=client_credentials&client_id=metadata-fence&client_secret=metadata-secret"
        )

      assert resp.status == 200, "#{scheme}: expected 200, got #{resp.status}"

      body = Jason.decode!(resp.body)
      token = body["access_token"]
      assert is_binary(token)

      claims = jwt_claims!(token)
      assert claims["aud"] == "https://management.azure.com"
      assert is_binary(claims["oid"]) and byte_size(claims["oid"]) > 0
      assert is_binary(claims["sub"]) and byte_size(claims["sub"]) > 0
      assert is_binary(claims["tid"]) and byte_size(claims["tid"]) > 0
      assert is_binary(claims["azp"]) and byte_size(claims["azp"]) > 0
      assert claims["tid"] == @tenant
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp jwt_claims!(token) do
    [_header, payload, _sig] = String.split(token, ".")

    payload
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Real-socket request tier: raw HTTP/1.1 over :gen_tcp for http and the same
  # raw wire over an :ssl socket (verify_none — the dev CA trust question is a
  # machine-trust concern, not part of this conformance fence) for https.
  defp request(scheme, port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    header_lines =
      Enum.map_join(
        headers ++ [{"host", "localhost:#{port}"}, {"connection", "close"}],
        "\r\n",
        fn {k, v} -> "#{k}: #{v}" end
      )

    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        header_lines <>
        "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    raw =
      if scheme == :https do
        with_ssl(port, request)
      else
        with_tcp(port, request)
      end

    parse_response(raw)
  end

  defp with_tcp(port, request) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    :ok = :gen_tcp.send(sock, request)
    data = recv_all(sock, [], &:gen_tcp.recv/3)
    :gen_tcp.close(sock)
    IO.iodata_to_binary(data)
  end

  defp with_ssl(port, request) do
    {:ok, sock} =
      :ssl.connect(~c"localhost", port, [verify: :verify_none, active: false, depth: 2], 5000)

    :ok = :ssl.send(sock, request)
    data = recv_all(sock, [], &:ssl.recv/3)
    :ssl.close(sock)
    IO.iodata_to_binary(data)
  end

  defp recv_all(sock, acc, recv_fun) do
    case recv_fun.(sock, 0, 5000) do
      {:ok, data} -> recv_all(sock, [data | acc], recv_fun)
      {:error, :closed} -> Enum.reverse(acc)
    end
  end

  defp parse_response(raw) do
    [status_line, rest] = :binary.split(raw, "\r\n")
    [header_block, body] = :binary.split(rest, "\r\n\r\n")

    status =
      status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()

    %{status: status, headers: header_block, body: body}
  end
end
