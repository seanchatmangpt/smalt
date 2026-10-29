defmodule Smalt.Integration.MarketplaceSaasTest do
  # AZURE-FIDELITY lane 8 court: the Microsoft-documented Marketplace SaaS
  # fulfillment face (/saas/*) over REAL TCP — Bandit + Smalt.EgressRouter +
  # raw :gen_tcp HTTP/1.1, no test-adapter conns, no mocks.
  #
  # Gates:
  #   1. resolve -> activate -> meter lifecycle end-to-end in-process
  #      (resolve payload shape, PendingFulfillmentStart, activate 200 empty,
  #      subscription flips to Subscribed, meter Accepted, requestId replay
  #      Duplicate, operations list carries the Activate op, PATCH Success,
  #      second PATCH 409 terminal).
  #   2. bad token law: missing x-ms-marketplace-token 400; unknown token 404;
  #      missing bearer 401; wrong bearer 401.
  #   3. unknown subscription 404 (activate / get / meter).
  #   4. state machine: activate-twice 409 Conflict; meter before activate 409
  #      ClientConflict; invalid PATCH status 400.
  #   5. default-on (G2 flip, 2026-10-25): the checked-in config.exs default is
  #      enabled: true and the face answers the wire with exactly that default
  #      tuple; with an EXPLICIT enabled: false the conn falls through to the
  #      pre-lane routing (blob catch-all), never the /saas JSON face.

  use ExUnit.Case, async: false

  @moduletag :marketplace_saas

  alias Smalt.Store

  @publisher_token "loopback-publisher-secret"
  @purchase_token "marketplace-purchase-token-1"
  @sub_id "11111111-2222-3333-4444-555555555555"
  @purchase %{
    "id" => @sub_id,
    "subscriptionName" => "Contoso Cloud Solution",
    "publisherId" => "contoso",
    "offerId" => "offer1",
    "planId" => "silver",
    "quantity" => 20
  }

  setup_all do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, _server} = Bandit.start_link(plug: Smalt.EgressRouter, scheme: :http, port: port)

    %{port: port}
  end

  setup context do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # table isolation between tests (named public ETS survives the suite)
    if :ets.info(:smalt_marketplace_saas) != :undefined do
      :ets.delete_all_objects(:smalt_marketplace_saas)
    end

    Application.put_env(:smalt, :marketplace_saas,
      enabled: true,
      publisher_token: @publisher_token,
      tokens: %{@purchase_token => @purchase}
    )

    on_exit(fn -> Application.delete_env(:smalt, :marketplace_saas) end)

    %{port: context.port}
  end

  # -- Gate 1: resolve -> activate -> meter lifecycle ---------------------------

  test "resolve -> activate -> meter lifecycle end-to-end", %{port: port} do
    # resolve: documented payload, PendingFulfillmentStart
    {:ok, {{_, 200, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        resolve_headers()
      )

    resolved = Jason.decode!(body)

    assert resolved["id"] == @sub_id
    assert resolved["offerId"] == "offer1"
    assert resolved["planId"] == "silver"
    assert resolved["quantity"] == 20
    assert resolved["subscription"]["saasSubscriptionStatus"] == "PendingFulfillmentStart"

    # activate: 200 with EMPTY body (documented)
    {:ok, {{_, 200, _}, _, ""}} =
      request(:post, port, "/saas/subscriptions/#{@sub_id}/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "silver"})
      )

    # get subscription: Subscribed, meterable
    {:ok, {{_, 200, _}, _, body}} =
      request(:get, port, "/saas/subscriptions/#{@sub_id}?api-version=2018-08-31", auth_headers())

    sub = Jason.decode!(body)
    assert sub["saasSubscriptionStatus"] == "Subscribed"
    assert sub["term"]["termUnit"] == "P1M"

    # operations list carries the minted Activate operation (InProgress)
    {:ok, {{_, 200, _}, _, body}} =
      request(:get, port, "/saas/subscriptions/#{@sub_id}/operations?api-version=2018-08-31",
        auth_headers()
      )

    ops = Jason.decode!(body)
    assert [%{"action" => "Activate", "status" => "InProgress", "id" => op_id}] = ops["operations"]
    assert ops["operations"] |> hd() |> Map.has_key?("activityId")

    # meter: Accepted, and the requestId replay answers Duplicate
    usage = %{
      "resourceId" => @sub_id,
      "dimension" => "seatHours",
      "quantity" => 5,
      "planId" => "silver",
      "requestId" => "usage-req-1"
    }

    {:ok, {{_, 200, _}, _, body}} =
      request(:post, port, "/saas/usageEvent?api-version=2018-08-31", auth_headers(),
        Jason.encode!(usage)
      )

    assert %{"status" => "Accepted", "usageEventId" => event_id} = Jason.decode!(body)

    {:ok, {{_, 200, _}, _, body}} =
      request(:post, port, "/saas/usageEvent?api-version=2018-08-31", auth_headers(),
        Jason.encode!(usage)
      )

    assert %{"status" => "Duplicate", "usageEventId" => ^event_id} = Jason.decode!(body)

    # PATCH the operation Success; the second PATCH is a terminal-state 409
    {:ok, {{_, 200, _}, _, body}} =
      request(
        :patch,
        port,
        "/saas/subscriptions/#{@sub_id}/operations/#{op_id}?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"status" => "Success"})
      )

    assert Jason.decode!(body) == %{"operationStatus" => "Success"}

    {:ok, {{_, 409, _}, _, body}} =
      request(
        :patch,
        port,
        "/saas/subscriptions/#{@sub_id}/operations/#{op_id}?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"status" => "Failure"})
      )

    assert Jason.decode!(body)["error"]["code"] == "Conflict"
  end

  # -- Gate 2: bad token law ----------------------------------------------------

  test "resolve with a missing marketplace token is a documented 400", %{port: port} do
    {:ok, {{_, 400, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31", auth_headers(), "")

    assert Jason.decode!(body)["error"]["code"] == "InvalidArgument"
  end

  test "resolve with an unknown marketplace token is a documented 404", %{port: port} do
    {:ok, {{_, 404, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        auth_headers() ++ [{"x-ms-marketplace-token", "no-such-purchase-token"}]
      )

    assert Jason.decode!(body)["error"]["code"] == "SubscriptionNotFound"
  end

  test "resolve with a missing or wrong bearer is a documented 401", %{port: port} do
    {:ok, {{_, 401, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31", [],
        ""
      )

    assert Jason.decode!(body)["error"]["code"] == "Unauthorized"

    {:ok, {{_, 401, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        [{"authorization", "Bearer wrong-secret"}, {"x-ms-marketplace-token", @purchase_token}]
      )

    assert Jason.decode!(body)["error"]["code"] == "Unauthorized"
  end

  # -- Gate 3: unknown subscription ----------------------------------------------

  test "activate on an unknown subscription is a documented 404", %{port: port} do
    {:ok, {{_, 404, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/no-such-sub/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "silver"})
      )

    assert Jason.decode!(body)["error"]["code"] == "SubscriptionNotFound"
  end

  # -- Gate 4: state machine ------------------------------------------------------

  test "activate twice is an illegal transition (409 Conflict)", %{port: port} do
    resolve_and_activate(port)

    # second activate on a Subscribed subscription: illegal transition
    {:ok, {{_, 409, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/#{@sub_id}/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "silver"})
      )

    assert Jason.decode!(body)["error"]["code"] == "Conflict"
  end

  test "meter before activate is the documented 409 ClientConflict", %{port: port} do
    {:ok, {{_, 200, _}, _, _}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        resolve_headers()
      )

    {:ok, {{_, 409, _}, _, body}} =
      request(:post, port, "/saas/usageEvent?api-version=2018-08-31", auth_headers(),
        Jason.encode!(%{
          "resourceId" => @sub_id,
          "dimension" => "seatHours",
          "quantity" => 1,
          "requestId" => "usage-req-early"
        })
      )

    assert Jason.decode!(body)["error"]["code"] == "ClientConflict"
  end

  test "activate with a mismatched planId is a documented 400", %{port: port} do
    resolve(port)

    {:ok, {{_, 400, _}, _, body}} =
      request(:post, port, "/saas/subscriptions/#{@sub_id}/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "gold"})
      )

    assert Jason.decode!(body)["error"]["code"] == "BadRequest"
  end

  test "PATCH with an invalid status value is a documented 400", %{port: port} do
    :ok = resolve_and_activate(port)

    {:ok, {{_, 200, _}, _, body}} =
      request(:get, port, "/saas/subscriptions/#{@sub_id}/operations?api-version=2018-08-31",
        auth_headers()
      )

    [%{"id" => op_id}] = Jason.decode!(body)["operations"]

    {:ok, {{_, 400, _}, _, body}} =
      request(
        :patch,
        port,
        "/saas/subscriptions/#{@sub_id}/operations/#{op_id}?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"status" => "Bogus"})
      )

    assert Jason.decode!(body)["error"]["code"] == "InvalidArgument"
  end

  # -- Gate 5: default-on law + explicit-off fallthrough ----------------------------

  test "the checked-in default enables the plane (config.exs pin)", _ do
    # G2 flip: the checked-in default tuple must be enabled: true. Pinned
    # against the config file itself — Application.put_env in setup shadows
    # the persisted value, so we read the source of truth directly.
    config_path =
      __DIR__
      |> Path.join("../../config/config.exs")
      |> Path.expand()

    assert File.exists?(config_path)

    default_line =
      config_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(fn line ->
        String.contains?(line, "config :smalt, :marketplace_saas")
      end)

    assert default_line =~ ~r/enabled:\s*true/
  end

  test "with the file's exact default tuple the /saas face answers the wire", %{port: port} do
    # enabled: true, publisher_token: nil, tokens: %{} — the shipped default.
    Application.put_env(:smalt, :marketplace_saas,
      enabled: true,
      publisher_token: nil,
      tokens: %{}
    )

    # No publisher_token configured = open, loopback-only discipline; with no
    # tokens minted an unknown purchase token answers the documented 404, not
    # RouteNotFound — the /saas face owns the conn.
    {:ok, {{_, 404, _}, headers, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31", [
        {"x-ms-marketplace-token", "no-such-purchase-token"}
      ])

    assert Jason.decode!(body)["error"]["code"] == "SubscriptionNotFound"
    refute Enum.any?(headers, fn {k, v} ->
             String.downcase(k) == "x-ms-error-code" and v == "RouteNotFound"
           end)
  end

  test "with the plane explicitly disabled the /saas conn falls through to the pre-lane routing", %{
    port: port
  } do
    Application.put_env(:smalt, :marketplace_saas,
      enabled: false,
      publisher_token: @publisher_token,
      tokens: %{}
    )

    {:ok, {{_, status, _}, headers, body}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        resolve_headers()
      )

    # pre-lane behavior on this seat: the main router's typed RouteNotFound
    # 404 (x-ms-error-code header), never the /saas JSON face
    assert status == 404
    refute String.contains?(body, "saasSubscriptionStatus")

    assert Enum.any?(headers, fn {k, v} ->
             String.downcase(k) == "x-ms-error-code" and v == "RouteNotFound"
           end)
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp resolve(port) do
    {:ok, {{_, 200, _}, _, _}} =
      request(:post, port, "/saas/subscriptions/resolve?api-version=2018-08-31",
        resolve_headers()
      )

    :ok
  end

  defp resolve_and_activate(port) do
    :ok = resolve(port)

    {:ok, {{_, 200, _}, _, ""}} =
      request(:post, port, "/saas/subscriptions/#{@sub_id}/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "silver"})
      )

    :ok
  end

  defp auth_headers do
    [{"authorization", "Bearer " <> @publisher_token}]
  end

  defp resolve_headers do
    auth_headers() ++ [{"x-ms-marketplace-token", @purchase_token}]
  end

  # Raw HTTP/1.1 over :gen_tcp — real transport, no client-library gloss.
  defp request(method, port, path, headers, body \\ "") do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false, nodelay: true])

    hdrs =
      Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end) ++
        ["content-length: #{byte_size(body)}\r\n", "host: 127.0.0.1\r\n", "connection: close\r\n"]

    req = "#{String.upcase(to_string(method))} #{path} HTTP/1.1\r\n" <> Enum.join(hdrs) <> "\r\n" <> body

    :ok = :gen_tcp.send(sock, req)
    resp = recv_all(sock, <<>>)
    :ok = :gen_tcp.close(sock)

    [status_line | rest] = String.split(resp, "\r\n", parts: 2)
    [head, payload] = String.split(hd(rest), "\r\n\r\n", parts: 2)

    status =
      status_line
      |> String.split(" ")
      |> Enum.at(1)
      |> String.to_integer()

    headers =
      head
      |> String.split("\r\n")
      |> Enum.map(fn line ->
        [k, v] = String.split(line, ": ", parts: 2)
        {k, v}
      end)

    {:ok, {{status, status, nil}, headers, payload}}
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
