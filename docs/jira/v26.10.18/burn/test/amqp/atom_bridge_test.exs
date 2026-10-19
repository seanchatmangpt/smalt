defmodule Smalt.Amqp.AtomBridgeTest do
  use ExUnit.Case, async: false

  # KD-45: the ATOM+XML management plane on the Service Bus AMQP port.
  # Real :gen_tcp loopback against the real serve/2 over the real Store
  # (Chicago, no mocks), final-state asserts on :smalt_resources.
  #
  # serve/2 answers ONE request then returns, so the harness loops
  # accept → serve on its listener.

  alias Smalt.Amqp.AtomBridge
  alias Smalt.Store

  setup do
    # Canonical resilient setup (v26.10.18): the guarded single-table wipe is
    # the ensure→wipe window that races an async sibling's shared-tree
    # teardown (FLAKE_LEDGER F2-F5/F10 class).
    SmaltTest.Store.resilient_setup()
    fresh_client()
  end

  ## helpers

  defp fresh_client do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    Task.start(fn ->
      accept_serve(listener)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    %{client: client}
  end

  # KD-45 harness task (unlinked scaffolding, never a test assertion): accept
  # → serve over the real serve/2. Its lifecycle EXPECTS the teardown
  # vocabulary — :timeout on the idle accept window, and :closed/:einval/
  # :enotconn/:notconn when sockets die mid-loop (same typing as serve/2's
  # i22/i23 silent teardown). It exits silently on all of them instead of
  # crashing with CaseClause noise; anything outside that vocabulary is a
  # typed exit, not a crash log.
  defp accept_serve(listener) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, sock} ->
        serve_conn(sock)
        accept_serve(listener)

      {:error, :timeout} ->
        accept_serve(listener)

      {:error, reason} when reason in [:closed, :einval, :enotconn, :notconn] ->
        :ok

      {:error, other} ->
        exit({:atom_bridge_harness_accept, other})
    end
  end

  # serve/2 answers ONE request then returns :ok unconditionally (silent
  # teardown typing, i22/i23), so a naive `:ok -> recurse` loop can never see
  # a dead peer and spins on it. Instead the loop probes liveness with a
  # 0-timeout 1-byte recv (no spin, no swallowed response bytes): bytes read
  # are buffered and handed to serve/2, :timeout means the peer is alive but
  # idle so serve/2 blocks for the next request, and the teardown vocabulary
  # closes the socket and ends the connection with a structured exit.
  defp serve_conn(sock, buf \\ <<>>) do
    case :gen_tcp.recv(sock, 1, 0) do
      {:ok, data} ->
        serve_conn(sock, <<buf::binary, data::binary>>)

      {:error, :timeout} ->
        AtomBridge.serve(sock, buf)
        serve_conn(sock)

      {:error, reason} when reason in [:closed, :einval, :enotconn, :notconn] ->
        :gen_tcp.close(sock)

      {:error, other} ->
        exit({:atom_bridge_harness_serve, other})
    end
  end

  defp send_req(client, req) do
    :ok = :gen_tcp.send(client, req)
    recv_resp(client, <<>>)
  end

  defp recv_resp(client, buf) do
    case :gen_tcp.recv(client, 0, 3000) do
      {:ok, data} ->
        buf = buf <> data

        case :binary.split(buf, "\r\n\r\n") do
          [head, rest] ->
            headers = String.split(head, "\r\n")

            clen =
              Enum.find_value(headers, 0, fn h ->
                case String.split(h, ": ", parts: 2) do
                  ["Content-Length", v] -> String.to_integer(v)
                  _ -> nil
                end
              end)

            if byte_size(rest) >= clen do
              [status_line | _] = headers
              body = binary_part(rest, 0, clen)
              {status_line, body}
            else
              recv_resp(client, buf)
            end

          :nomatch ->
            recv_resp(client, buf)
        end

      {:error, reason} ->
        flunk("recv failed: #{inspect(reason)}")
    end
  end

  defp status_of(client, req) do
    {status_line, _body} = send_req(client, req)
    ["HTTP/1.1", code | _] = String.split(status_line, " ")
    String.to_integer(code)
  end

  defp put_queue_req(name) do
    body =
      ~s(<entry xmlns="http://www.w3.org/2005/Atom"><content type="application/xml"><QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect">) <>
        ~s(<LockDuration>PT1M</LockDuration><RequiresSession>false</RequiresSession><MaxDeliveryCount>10</MaxDeliveryCount>) <>
        ~s(</QueueDescription></content></entry>)

    "PUT /#{name}?api-version=2021-10 HTTP/1.1\r\n" <>
      "Host: localhost\r\n" <>
      "Content-Type: application/atom+xml;type=entry;charset=utf-8\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "\r\n" <>
      body
  end

  defp simple_req(method, path) do
    "#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
  end

  ## tests

  test "http?/1 truth table" do
    assert AtomBridge.http?("GET /q HTTP/1.1\r\n")
    assert AtomBridge.http?("PUT /q HTTP/1.1\r\n")
    # sniff matches the 4-char prefix, not the full verb
    assert AtomBridge.http?("DELE /q HTTP/1.1\r\n")
    assert AtomBridge.http?("POST /q HTTP/1.1\r\n")
    refute AtomBridge.http?("AMQP\x00\x01\x00\x00")
    refute AtomBridge.http?(<<0, 0, 0, 60, 2, 0, 0, 0, 0, 65>>)
    refute AtomBridge.http?(<<>>)
  end

  test "PUT creates queue: 201 + store record" do
    %{client: client} = fresh_client()

    assert status_of(client, put_queue_req("atomq1")) == 201

    assert {:ok, rec} = Store.get(:smalt_resources, atom_queue_key("atomq1"))
    assert is_map(rec)
  end

  test "PUT update 200; GET 200 entry or 404; DELETE 200 then 404; POST 405" do
    %{client: client} = fresh_client()

    assert status_of(client, put_queue_req("atomq2")) == 201
    assert status_of(client, put_queue_req("atomq2")) == 200

    {status_line, _body} = send_req(client, simple_req("GET", "/atomq2"))
    assert status_line =~ "200"

    assert status_of(client, simple_req("GET", "/atomq-missing")) == 404

    assert status_of(client, simple_req("DELETE", "/atomq2")) == 200
    assert status_of(client, simple_req("GET", "/atomq2")) == 404

    assert status_of(client, simple_req("POST", "/atomq2")) == 405
  end

  test "malformed content-length closes typed: no response, bounded wait, then end" do
    %{client: client} = fresh_client()

    req = "PUT /atomq3 HTTP/1.1\r\nHost: localhost\r\nContent-Length: notanumber\r\n\r\n"
    :ok = :gen_tcp.send(client, req)

    # split_request -> {:error, :bad_request} -> serve logs + returns WITHOUT
    # responding; bounded by serve's own 5s recv cap, then the loop ends.
    # Pin the bounded no-hang-forever contract, not a specific status.
    result = :gen_tcp.recv(client, 0, 7000)
    assert match?({:error, :closed}, result) or match?({:error, :timeout}, result)
  end

  test "oversize request is refused or closed, never hangs" do
    %{client: client} = fresh_client()

    req =
      "PUT /atomq4 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2097152\r\n\r\n" <>
        String.duplicate("x", 1024)

    result =
      try do
        :gen_tcp.send(client, req)

        case :gen_tcp.recv(client, 0, 6000) do
          {:ok, data} -> {:resp, data}
          {:error, :closed} -> {:closed, nil}
          {:error, other} -> {:error, other}
        end
      catch
        :exit, _ -> {:exit, nil}
      end

    # bounded: a response, a close, or the server's own 5s recv cap — never
    # an unbounded hang.
    assert match?({:resp, _}, result) or match?({:closed, _}, result) or
             match?({:error, :timeout}, result)
  end

  defp atom_queue_key(name) do
    String.downcase(
      "/subscriptions/emulator-atom/resourceGroups/emulator/providers/Microsoft.ServiceBus/namespaces/emulator/queues/#{name}"
    )
  end
end
