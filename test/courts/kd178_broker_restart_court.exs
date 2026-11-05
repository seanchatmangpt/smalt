# KD-178 court: Web PubSub broker-restart state wipe.
#
# Divergence: the broker (Smalt.WebPubSub GenServer) and the Bandit HTTP
# listener are separately supervised one_for_one children, so a supervised
# broker crash restarted the broker with a wiped group registry while
# connected client sockets kept riding the live Bandit child — no
# client-visible signal, publish honestly answering {:ok, 0} over dead
# membership, rejoin succeeding first-try. Real Azure drops the client
# WebSocket when the broker restarts (forcing reconnect+rejoin).
#
# Fix under court: Smalt.WebPubSub.Socket monitors the broker in init/1
# and {:stop, ...}s on the :DOWN, closing the client connection.
#
# Chicago discipline: real supervised broker (the app's DataSupervisor
# one_for_one child, killed with a real Process.exit kill — restart
# witnessed via pid change), real Bandit listener, real Plug router WS
# upgrade, and a real hand-written RFC6455 WebSocket client over :gen_tcp
# (a real interface implementation, not a mock). Bounded polls only —
# no sleeps.
#
# Negative fixture (shim court, run separately): reverting the monitor
# from socket.ex must flip this court (client stays connected riding the
# listener after the broker kill). Witnessed in
# docs/jira/v26.11.5/receipts/l32-kd178.md.
#
# Context: solo (in-process, loopback).
#
# `# KD-COVERS: KD-178`
#
# Context: solo

defmodule Smalt.Courts.Kd178BrokerRestartCourt do
  use ExUnit.Case, async: false

  import SmaltTest.AssertEventually, only: [assert_eventually: 2]

  alias __MODULE__.Ws

  @moduletag :wps_kd178

  setup do
    # ja5/sj4 pattern: OS-assigned port, closed before Bandit binds it.
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)

    {:ok, server} = Bandit.start_link(plug: Smalt.WebPubSub.Router, scheme: :http, port: port)
    hub = "kd178-#{System.unique_integer([:positive])}"

    %{port: port, server: server, hub: hub}
  end

  test "broker kill under supervision drops the client socket and forces reconnect+rejoin",
       %{port: port, server: server, hub: hub} do
    roles = ["webpubsub.joinLeaveGroup", "webpubsub.sendToGroup"]
    token = Smalt.WebPubSub.Token.mint(hub, "kd178-u1", roles)
    group = "g1"

    # -- Real WS client connects and joins (positive control: the wire face works)
    ws = Ws.connect(port, "/webpubsub/hubs/#{hub}?access_token=#{token}")
    Ws.send_text(ws, Jason.encode!(%{"type" => "joinGroup", "group" => group, "ackId" => 1}))
    assert %{"type" => "ack", "ackId" => 1, "success" => true} = Ws.next_ack(ws)
    assert [_socket_pid] = Smalt.WebPubSub.members(hub, group)

    # -- Server push reaches the client through the real listener
    {:ok, 1} = Smalt.WebPubSub.publish(hub, group, "kd178-payload")
    assert {:binary, "kd178-payload"} = Ws.next_frame(ws)

    # -- Supervised broker crash (one_for_one restart, same topology as prod)
    old_broker = Process.whereis(Smalt.WebPubSub)
    Process.exit(old_broker, :kill)

    # Restart witnessed: new pid, alive, answering (bounded poll, no sleep).
    assert_eventually(
      fn ->
        new = Process.whereis(Smalt.WebPubSub)
        new != old_broker and new != nil and Process.alive?(new) and
          GenServer.whereis(Smalt.WebPubSub) == new
      end,
      timeout: 5_000
    )

    new_broker = Process.whereis(Smalt.WebPubSub)
    assert new_broker != old_broker

    # Broker-restarted :DOWN reaches the socket — the client connection is
    # closed (close frame or TCP close), never left riding the listener.
    assert :closed = Ws.await_close(ws, 5_000)

    # The restarted broker's registry is wiped AND stayed truthful: no
    # ghost membership from the dead socket survives the restart.
    assert [] = Smalt.WebPubSub.members(hub, group)
    assert {:ok, 0} = Smalt.WebPubSub.publish(hub, group, "after-restart")

    # -- The real-Azure cycle: reconnect + rejoin succeeds against the
    #    restarted broker (the new socket monitors the NEW broker pid).
    ws2 = Ws.connect(port, "/webpubsub/hubs/#{hub}?access_token=#{token}")
    Ws.send_text(ws2, Jason.encode!(%{"type" => "joinGroup", "group" => group, "ackId" => 2}))
    assert %{"type" => "ack", "ackId" => 2, "success" => true} = Ws.next_ack(ws2)
    assert [_socket_pid2] = Smalt.WebPubSub.members(hub, group)

    {:ok, 1} = Smalt.WebPubSub.publish(hub, group, "after-rejoin")
    assert {:binary, "after-rejoin"} = Ws.next_frame(ws2)

    :ok = Smalt.WebPubSub.leave(hub, group, self())
    :gen_tcp.close(ws2)
    assert Process.alive?(server)
  end

  test "socket terminate survives a broker mid-restart (no :noproc exit on leave)",
       %{port: _port, server: _server, hub: hub} do
    # Pure-module leg: terminate with a dead broker name must not raise.
    # (KD-178 fix side-guard: the explicit leave in terminate/2 is
    # gated on Process.whereis/1.)
    st = %Smalt.WebPubSub.Socket{
      hub: hub,
      user_id: "u",
      roles: [],
      conn_id: "cid",
      groups: ["g-dead"]
    }

    :ok = Smalt.WebPubSub.Socket.terminate(:normal, st)
  end
end

defmodule Smalt.Courts.Kd178BrokerRestartCourt.Ws do
  @moduledoc """
  Minimal real RFC6455 client over :gen_tcp (passive). Hand-written real
  interface implementation — Chicago-legal, no mock. Enough framing for
  the court: text frames out (masked), text/binary/close frames in.
  """

  @timeout 5_000
  import Bitwise

  def connect(port, path) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false, nodelay: true])

    key = :base64.encode(:crypto.strong_rand_bytes(16))

    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Protocol: json.webpubsub.azure.v1\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)

    # Read the 101 head (bounded).
    head = recv_until(sock, "\r\n\r\n", deadline(@timeout))
    assert_101(head)

    sock
  end

  def send_text(sock, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x81, 0x80 ||| len>>
        len < 65_536 -> <<0x81, 0x80 ||| 126, len::16>>
        true -> <<0x81, 0x80 ||| 127, len::unsigned-integer-size(64)>>
      end

    masked = mask_payload(payload, mask)
    :ok = :gen_tcp.send(sock, [header, mask, masked])
    :ok
  end

  # Next text frame decoded as JSON (skips nothing else — protocol is
  # acks-then-acks in this court).
  def next_ack(sock) do
    {:ok, 0x1, payload} = next_frame(sock, deadline(@timeout))
    Jason.decode!(payload)
  end

  # Next frame of any data opcode (text or binary), decoded as a tagged tuple.
  def next_frame(sock) do
    case next_frame(sock, deadline(@timeout)) do
      {:ok, opcode, payload} when opcode in [0x1, 0x2] -> {if(opcode == 0x1, do: :text, else: :binary), payload}
      {:ok, 0x8, _} -> :closed
      other -> other
    end
  end

  # Bounded poll for connection close: a close frame or TCP close.
  # Uses recv timeouts as the poll cadence — never Process.sleep.
  def await_close(sock, timeout_ms) do
    deadline = deadline(timeout_ms)

    case next_frame(sock, deadline) do
      :closed -> :closed
      {:ok, 0x8, _} -> :closed
      {:ok, _op, _payload} -> await_close(sock, remaining(deadline))
      {:error, reason} -> raise "await_close: read failed without close: #{inspect(reason)}"
    end
  end

  # -- internals ---------------------------------------------------------------

  defp next_frame(sock, deadline) do
    with {:ok, <<b1, b2>>} <- recv_exact(sock, 2, deadline),
         opcode = b1 &&& 0x0F,
         len0 = b2 &&& 0x7F,
         {:ok, len_bin} <- if(len0 == 126, do: recv_exact(sock, 2, deadline), else: {:ok, <<>>}),
         {:ok, len_bin8} <- if(len0 == 127, do: recv_exact(sock, 8, deadline), else: {:ok, <<>>}),
         len = decode_len(len0, len_bin, len_bin8),
         {:ok, payload} <- (if len > 0, do: recv_exact(sock, len, deadline), else: {:ok, <<>>}) do
      {:ok, opcode, payload}
    else
      {:error, :closed} -> :closed
      {:error, reason} -> raise "ws read failed: #{inspect(reason)}"
    end
  end

  defp decode_len(126, <<len::16>>, _), do: len
  defp decode_len(127, _, <<len::unsigned-integer-size(64)>>), do: len
  defp decode_len(len0, _, _) when len0 < 126, do: len0

  defp recv_exact(_sock, 0, _deadline), do: {:ok, <<>>}

  defp recv_exact(sock, need, deadline) do
    do_recv_exact(sock, need, deadline, [])
  end

  defp do_recv_exact(sock, need, deadline, acc) do
    case :gen_tcp.recv(sock, need, remaining(deadline)) do
      {:ok, bin} when byte_size(bin) == need ->
        {:ok, IO.iodata_to_binary(Enum.reverse([bin | acc]))}

      {:ok, bin} ->
        do_recv_exact(sock, need - byte_size(bin), deadline, [bin | acc])

      {:error, :timeout} ->
        if remaining(deadline) > 0 do
          do_recv_exact(sock, need, deadline, acc)
        else
          {:error, :timeout}
        end

      other ->
        other
    end
  end

  defp recv_until(sock, needle, deadline, acc \\ []) do
    case :gen_tcp.recv(sock, 0, remaining(deadline)) do
      {:ok, bin} ->
        acc2 = [bin | acc] |> IO.iodata_to_binary()

        if String.contains?(acc2, needle) do
          acc2
        else
          recv_until(sock, needle, deadline, [acc2])
        end

      {:error, reason} ->
        raise "ws handshake read failed: #{inspect(reason)}"
    end
  end

  defp assert_101(head) do
    unless head =~ "101" do
      raise "ws handshake failed: #{inspect(head)}"
    end
  end

  defp mask_payload(payload, mask) do
    m = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {b, i} -> :erlang.band(:erlang.bxor(b, Enum.at(m, rem(i, 4))), 0xFF) end)
    |> :binary.list_to_bin()
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)
end
