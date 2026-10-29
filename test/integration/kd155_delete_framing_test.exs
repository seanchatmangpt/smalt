# KD-COVERS: KD-155 — two-layer defect on the SB management (ATOM) DELETE face.
#
# Layer 1 (already closed by the method-word sniff): atom_bridge http?/1 matched
# fixed 3/4-byte prefixes ("DELE", "PATC", "OPTI") + space, so the 6-byte
# methods DELETE / PATCH / OPTIONS fell through to AMQP header negotiation and
# the client read an AMQP error frame (node: HPE_INVALID_CONSTANT).
#
# Layer 2 (this lane, failing-first — fix lands after the witness probe
# confirms): dispatch("DELETE", ...) answers 200 OK with a full ATOM entry
# body (content-length + body bytes on a delete). Real Azure Service Bus
# returns **204 No Content with an empty body** for
# `DELETE /{queue}?api-version=...` on the ATOM management endpoint —
# source: Azure Service Bus REST, "Delete Queue"
# (learn.microsoft.com/en-us/rest/api/servicebus/delete-queue: status code
# 204, no response body). Per RFC 9110 §6.4.5 + §8.6 a 204 is terminated by
# the end of its header section, carries no content, and MUST NOT carry
# Content-Length.
#
# Framing-defect class: body-on-delete. A 200 + content-length + body on a
# DELETE is the shape the node admin client's response framing path
# mis-handles (HPE_INVALID_CONSTANT surface); Azure's wire answer is the
# bodyless 204.
#
# Chicago discipline: real TCP — a real Smalt.Amqp.Listener on an ephemeral
# loopback port, real Smalt.Amqp.Connection header sniff, real ATOM dispatch
# against a real Smalt.Store. No mocks. The wire assertions are on the raw
# response BYTES, never interactions.
#
# Context: solo (integration tier, in-process wire faces).

Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule Integration.Kd155DeleteFramingTest do
  use ExUnit.Case, async: false
  alias Smalt.Amqp.AtomBridge
  alias Smalt.Amqp.Listener
  alias Smalt.Store

  @queue "kd155-q"

  setup do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    sup_name = Module.concat(__MODULE__, ConnSup)
    {:ok, _} =
      DynamicSupervisor.start_link(name: sup_name)

    {:ok, _} =
      Listener.start_link(
        {:sb, 0, name: Module.concat(__MODULE__, ListenerSb), conn_sup: sup_name}
      )

    port = Listener.port(Module.concat(__MODULE__, ListenerSb))

    on_exit(fn ->
      if :ets.info(:smalt_sb_messages) != :undefined do
        for {k, _} <- :ets.tab2list(:smalt_sb_messages),
            is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), @queue) do
          :ets.delete(:smalt_sb_messages, k)
        end
      end
    end)

    {:ok, port: port}
  end

  # -- Unit face: the sniff itself ----------------------------------------------

  test "http?/1 admits the full HTTP method vocabulary" do
    for method <- ~w(GET PUT POST DELETE HEAD PATCH OPTIONS MERGE) do
      assert AtomBridge.http?(method <> " /path HTTP/1.1\r\nHost: x\r\n\r\n"),
             "expected #{method} request line to be sniffed as HTTP"
    end
  end

  test "http?/1 refuses non-HTTP bytes (AMQP/SASL headers, garbage)" do
    refute AtomBridge.http?("AMQP\x00\x01\x00\x00")
    refute AtomBridge.http?("AMQP\x03\x01\x00\x00")
    refute AtomBridge.http?(<<0x00, 0x53, 0x14, 0xC0>>)
    refute AtomBridge.http?("GARBAGE")
    refute AtomBridge.http?("DELE")
  end

  # -- Wire face: real socket, real broker port ---------------------------------

  test "DELETE on the SB port answers the real-Azure shape: 204 No Content, empty body",
       %{port: port} do
    sock = open(port)

    body =
      ~s(<?xml version="1.0" encoding="utf-8"?><entry xmlns="http://www.w3.org/2005/Atom">) <>
        ~s(<content type="application/xml"><QueueDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect">) <>
        ~s(<LockDuration>PT45S</LockDuration><MaxDeliveryCount>7</MaxDeliveryCount>) <>
        ~s(</QueueDescription></content></entry>)

    put_req = """
    PUT /#{@queue}?api-version=2021-05 HTTP/1.1\r
    Content-Type: application/atom+xml\r
    Content-Length: #{byte_size(body)}\r
    \r
    """ <> body

    :ok = :gen_tcp.send(sock, put_req)
    {:ok, put_resp} = recv_until_headers(sock)
    assert String.starts_with?(put_resp, "HTTP/1.1 201")

    # The defect under test: 200 + ATOM body instead of Azure's 204 No
    # Content. The bridge serves one request per connection (serve/2 ->
    # {:closed}), so the DELETE leg opens a fresh connection like the real
    # SDK does.
    :gen_tcp.close(sock)
    sock = open(port)

    delete_req =
      "DELETE /#{@queue}?api-version=2021-05 HTTP/1.1\r\n" <>
        "Content-Length: 0\r\n\r\n"

    :ok = :gen_tcp.send(sock, delete_req)
    {:ok, resp, drained} = recv_until_headers_and_close(sock)

    [status_line | header_lines] = String.split(resp, "\r\n")
    headers = headers_map(header_lines)

    # Real Azure: status code 204 (Delete Queue REST doc). Fails on current
    # code, which sends "HTTP/1.1 200 OK".
    assert status_line == "HTTP/1.1 204 No Content",
           "expected 204 No Content for queue DELETE, got: #{inspect(status_line)}"

    # RFC 9110 §8.6: a server MUST NOT send Content-Length in a 204.
    refute Map.has_key?(headers, "content-length"),
           "204 must not carry content-length, got: #{inspect(headers)}"

    # No body bytes on the wire after the header section (204 is terminated
    # by the header block; the bridge closes with `connection: close`).
    assert drained == <<>>,
           "204 response carried body bytes after the header section: #{inspect(drained)}"

    # Real state, not interaction: the queue row is actually gone.
    refute match?(
             {:ok, _},
             Store.get(
               :smalt_resources,
               "/subscriptions/emulator-atom/resourcegroups/emulator/providers/microsoft.servicebus/namespaces/emulator/queues/#{@queue}"
             )
           )

    :gen_tcp.close(sock)
  end

  test "DELETE of a missing queue is still HTTP (404), never an AMQP frame",
       %{port: port} do
    sock = open(port)

    :ok =
      :gen_tcp.send(sock, "DELETE /kd155-absent?api-version=2021-05 HTTP/1.1\r\nContent-Length: 0\r\n\r\n")

    {:ok, resp} = recv_until_headers(sock)
    assert String.starts_with?(resp, "HTTP/1.1 404")
    :gen_tcp.close(sock)
  end

  # AMQP regression: a real AMQP header on the same port still negotiates the
  # AMQP protocol, not the ATOM bridge.
  test "AMQP header on the SB port still negotiates AMQP", %{port: port} do
    sock = open(port)

    :ok = :gen_tcp.send(sock, "AMQP\x00\x01\x00\x00")
    {:ok, echo} = :gen_tcp.recv(sock, 0, 5_000)
    assert String.starts_with?(echo, "AMQP")
    :gen_tcp.close(sock)
  end

  # -- Helpers -------------------------------------------------------------------

  defp open(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    sock
  end

  defp recv_until_headers(sock, buf \\ <<>>) do
    case :binary.split(buf, "\r\n\r\n") do
      [_, _] -> {:ok, buf}
      _ ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} -> recv_until_headers(sock, <<buf::binary, data::binary>>)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Header block plus any stray body bytes; the server closes after
  # `connection: close`, so recv ends with :closed — a bodyless 204 has no
  # bytes between the header terminator and the close.
  # Reads the header block exactly once past peer-close: a second recv after
  # the port auto-closed yields :enotconn (harness artifact, not wire bytes),
  # so the drained tail is returned alongside the headers.
  defp recv_until_headers_and_close(sock) do
    case recv_until_headers(sock) do
      {:ok, headers} ->
        case recv_exhausted(sock) do
          {:ok, extra} -> {:ok, headers <> extra, extra}
          {:error, :closed} -> {:ok, headers, <<>>}
          {:error, other} -> {:error, other, <<>>}
        end

      err ->
        err
    end
  end

  defp recv_exhausted(sock, acc \\ <<>>) do
    case :gen_tcp.recv(sock, 0, 1_000) do
      {:ok, data} -> recv_exhausted(sock, <<acc::binary, data::binary>>)
      {:error, :closed} -> {:ok, acc}
      {:error, :timeout} -> {:ok, acc}
      {:error, other} -> {:error, other}
    end
  end

  defp headers_map(lines) do
    for line <- lines, line != "", split = :binary.split(line, ":"), match?([_, _], split) do
      [k, v] = split
      {String.downcase(String.trim(k)), String.trim(v)}
    end
    |> Map.new()
  end
end
