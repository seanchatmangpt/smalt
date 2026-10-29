defmodule Amqp10.CrashOnlyCourt do
  @moduledoc """
  Courts for the crash-only AMQP 1.0 router family (`lib/smalt/messaging/amqp10/`):
  crash-cascade timing, client RST, raw wire round-trip, malformed protocol
  header, incomplete-frame buffering, and a frame-decoder equivalence
  spot-check against `Smalt.Amqp.FrameCodec`.
  """

  use ExUnit.Case, async: false

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>

  # -- helpers ----------------------------------------------------------------

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

  # Handshake: header + open + begin + attach (client = sender, handle 0).
  defp handshake!(sock) do
    :ok = :gen_tcp.send(sock, @header)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:open, %{container_id: "court-client"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "court-link", handle: 0, role: false,
                           target: %{address: "amqp10-court"}}})
      ])

    frames = recv_while(sock, 4, <<>>)
    :ok = drain_and_check(frames)
    frames
  end

  defp drain_and_check(frames) do
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)

    if kinds == [:open, :begin, :attach, :flow] do
      :ok
    else
      flunk("unexpected handshake replies: #{inspect(kinds)}")
    end
  end

  defp recv_while(_sock, 0, _buf), do: []

  defp recv_while(sock, n, buf) do
    {frame, buf2} =
      case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
        {:ok, f, rest} ->
          {f, rest}

        {:more, _} ->
          {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
          case Smalt.Amqp10.FrameDecoder.decode_frame(buf <> data) do
            {:ok, f, rest} -> {f, rest}
            other -> flunk("decode failed: #{inspect(other)}")
          end

        {:error, r} ->
          flunk("decode error: #{inspect(r)}")
      end

    [frame | recv_while(sock, n - 1, buf2)]
  end

  # Collect monitor DOWNs until `refs` is empty or the `deadline` passes;
  # returns {elapsed_ms, remaining_refs} ({999+ elapsed, remaining} when
  # DOWNs are missing). The caller must rebind BOTH: the remaining set is
  # data, not just the timing (v26.10.21 AMQP10-F4: the stale-refset bug —
  # asserting on the caller's original set — read as "cascade incomplete"
  # while the measured cascade was 0ms).
  defp collect_downs(refs, t0, deadline) do
    now = System.monotonic_time(:millisecond)

    cond do
      MapSet.size(refs) == 0 ->
        {System.monotonic_time(:millisecond) - t0, refs}

      now >= deadline ->
        {deadline - t0 + 999, refs}

      true ->
        receive do
          {:DOWN, ref, :process, _pid, _reason} ->
            collect_downs(MapSet.delete(refs, ref), t0, deadline)
        after
          deadline - now -> {deadline - t0 + 999, refs}
        end
    end
  end

  defp tree_pids(conn) do
    sessions = :erlang.process_info(conn, :links) |> elem(1) |> Enum.filter(&is_pid/1)

    links =
      Enum.flat_map(sessions, fn s ->
        :erlang.process_info(s, :links) |> elem(1) |> Enum.filter(&is_pid/1)
      end)

    Enum.uniq([conn | sessions] ++ links) -- [self()]
  end

  test "court 1: kill the root -> whole tree dead within 10ms" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    pids = tree_pids(conn)
    assert length(pids) >= 3, "expected root+sessions+links, got #{inspect(pids)}"

    # Monitors BEFORE the kill: elapsed is measured from the exit call.
    refs = for pid <- pids, do: Process.monitor(pid)
    refset = MapSet.new(refs)
    t0 = System.monotonic_time(:millisecond)
    Process.exit(conn, :kill)

    {elapsed, remaining} = collect_downs(refset, t0, t0 + 10)

    assert elapsed < 10,
           "cascade took #{elapsed}ms (budget 10ms), missing #{MapSet.size(remaining)} DOWNs"

    assert MapSet.size(remaining) == 0
  end

  test "court 2: client RST -> full tree death <10ms" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    pids = tree_pids(conn)
    refs = for pid <- pids, do: Process.monitor(pid)
    refset = MapSet.new(refs)
    t0 = System.monotonic_time(:millisecond)

    # Abrupt reset: SO_LINGER 0 close sends RST, not FIN.
    :ok = :inet.setopts(sock, linger: {true, 0})
    :ok = :gen_tcp.close(sock)

    {elapsed, remaining} = collect_downs(refset, t0, t0 + 10)

    assert elapsed < 10,
           "RST cascade took #{elapsed}ms (budget 10ms), missing #{MapSet.size(remaining)} DOWNs"

    assert MapSet.size(remaining) == 0
  end

  test "court 3: raw gen_tcp round-trip - flow + disposition, payload lands in ETS" do
    Process.flag(:trap_exit, true)
    {_lpid, _conn, sock} = start_router!()
    handshake!(sock)

    payload = "court-payload-" <> String.duplicate("x", 256)
    tag = :binary.copy(<<0>>, 16)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:transfer, %{handle: 0, delivery_id: 7, delivery_tag: tag,
                             settled: true, more: false}, payload})
      ])

    # The immediate link-credit flow frame is already consumed by the
    # 4-frame handshake above (open, begin, attach, flow); a settled
    # transfer answers exactly one accepted disposition.
    [disposition] = recv_while(sock, 1, <<>>)

    {_, disp_fields} = disposition.performative
    assert disp_fields[:first] == 7
    assert disp_fields[:settled] == true
    assert disp_fields[:state] == {:described, 0x24, []}, "expected accepted state"

    rows = :ets.lookup(:amqp10_settled, {0, 7})
    assert [{_, ^payload, _ts}] = rows
  end

  test "court 4: malformed protocol header -> typed connection exit" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    ref = Process.monitor(conn)
    :ok = :gen_tcp.send(sock, "GARBAGE!!!")

    assert_receive {:DOWN, ^ref, :process, ^conn,
                    {:bad_protocol_header, <<"GARBAGE!">> = _got}},
                   5_000
  end

  test "court 5: incomplete frame buffered, completed on next chunk" do
    Process.flag(:trap_exit, true)
    {_lpid, _conn, sock} = start_router!()
    handshake!(sock)

    payload = "split-payload-" <> String.duplicate("y", 128)
    tag = :binary.copy(<<1>>, 16)

    full =
      enc(0, {:transfer, %{handle: 0, delivery_id: 9, delivery_tag: tag,
                           settled: true, more: false}, payload})

    {first, second} = String.split_at(full, div(byte_size(full), 2))
    :ok = :gen_tcp.send(sock, first)
    # No sleep: the split frame simply cannot complete yet; completion is
    # proven by the disposition + ETS row arriving only after chunk 2.
    refute :ets.member(:amqp10_settled, {0, 9})
    :ok = :gen_tcp.send(sock, second)

    [_disposition] = recv_while(sock, 1, <<>>)
    rows = :ets.lookup(:amqp10_settled, {0, 9})
    assert [{_, ^payload, _ts}] = rows
  end

  test "equivalence spot-check: FrameDecoder vs FrameCodec on shared corpus" do
    corpus = [
      enc(0, {:open, %{container_id: "eq", max_frame_size: 65_536}}),
      enc(0, {:begin, %{remote_channel: 3, next_outgoing_id: 1,
                        incoming_window: 100, outgoing_window: 100}}),
      enc(0, {:attach, %{name: "eq-link", handle: 2, role: false,
                         target: %{address: "q"}}}),
      enc(0, {:attach, %{name: "eq-rx", handle: 5, role: true,
                         source: %{address: "q"}}}),
      enc(0, {:flow, %{handle: 2, delivery_count: 4, link_credit: 55}}),
      enc(0, {:transfer, %{handle: 2, delivery_id: 11, delivery_tag: <<0::128>>,
                           settled: true}, "corpus-body"}),
      enc(0, {:disposition, %{role: true, first: 11, settled: true, state: :accepted}}),
      enc(0, {:detach, %{handle: 2, closed: true}}),
      enc(0, {:end, %{}}),
      enc(0, {:close, %{}}),
      # Raw heartbeat: 8-byte empty AMQP frame.
      <<0, 0, 0, 8, 2, 0, 0, 0>>
    ]

    for wire <- corpus do
      {:ok, ours, <<>>} = Smalt.Amqp10.FrameDecoder.decode_frame(wire)
      {:ok, theirs} = Smalt.Amqp.FrameCodec.decode_frame(wire)

      # Structural equality of the COMMON fields: type, channel,
      # performative name, payload; plus a couple of scalar fields where
      # both decoders expose them.
      assert ours.type == theirs.type
      assert ours.channel == theirs.channel
      {our_name, our_fields} = ours.performative
      their_name = theirs.performative[:performative] || theirs.performative.performative

      assert our_name == their_name,
             "performative mismatch: #{inspect(our_name)} vs #{inspect(their_name)} on #{inspect(wire)}"

      assert ours.payload == theirs.payload

      if their_name == :transfer do
        assert our_fields[:handle] == theirs.performative[:handle]
        assert our_fields[:delivery_id] == theirs.performative[:delivery_id]
        assert our_fields[:settled] == theirs.performative[:settled]
      end

      if their_name == :attach do
        assert our_fields[:name] == theirs.performative[:name]
        assert our_fields[:handle] == theirs.performative[:handle]
        assert our_fields[:role] == theirs.performative[:role]
      end

      if their_name == :flow do
        assert our_fields[:link_credit] == theirs.performative[:link_credit]
        assert our_fields[:handle] == theirs.performative[:handle]
      end
    end

    # {:more} agreement on a truncated buffer.
    {:more, _} = Smalt.Amqp10.FrameDecoder.decode_frame(binary_slice(hd(corpus), 0, 4))
    {:more, _} = Smalt.Amqp.FrameCodec.decode_frame(binary_slice(hd(corpus), 0, 4))
  end

  # -- EXPL-4 F2 repair court (expl4r-wirefront-repairs) -------------------------

  # Falsifier: a remote frame declaring a 200-byte 0xA1 string with 3 bytes
  # of payload must answer {:error, :truncated_frame} — the witnessed
  # MatchError face is closed, and the moduledoc "never raises" claim is
  # receipted (decode_frame raises on NOTHING here).
  test "F2: truncated sized element is typed, never raises" do
    body = <<0x00, 0x53, 0x12, 0xA1, 200, 1, 2, 3>>
    frame = <<byte_size(body) + 8::32, 2::8, 1::8, 0::16, body::binary>>

    assert {:error, :truncated_frame} = Smalt.Amqp10.FrameDecoder.decode_frame(frame)
  end

  # 0xC0 declared size is binding: trailing bytes inside the declared list
  # size are refused, never silently absorbed (read-side finding, same lane).
  test "F2: 0xC0 declared-size trailing bytes refused; truncation typed" do
    # attach performative; its fields list is a 0xC0 with declared size 4,
    # count 1, one 0x50 (short) element = 2 bytes + 1 trailing junk byte.
    body = <<0x00, 0x53, 0x12, 0xC0, 0x04, 0x01, 0x50, 1, 0xAA>>
    frame = <<byte_size(body) + 8::32, 2::8, 1::8, 0::16, body::binary>>

    assert {:error, :bad_element} = Smalt.Amqp10.FrameDecoder.decode_frame(frame)

    # truncated 0xC0: declared 200-byte list, 2 bytes buffered.
    body2 = <<0x00, 0x53, 0x12, 0xC0, 200, 1, 2>>
    frame2 = <<byte_size(body2) + 8::32, 2::8, 1::8, 0::16, body2::binary>>

    assert {:error, :truncated_frame} = Smalt.Amqp10.FrameDecoder.decode_frame(frame2)
  end
end
