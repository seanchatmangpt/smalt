# BK-58 (BK-40 lane 3): domain-blind WebSocket -> AMQP relay witness.
#
# Chicago discipline: real WS handshake (RFC6455 client over real TCP),
# real Bandit relay on a real loopback port, real Smalt.Amqp.Listener in
# :eh mode with real broker connections under Smalt.AmqpBroker.ConnSup.
# No mocks. The witness: one EH event published over WS through the relay
# lands in the EH store and is delivered back over the same WS relay to a
# partition receiver -- real bytes end to end, assertions on received wire
# payload, never interactions.
#
# Law note: the browser leg stays TYPED-PERMANENT (workspace transport
# law, smaltFetch cannot do WS) -- this witness is host-side only. The
# relay is delivered where lawful: lib/smalt/messaging/ws_amqp_relay.ex.
#
# Context: solo (in-process wire faces on loopback).

defmodule SmaltTest.WsClient do
  @moduledoc """
  Minimal RFC6455 client for loopback relay tests. Real socket, no
  client-library dependency: handshake, masked binary frames, bounded
  recv polls (no sleeps).
  """

  import ExUnit.Assertions
  import Bitwise

  defstruct [:sock, :buf]

  def connect(port, path) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    :ok = :gen_tcp.send(sock, req)
    {:ok, headers, rest} = recv_until_marker(sock, <<>>, "\r\n\r\n")
    assert String.contains?(headers, " 101 ")
    %__MODULE__{sock: sock, buf: rest}
  end

  def send_binary(%__MODULE__{sock: sock}, data) do
    data = IO.iodata_to_binary(data)
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(data)

    {head, frame_len} =
      if len < 126 do
        {<<0x82, 0x80 ||| len>>, len}
      else
        {<<0x82, 0x80 ||| 126, len::16>>, len}
      end

    payload = :crypto.exor(data, mask_stream(mask, frame_len))
    :ok = :gen_tcp.send(sock, <<head::binary, mask::binary, payload::binary>>)
    :ok
  end

  # Returns the next DATA payload from the WS stream (skips ping/pong,
  # replies pong to ping). Bounded poll on a real observable.
  def recv_data(ws, timeout_ms) do
    case next_frame(ws) do
      {:ok, {:data, payload}, ws2} -> {:ok, payload, ws2}
      {:ok, {:ping, payload}, ws2} ->
        :ok = send_pong(ws2, payload)
        recv_data(%{ws2 | buf: <<>>}, timeout_ms)
      {:more, ws2} ->
        recv_more(ws2, timeout_ms)
      {:closed, _} = c -> c
    end
  end

  defp recv_more(ws, timeout_ms) do
    case :gen_tcp.recv(ws.sock, 0, timeout_ms) do
      {:ok, chunk} -> recv_data(%{ws | buf: ws.buf <> chunk}, timeout_ms)
      {:error, :closed} -> {:closed, ws}
      {:error, reason} -> {:error, reason, ws}
    end
  end

  defp next_frame(%__MODULE__{buf: buf} = ws) do
    case parse_frame(buf) do
      {frame, rest} -> {:ok, frame, %{ws | buf: rest}}
      :more -> {:more, ws}
      :invalid -> {:closed, ws}
    end
  end

  defp parse_frame(<<b1::8, b2::8, rest::binary>>) do
    len7 = b2 &&& 0x7F
    frame_len(len7, rest, b1)
  end

  defp parse_frame(_), do: :more

  defp frame_len(126, <<len::16, rest::binary>>, b1), do: frame_len(len, rest, b1)

  defp frame_len(127, <<_::32, len::32, rest::binary>>, b1), do: frame_len(len, rest, b1)

  defp frame_len(len, rest, b1) do
    case rest do
      <<payload::binary-size(^len), tail::binary>> ->
        {frame(b1, payload), tail}

      _ ->
        :more
    end
  end

  defp frame(b1, payload) do
    case b1 &&& 0x0F do
      9 -> {:ping, payload}
      10 -> {:pong, payload}
      8 -> {:close, payload}
      _ -> {:data, payload}
    end
  end

  defp send_pong(%__MODULE__{sock: sock}, payload) do
    len = byte_size(payload)

    head =
      if len < 126 do
        <<0x8A, 0x80 ||| len>>
      else
        <<0x8A, 0x80 ||| 126, len::16>>
      end

    mask = <<0, 0, 0, 0>>
    :ok = :gen_tcp.send(sock, <<head::binary, mask::binary, payload::binary>>)
  end

  defp mask_stream(mask, len) do
    :binary.part(:binary.copy(mask, div(len, 4) + 1), 0, len)
  end

  defp recv_until_marker(sock, buf, marker) do
    case :binary.split(buf, marker) do
      [headers, tail] -> {:ok, headers, tail}
      _ ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, chunk} -> recv_until_marker(sock, buf <> chunk, marker)
          {:error, r} -> {:error, r}
        end
    end
  end

end

defmodule Smalt.Internal.WsAmqpRelayTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp10.FrameDecoder
  alias Smalt.Amqp.FrameCodec
  alias Smalt.Messaging.EventHubs
  alias SmaltTest.WsClient

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  @recv_timeout 10_000

  defp relay_port, do: Application.fetch_env!(:smalt, :ws_amqp_relay_port)

  defp enc(ch, perf), do: IO.iodata_to_binary(FrameCodec.encode_frame(:amqp, ch, perf))

  # Pull exactly n decoded AMQP frames through the WS relay, carrying the
  # inter-frame buffer across WS data payloads. Bounded by @recv_timeout.
  defp recv_amqp(ws, n, buf \\ <<>>)
  defp recv_amqp(ws, 0, buf), do: {[], ws, buf}

  defp recv_amqp(ws, n, buf) do
    case FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} ->
        {frames, ws2, rest2} = recv_amqp(ws, n - 1, rest)
        {[f | frames], ws2, rest2}

      {:more, _} ->
        assert {:ok, chunk, ws2} = WsClient.recv_data(ws, @recv_timeout)
        recv_amqp(ws2, n, buf <> chunk)

      {:error, r} ->
        flunk("amqp frame decode failed: #{inspect(r)}")
    end
  end

  test "unknown lane is refused 404, never upgraded" do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", relay_port(), [:binary, packet: :raw, active: false], 5_000)

    req =
      "GET /ws/amqp/nope HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: eWVsbG93aGVhZGVyb2theQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)
    {:ok, resp} = recv_all(sock)
    assert String.starts_with?(resp, "HTTP/1.1 404")
    :gen_tcp.close(sock)
  end

  test "EH publish -> consume end-to-end through the relay (BK-58 witness)" do
    EventHubs.ensure_tables()
    hub = "bk58-hub-#{System.unique_integer([:positive])}"
    evt = "bk58-evt-#{System.unique_integer([:positive])}"

    ws = WsClient.connect(relay_port(), "/ws/amqp/eh")

    # -- AMQP header + open/begin/attach(sender), all through the relay --------
    :ok = WsClient.send_binary(ws, @header)
    assert {:ok, echo, ws} = WsClient.recv_data(ws, @recv_timeout)
    assert echo == @header, "relay must echo the AMQP header verbatim"

    :ok =
      WsClient.send_binary(ws, [
        enc(0, {:open, %{container_id: "bk58"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "bk58-pub", handle: 0, role: false, target: %{address: hub}}})
      ])

    {[open_f, begin_f, attach_f, flow_f], ws, buf} = recv_amqp(ws, 4)
    assert elem(open_f.performative, 0) == :open
    assert elem(begin_f.performative, 0) == :begin
    assert elem(attach_f.performative, 0) == :attach
    assert elem(flow_f.performative, 0) == :flow

    # -- Publish: settled transfer with a partition key -------------------------
    payload =
      IO.iodata_to_binary(
        FrameCodec.encode_message([
          {:message_annotations, %{"x-opt-partition-key" => "bk58pk"}},
          {:body_data, evt}
        ])
      )

    :ok =
      WsClient.send_binary(ws, [
        enc(0,
          {:transfer,
           %{handle: 0, delivery_id: 1, delivery_tag: <<0::128>>, settled: true, more: false},
           payload}
        )
      ])

    # Broker settles EH publishes with a disposition(accepted) — real store write.
    {[disp_f], ws, _buf} = recv_amqp(ws, 1, buf)
    # The decoder returns the described type for the accepted outcome
    # (descriptor 0x24 = accepted).
    assert {:disposition, %{state: {:described, 36, []}}} = disp_f.performative

    # -- Consume: receivers on both pinned partitions (pk hash is broker-owned) -
    :ok =
      WsClient.send_binary(ws, [
        enc(0,
          {:attach,
           %{
             name: "bk58-sub0",
             handle: 1,
             role: true,
             source: %{address: "#{hub}/ConsumerGroups/$Default/Partitions/0"}
           }}
        ),
        enc(0,
          {:attach,
           %{
             name: "bk58-sub1",
             handle: 2,
             role: true,
             source: %{address: "#{hub}/ConsumerGroups/$Default/Partitions/1"}
           }}
        ),
        enc(0, {:flow, %{handle: 1, link_credit: 10}}),
        enc(0, {:flow, %{handle: 2, link_credit: 10}})
      ])

    # The broker may interleave the credit-first EH delivery with the attach
    # echoes (KD-115 delivers on flow), so no fixed-count read here: drain
    # until the event transfer arrives, collecting the attach echoes too.
    {attaches, xfers, _ws, _abuf} = drain_to_transfer(ws, <<>>, deadline_ms(), 0, [])

    assert attaches >= 2, "expected 2 attach echoes, got #{attaches}"

    if xfers == [] do
      IO.puts("BK103-PROBE store: p0=#{inspect(EventHubs.last_enqueued("#{hub}/partitions/0"))} " <>
              "p1=#{inspect(EventHubs.last_enqueued("#{hub}/partitions/1"))}")
    end

    assert xfers != [], "no EH delivery arrived through the relay"

    assert Enum.any?(xfers, fn x -> x.payload != nil and x.payload =~ evt end),
           "EH delivery through the relay lost the published payload: " <>
             inspect(Enum.map(xfers, & &1.payload))

    :ok = WsClient.send_binary(ws, enc(0, {:end, %{}}))
  end

  defp deadline_ms, do: System.monotonic_time(:millisecond) + @recv_timeout

  # Bounded drain of broker frames until a transfer on handle 1 or 2
  # arrives (or the deadline passes). Counts attach echoes en route. The
  # AMQP byte buffer (abuf) is separate from the WS-layer buffer inside the
  # client struct; every wait is a bounded recv.
  defp drain_to_transfer(ws, abuf, deadline, attaches, acc) do
    cond do
      System.monotonic_time(:millisecond) > deadline ->
        {attaches, acc, ws, abuf}

      true ->
        case FrameDecoder.decode_frame(abuf) do
          {:ok, %{performative: {:transfer, %{handle: h}}} = f, rest} when h == 1 or h == 2 ->
            drain_to_transfer(ws, rest, deadline, attaches, [f | acc])

          {:ok, %{performative: {:attach, _}}, rest} ->
            drain_to_transfer(ws, rest, deadline, attaches + 1, acc)

          {:ok, _other, rest} ->
            drain_to_transfer(ws, rest, deadline, attaches, acc)

          {:more, _} ->
            case WsClient.recv_data(ws, 2_000) do
              {:ok, chunk, ws2} ->
                drain_to_transfer(ws2, abuf <> chunk, deadline, attaches, acc)

              _ ->
                {attaches, acc, ws, abuf}
            end

          {:error, r} ->
            flunk("amqp frame decode failed: #{inspect(r)} (abuf head: #{inspect(binary_part(abuf, 0, min(8, byte_size(abuf))))})")
        end
    end
  end

  defp recv_all(sock, buf \\ <<>>) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, d} -> recv_all_cont(sock, buf <> d)
      {:error, _} -> {:ok, buf}
    end
  end

  defp recv_all_cont(sock, buf) do
    case :gen_tcp.recv(sock, 0, 500) do
      {:ok, d} -> recv_all_cont(sock, buf <> d)
      {:error, _} -> {:ok, buf}
    end
  end
end
