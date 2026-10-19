defmodule Smalt.Wire.ArmWireTest do
  @moduledoc """
  T2 wire tier — ARM control plane over real sockets.

  Boots the REAL supervision-tree children (Smalt.Store + Bandit hosting
  Smalt.ArmGateway.Router + Smalt.AmqpBroker) on ephemeral ports taken from the
  pinned Application env contract (Application.get_env(:smalt, :arm_port, 9443)),
  then drives real HTTP/1.1 over raw :gen_tcp (no HTTP client dependency).
  """

  use ExUnit.Case, async: false

  @sub_id "00000000-0000-0000-0000-000000000001"

  setup do
    ports = %{
      arm: get_free_port(),
      egress: get_free_port(),
      amqp: get_free_port()
    }

    stop_existing_tree()

    # save-prev/on_exit-restore discipline (test-isolation-leak gate):
    SmaltTest.Env.put_restored(
      arm_port: ports.arm,
      egress_port: ports.egress,
      amqp_port: ports.amqp,
      event_hubs_port: get_free_port()
    )

    children =
      [
        Smalt.Store,
        {Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: ports.arm}
      ] ++
        if Code.ensure_loaded?(Smalt.AmqpBroker) do
          [{Smalt.AmqpBroker, []}]
        else
          []
        end

    {:ok, sup} =
      Supervisor.start_link(children, strategy: :one_for_one, name: Smalt.WireSup)

    # Boot premise (court-x2 run-2 face): the STS faces POST /oauth2/... the
    # instant the supervisor links — Bandit's listener may not be ANSWERING
    # yet. Bounded poll on the real observable (the arm port accepting a real
    # TCP connection), typed flunk on timeout. No sleeps.
    SmaltTest.AssertEventually.eventually(
      fn ->
        case :gen_tcp.connect(~c"127.0.0.1", ports.arm, [:binary, active: false], 1000) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            {:ok, :listener_answering}

          {:error, reason} ->
            {:retry, {:connect, reason}}
        end
      end,
      deadline_ms: 10_000,
      observable: "arm wire listener answering on #{ports.arm}"
    )

    on_exit(fn ->
      stop_tree(sup)
      SmaltTest.Lifecycle.restore_app()
      SmaltTest.Lifecycle.ensure_store_up()
    end)

    {:ok, arm: ports.arm}
  end

  @tag :wire
  test "POST /oauth2/v2.0/token issues a bearer token over the wire", %{arm: port} do
    resp =
      http_request(port, "POST", "/oauth2/v2.0/token",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: "grant_type=client_credentials&client_id=wire-test&client_secret=wire-secret"
      )

    assert resp.status == 200

    body = Jason.decode!(resp.body)
    assert body["token_type"] == "Bearer"
    assert body["expires_in"] == 3600
    assert is_binary(body["access_token"]) and byte_size(body["access_token"]) > 0

    # The access_token is a real JWS: three dot-separated base64url segments.
    assert [_, _, _] = String.split(body["access_token"], ".")
  end

  @tag :wire
  test "mint -> Bearer GET /subscriptions 200; stripped token -> 401 + WWW-Authenticate (enforce)",
       %{
         arm: port
       } do
    # Wire tier must be a verify+challenge superset of the STS mint, not
    # mint-only: flip the real supervision tree into :enforce for this test.
    SmaltTest.Env.put_restored(auth_mode: :enforce)

    mint =
      http_request(port, "POST", "/oauth2/v2.0/token",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: "grant_type=client_credentials&client_id=wire-test&client_secret=wire-secret"
      )

    assert mint.status == 200
    %{"access_token" => token} = Jason.decode!(mint.body)
    assert is_binary(token) and byte_size(token) > 0

    authed =
      http_request(port, "GET", "/subscriptions?api-version=2021-04-01",
        headers: [{"authorization", "Bearer #{token}"}]
      )

    assert authed.status == 200
    assert is_list(Jason.decode!(authed.body)["value"])

    stripped = http_request(port, "GET", "/subscriptions?api-version=2021-04-01")

    assert stripped.status == 401
    assert stripped.headers =~ ~r/WWW-Authenticate:\s*Bearer/i
  end

  @tag :wire
  test "GET /subscriptions lists subscriptions over the wire", %{arm: port} do
    resp = http_request(port, "GET", "/subscriptions?api-version=2021-04-01")

    assert resp.status == 200
    body = Jason.decode!(resp.body)
    assert is_list(body["value"])
  end

  @tag :wire
  test "PUT resource group round-trips over the wire (201 then 200)", %{arm: port} do
    path = "/subscriptions/#{@sub_id}/resourceGroups/wire-rg?api-version=2023-07-01"

    create =
      http_request(port, "PUT", path,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"location" => "westus2"})
      )

    assert create.status == 201
    body = Jason.decode!(create.body)
    assert body["name"] == "wire-rg"
    assert body["location"] == "westus2"
    assert body["properties"]["provisioningState"] == "Succeeded"

    update =
      http_request(port, "PUT", path,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"location" => "westus2"})
      )

    assert update.status == 200

    get =
      http_request(
        port,
        "GET",
        "/subscriptions/#{@sub_id}/resourceGroups/wire-rg?api-version=2023-07-01"
      )

    assert get.status == 200
    assert Jason.decode!(get.body)["name"] == "wire-rg"
  end

  @tag :wire
  test "GET unknown resource group returns ARM error envelope 404 over the wire", %{arm: port} do
    resp =
      http_request(
        port,
        "GET",
        "/subscriptions/#{@sub_id}/resourceGroups/never-created?api-version=2023-07-01"
      )

    assert resp.status == 404
    body = Jason.decode!(resp.body)
    assert body["error"]["code"] == "ResourceGroupNotFound"
    assert is_binary(body["error"]["message"]) and byte_size(body["error"]["message"]) > 0
  end

  @tag :wire
  test "route-negative: unknown path returns ARM 404 error envelope over the wire", %{arm: port} do
    resp = http_request(port, "GET", "/definitely/not/a/route")

    assert resp.status == 404
    body = Jason.decode!(resp.body)
    assert body["error"]["code"] == "RouteNotFound"
    assert is_binary(body["error"]["message"]) and byte_size(body["error"]["message"]) > 0
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  # The AMQP broker tree under another lane does not always terminate cleanly
  # on Supervisor.stop; fall back to a hard kill so teardown never fails the
  # test run. Teardown only — assertions are never softened.
  defp stop_tree(sup) do
    try do
      Supervisor.stop(sup, :normal, 5000)
    catch
      _, _ -> Process.exit(sup, :kill)
    end
  end

  defp stop_existing_tree do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        for name <- [Smalt.Store, Smalt.AmqpBroker] do
          if pid = Process.whereis(name), do: GenServer.stop(pid)
        end

      sup ->
        SmaltTest.Lifecycle.stop_shared_tree()
    end
  end

  defp get_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp http_request(port, method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body, "")

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5000)

    header_lines =
      Enum.map_join(
        headers ++ [{"host", "127.0.0.1:#{port}"}, {"connection", "close"}],
        "\r\n",
        fn {k, v} -> "#{k}: #{v}" end
      )

    request =
      "#{method} #{path} HTTP/1.1\r\n" <>
        header_lines <>
        "\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body

    :ok = :gen_tcp.send(sock, request)
    raw = recv_all(sock)
    :gen_tcp.close(sock)
    parse_response(raw)
  end

  defp recv_all(sock) do
    case :gen_tcp.recv(sock, 0, 5000) do
      {:ok, data} -> [data | recv_all(sock)]
      {:error, :closed} -> []
    end
  end

  defp parse_response(raw) do
    raw = IO.iodata_to_binary(raw)
    [status_line, rest] = :binary.split(raw, "\r\n")
    [header_block, body] = :binary.split(rest, "\r\n\r\n")

    status =
      status_line |> String.split(" ") |> Enum.at(1) |> String.to_integer()

    %{status: status, headers: header_block, body: body}
  end
end
