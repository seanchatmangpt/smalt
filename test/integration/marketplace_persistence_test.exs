defmodule Smalt.Integration.MarketplacePersistenceTest do
  # CONVERGENCE lane V8 court: marketplace SaaS state must survive across
  # TCP CONNECTIONS, not just requests. Conn 1 resolves (purchase token via
  # the documented `x-ms-marketplace-token` header) and activates; the socket
  # is closed; conn 2 is a FRESH socket that must observe:
  #   * GET subscription  -> saasSubscriptionStatus: "Subscribed" + term
  #   * GET operations    -> the Activate operation, status "InProgress"
  #   * POST usageEvent   -> "Accepted" (meterable on the persisted state)
  #
  # The state lives in the named ETS table :smalt_marketplace_saas with a
  # long-lived heir (spawned holder) because the creating process is a Bandit
  # request process that dies with the connection. This court witnesses that
  # the heir actually outlives conn 1 — if the table died with the request
  # process, every conn-2 read would 404 and the court would flip red.

  use ExUnit.Case, async: false

  @moduletag :marketplace_saas

  alias Smalt.Store

  @publisher_token "loopback-publisher-secret"
  @purchase_token "marketplace-purchase-token-1"
  @sub_id "99999999-8888-7777-6666-555555555555"
  @purchase %{
    "id" => @sub_id,
    "subscriptionName" => "Persistence Court Seat",
    "publisherId" => "contoso",
    "offerId" => "offer1",
    "planId" => "silver",
    "quantity" => 7
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

  test "state written on conn 1 survives into a fresh conn 2", %{port: port} do
    # -- conn 1: resolve + activate, then the socket CLOSES --------------------
    conn1 = connect(port)

    {:ok, {{_, 200, _}, _, body}} =
      conn1
      |> send_raw(:post, "/saas/subscriptions/resolve?api-version=2018-08-31", resolve_headers())

    resolved = Jason.decode!(body)
    assert resolved["id"] == @sub_id
    assert resolved["subscription"]["saasSubscriptionStatus"] == "PendingFulfillmentStart"

    {:ok, {{_, 200, _}, _, ""}} =
      conn1
      |> send_raw(:post, "/saas/subscriptions/#{@sub_id}/activate?api-version=2018-08-31",
        auth_headers(),
        Jason.encode!(%{"planId" => "silver"})
      )

    :ok = :gen_tcp.close(conn1)

    # -- conn 2: a FRESH socket must observe conn 1's state --------------------
    conn2 = connect(port)

    {:ok, {{_, 200, _}, _, body}} =
      conn2
      |> send_raw(:get, "/saas/subscriptions/#{@sub_id}?api-version=2018-08-31", auth_headers())

    sub = Jason.decode!(body)
    assert sub["saasSubscriptionStatus"] == "Subscribed"
    assert sub["term"]["termUnit"] == "P1M"

    {:ok, {{_, 200, _}, _, body}} =
      conn2
      |> send_raw(:get, "/saas/subscriptions/#{@sub_id}/operations?api-version=2018-08-31",
        auth_headers()
      )

    assert [
             %{
               "action" => "Activate",
               "status" => "InProgress",
               "id" => op_id,
               "activityId" => activity_id
             }
           ] = Jason.decode!(body)["operations"]

    assert is_binary(activity_id) and activity_id != ""

    # meter against the persisted Subscribed state: Accepted
    usage = %{
      "resourceId" => @sub_id,
      "dimension" => "seatHours",
      "quantity" => 3,
      "planId" => "silver",
      "requestId" => "persistence-usage-1"
    }

    {:ok, {{_, 200, _}, _, body}} =
      conn2
      |> send_raw(:post, "/saas/usageEvent?api-version=2018-08-31", auth_headers(),
        Jason.encode!(usage)
      )

    assert %{"status" => "Accepted", "usageEventId" => event_id} = Jason.decode!(body)

    # and the usage written on conn 2 replays as Duplicate on ANOTHER fresh
    # conn 3 — the write side persists too, not just the read side.
    :ok = :gen_tcp.close(conn2)

    conn3 = connect(port)

    {:ok, {{_, 200, _}, _, body}} =
      conn3
      |> send_raw(:post, "/saas/usageEvent?api-version=2018-08-31", auth_headers(),
        Jason.encode!(usage)
      )

    assert %{"status" => "Duplicate", "usageEventId" => ^event_id} = Jason.decode!(body)

    :ok = :gen_tcp.close(conn3)
  end

  # conn 1 as a TRUE single TCP connection: resolve and activate on one
  # keep-alive socket (the pipe that wrote the state closes afterward).

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp connect(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false, nodelay: true])

    sock
  end

  defp auth_headers do
    [{"authorization", "Bearer " <> @publisher_token}]
  end

  defp resolve_headers do
    auth_headers() ++ [{"x-ms-marketplace-token", @purchase_token}]
  end

  # Raw HTTP/1.1 over :gen_tcp — real transport, no client-library gloss.
  # Keep-alive by default (so ONE socket can carry multiple requests — conn 1
  # does resolve AND activate on the same TCP connection); pass close?: true
  # for the last request on a connection.
  defp send_raw(sock, method, path, headers, body \\ "") do
    send_raw(sock, method, path, headers, body, [])
  end

  defp send_raw(sock, method, path, headers, body, opts) do
    closing? = Keyword.get(opts, :close?, false)

    hdrs =
      Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end) ++
        [
          "content-length: #{byte_size(body)}\r\n",
          "host: 127.0.0.1\r\n",
          if(closing?, do: "connection: close\r\n", else: "connection: keep-alive\r\n")
        ]

    req =
      "#{String.upcase(to_string(method))} #{path} HTTP/1.1\r\n" <> Enum.join(hdrs) <> "\r\n" <> body

    :ok = :gen_tcp.send(sock, req)
    {:ok, status, resp_headers, payload} = recv_response(sock)

    {:ok, {{status, status, nil}, resp_headers, payload}}
  end

  # Content-length-framed read: exact for keep-alive (no reliance on socket
  # close to delimit the body), falls back to read-to-close for
  # `connection: close` responses.
  defp recv_response(sock) do
    head = recv_until(sock, "\r\n\r\n", <<>>)
    [status_line | header_lines] = String.split(head, "\r\n")
    [head_rest, already] = String.split(head, "\r\n\r\n", parts: 2)

    headers =
      header_lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case String.split(line, ": ", parts: 2) do
          [k, v] -> [{String.downcase(k), v}]
          _ -> []
        end
      end)

    status =
      status_line
      |> String.split(" ")
      |> Enum.at(1)
      |> String.to_integer()

    content_length =
      case List.keyfind(headers, "content-length", 0) do
        {"content-length", n} -> String.to_integer(n)
        nil -> nil
      end

    {payload, _} = recv_exact(sock, content_length, already)

    # header names are lowercased by the parse; the assertions here only
    # read content-length, so the downcase is lossless for this court.
    {:ok, status, headers, payload}
  end

  defp recv_until(sock, pattern, acc) do
    case :binary.match(acc, pattern) do
      {_, _} ->
        # keep the full buffer (head + any body bytes already received)
        acc

      :nomatch ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_until(sock, pattern, acc <> data)
    end
  end

  defp recv_exact(_sock, nil, acc), do: {acc, :ok}

  defp recv_exact(_sock, 0, acc), do: {acc, :ok}

  defp recv_exact(sock, n, acc) when byte_size(acc) >= n do
    {binary_part(acc, 0, n), :ok}
  end

  defp recv_exact(sock, n, acc) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    recv_exact(sock, n, acc <> data)
  end
end
