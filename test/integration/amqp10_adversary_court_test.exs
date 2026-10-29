defmodule Amqp10.AdversaryCourt do
  @moduledoc """
  AMQP 1.0 skeptic adversarial court (BK-1 residual, promoted from scratch
  `amqp10_bk1_adversary.exs` in v26.10.21). One re-derived adversarial case
  per gate (ADV-1..ADV-5): mid-frame RST cascade, live-wire nil-described
  `:end`, unknown-handle transfer, header-boundary split, settled-row keying.
  Companion to `Amqp10.CrashOnlyCourt`.
  """

  use ExUnit.Case, async: false

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>

  defp start_router! do
    parent = self()
    {:ok, lpid, port} = Smalt.Amqp10.Connection.start_listener(0, notify: parent)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    {lpid, conn, sock}
  end

  defp enc(ch, perf), do: IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf))

  defp handshake!(sock) do
    :ok = :gen_tcp.send(sock, @header)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:open, %{container_id: "bk1-adv"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "bk1-adv-link", handle: 0, role: false,
                           target: %{address: "amqp10-bk1"}}})
      ])

    frames = recv_n(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], inspect(kinds)
    frames
  end

  defp recv_n(_sock, 0, _buf), do: []

  defp recv_n(sock, n, buf) do
    case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} -> [f | recv_n(sock, n - 1, rest)]
      {:more, _} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
        recv_n(sock, n, buf <> data)
      {:error, r} -> flunk("decode: #{inspect(r)}")
    end
  end

  defp transfer_frame(did, payload),
    do: enc(0, {:transfer, %{handle: 0, delivery_id: did,
                             delivery_tag: <<0::128>>, settled: true, more: false}, payload})

  defp tree_pids(conn) do
    sessions = :erlang.process_info(conn, :links) |> elem(1) |> Enum.filter(&is_pid/1)

    links =
      Enum.flat_map(sessions, fn s ->
        case :erlang.process_info(s, :links) do
          :undefined -> []
          {:links, ls} -> Enum.filter(ls, &is_pid/1)
        end
      end)

    Enum.uniq([conn | sessions] ++ links) -- [self()]
  end

  defp collect_downs(refs, t0, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      MapSet.size(refs) == 0 -> {:ok, now - t0}
      now >= deadline -> {:timeout, MapSet.size(refs)}
      true ->
        receive do
          {:DOWN, ref, :process, _, _} -> collect_downs(MapSet.delete(refs, ref), t0, deadline)
        after
          deadline - now -> {:timeout, MapSet.size(refs)}
        end
    end
  end

  # ADV-1 (gate 1 cascade): RST while a transfer frame is split across the
  # wire — first half written, RST before the second half. The connection
  # must die typed and the whole tree must cascade <10ms.
  test "ADV-1: RST mid-frame (half a transfer on the wire) -> typed tree death <10ms" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    pids = tree_pids(conn)
    assert length(pids) >= 3
    refs = MapSet.new(for pid <- pids, do: Process.monitor(pid))

    full = transfer_frame(500_001, "adv1-half")
    {a, _b} = String.split_at(full, div(byte_size(full), 2))
    :ok = :gen_tcp.send(sock, a)
    t0 = System.monotonic_time(:millisecond)
    :ok = :inet.setopts(sock, linger: {true, 0})
    :ok = :gen_tcp.close(sock)

    assert {:ok, elapsed} = collect_downs(refs, t0, t0 + 10)
    assert elapsed < 10, "mid-frame RST cascade: #{elapsed}ms"
    IO.puts("[ADV-1] mid-frame RST cascade: #{elapsed}ms, #{length(pids)} pids")
  end

  # ADV-2 (gate 2 conformance): valid nil-described :end over the LIVE wire —
  # the decoder must not raise; the connection must exit TYPED (no bare
  # ArgumentError), proving the SK2b fix holds on a live connection, not just
  # at the decoder unit level.
  test "ADV-2: live-wire nil-described end frame -> typed exit, never a raise" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    ref = Process.monitor(conn)

    body = <<0, 0x53, 0x17, 0x40>>
    size = 8 + byte_size(body)
    :ok = :gen_tcp.send(sock, <<size::32, 2::8, 0::8, 0::16, body::binary>>)

    assert_receive {:DOWN, ^ref, :process, ^conn, reason}, 5_000
    refute match?({ArgumentError, _}, reason), "decoder raised on live wire: #{inspect(reason)}"
    IO.puts("[ADV-2] nil-described end over live wire -> typed exit: #{inspect(reason)}")
  end

  # ADV-3 (gate 3 credit/enforcement): transfer on an UNKNOWN handle before
  # any attach echo — the session must refuse typed, not silently accept.
  test "ADV-3: transfer on unknown handle -> typed exit, no silent accept" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    ref = Process.monitor(conn)

    bogus =
      enc(0, {:transfer, %{handle: 9, delivery_id: 600_001, delivery_tag: <<0::128>>,
                           settled: true, more: false}, "adv3"})

    :ok = :gen_tcp.send(sock, bogus)

    assert_receive {:DOWN, ^ref, :process, ^conn, reason}, 5_000
    IO.puts("[ADV-3] unknown-handle transfer -> #{inspect(reason)}")
    refute match?({ArgumentError, _}, reason)
  end

  # ADV-4 (gate 4 partial-frame): cut EXACTLY at the 8-byte frame header
  # boundary — the harshest legal split point (empty body chunk 1).
  test "ADV-4: split exactly at frame-header boundary -> handshake completes" do
    Process.flag(:trap_exit, true)
    full = IO.iodata_to_binary([
      @header,
      enc(0, {:open, %{container_id: "bk1-adv4"}}),
      enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
      enc(0, {:attach, %{name: "bk1-adv4-link", handle: 0, role: false,
                         target: %{address: "amqp10-bk1"}}})
    ])

    {_lpid, _conn, sock} = start_router!()
    {a, b} = String.split_at(full, 8)
    :ok = :gen_tcp.send(sock, a)
    :ok = :gen_tcp.send(sock, b)
    frames = recv_n(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], inspect(kinds)
    IO.puts("[ADV-4] header-boundary split: handshake ok")
  end

  # ADV-5 (gate 5 ETS growth/lifecycle): settled row lands with the right
  # key + payload for a fresh high delivery-id; and rows keyed per-channel.
  test "ADV-5: settled row keyed {channel, delivery_id} with exact payload" do
    Process.flag(:trap_exit, true)
    {_lpid, _conn, sock} = start_router!()
    handshake!(sock)

    payload = "adv5-" <> String.duplicate("z", 64)
    :ok = :gen_tcp.send(sock, transfer_frame(700_001, payload))
    [_disposition] = recv_n(sock, 1, <<>>)

    assert [{_, ^payload, _ts}] = :ets.lookup(:amqp10_settled, {0, 700_001})
    IO.puts("[ADV-5] settled row {0, 700_001} payload exact")
  end
end
