defmodule Amqp10.SkepticCourt do
  @moduledoc """
  AMQP10SK skeptic court (v26.10.21) — five-claim audit of the crash-only
  AMQP 1.0 router family (`lib/smalt/messaging/amqp10/`), re-dispatched after
  the BLOCKED receipt `docs/jira/v26.10.21/receipts/amqp10-crash-only-skeptic.md`.

  Claims audited:

    1. cascade <10ms on root kill AND on client RST
    2. wire conformance: outbound frames decode via `Smalt.Amqp10.FrameDecoder`
       and `Smalt.Amqp.PrimitiveCodec`; the decoder never raises on valid
       remote input
    3. credit law: single 100-credit grant, no replenishment; enforcement
       observed honestly
    4. partial-frame buffering: random TCP-segment splits mid-frame-header and
       mid-body, completed on the next chunk
    5. `:amqp10_settled` ETS growth law (bounded or unbounded)

  The family encodes OUTBOUND with `Smalt.Amqp.FrameCodec` (which rides
  `Smalt.Amqp.PrimitiveCodec`), so conformance = the family decoder can read
  back its own encoder's bytes.
  """

  use ExUnit.Case, async: false

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>

  # -- harness -----------------------------------------------------------------

  defp start_router! do
    parent = self()
    {:ok, lpid, port} = Smalt.Amqp10.Connection.start_listener(0, notify: parent)

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    {lpid, conn, sock}
  end

  defp enc(ch, perf), do: IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf))

  defp handshake_bytes do
    [
      @header,
      enc(0, {:open, %{container_id: "skeptic-client"}}),
      enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
      enc(0, {:attach, %{name: "skeptic-link", handle: 0, role: false,
                         target: %{address: "amqp10-skeptic"}}})
    ]
  end

  defp handshake!(sock) do
    :ok = :gen_tcp.send(sock, handshake_bytes())
    frames = recv_n(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], "handshake replies: #{inspect(kinds)}"
    frames
  end

  defp recv_n(_sock, 0, _buf), do: []

  defp recv_n(sock, n, buf) do
    case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
      {:ok, f, rest} ->
        [f | recv_n(sock, n - 1, rest)]

      {:more, _} ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 15_000)
        recv_n(sock, n, buf <> data)

      {:error, r} ->
        flunk("skeptic decode error: #{inspect(r)} buf=#{inspect(buf)}")
    end
  end

  defp drain_available(sock, buf, acc, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {Enum.reverse(acc), buf}
    else
      case Smalt.Amqp10.FrameDecoder.decode_frame(buf) do
        {:ok, f, rest} ->
          drain_available(sock, rest, [f | acc], deadline)

        {:more, _} ->
          case :gen_tcp.recv(sock, 0, deadline - now) do
            {:ok, data} -> drain_available(sock, buf <> data, acc, deadline)
            {:error, _t} -> {Enum.reverse(acc), buf}
          end

        {:error, r} ->
          IO.puts("[drain] undecodable residue: #{inspect(r)}")
          {Enum.reverse([{:undecodable, buf} | acc]), <<>>}
      end
    end
  end

  defp tree_pids(conn) do
    sessions =
      :erlang.process_info(conn, :links) |> elem(1) |> Enum.filter(&is_pid/1)

    links =
      Enum.flat_map(sessions, fn s ->
        case :erlang.process_info(s, :links) do
          :undefined -> []
          {:links, ls} -> Enum.filter(ls, &is_pid/1)
        end
      end)

    Enum.uniq([conn | sessions] ++ links) -- [self()]
  end

  defp collect_downs(refs, t0, deadline), do: collect_downs(refs, t0, deadline, t0)

  defp collect_downs(refs, t0, deadline, started) do
    now = System.monotonic_time(:millisecond)

    cond do
      MapSet.size(refs) == 0 ->
        {:ok, now - started}

      now >= deadline ->
        {:timeout, MapSet.size(refs), now - started}

      true ->
        receive do
          {:DOWN, ref, :process, _, _} ->
            collect_downs(MapSet.delete(refs, ref), t0, deadline, started)
        after
          deadline - now -> {:timeout, MapSet.size(refs), now - started}
        end
    end
  end

  defp transfer_frame(did, payload),
    do: enc(0, {:transfer, %{handle: 0, delivery_id: did,
                             delivery_tag: <<0::128>>, settled: true, more: false}, payload})

  # -- claim 1: crash cascade --------------------------------------------------

  test "SK1: root kill -> whole tree dead within 10ms" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    pids = tree_pids(conn)
    assert length(pids) >= 3

    refs = MapSet.new(for pid <- pids, do: Process.monitor(pid))
    t0 = System.monotonic_time(:millisecond)
    Process.exit(conn, :kill)

    assert {:ok, elapsed} = collect_downs(refs, t0, t0 + 10),
           "root-kill cascade incomplete"

    assert elapsed < 10, "root-kill cascade took #{elapsed}ms"
    IO.puts("[SK1] root-kill cascade: #{elapsed}ms, #{length(pids)} pids")
    :gen_tcp.close(sock)
  end

  test "SK1b: client RST -> full tree death <10ms" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    pids = tree_pids(conn)
    refs = MapSet.new(for pid <- pids, do: Process.monitor(pid))
    t0 = System.monotonic_time(:millisecond)

    :ok = :inet.setopts(sock, linger: {true, 0})
    :ok = :gen_tcp.close(sock)

    assert {:ok, elapsed} = collect_downs(refs, t0, t0 + 10),
           "RST cascade incomplete"

    assert elapsed < 10, "RST cascade: #{elapsed}ms"
    IO.puts("[SK1b] RST cascade: #{elapsed}ms, #{length(pids)} pids")
  end

  # -- claim 2: wire conformance ------------------------------------------------

  test "SK2: server outbound frames decode via FrameDecoder (disposition face)" do
    Process.flag(:trap_exit, true)
    {_lpid, _conn, sock} = start_router!()
    handshake!(sock)

    :ok =
      :gen_tcp.send(sock, [
        transfer_frame(1, "sk2-payload"),
        transfer_frame(2, "sk2-payload-2")
      ])

    {replies, _buf} = drain_available(sock, <<>>, [], System.monotonic_time(:millisecond) + 2_000)

    kinds =
      Enum.map(replies, fn
        {:undecodable, b} -> {:undecodable, byte_size(b)}
        f -> elem(f.performative, 0)
      end)

    IO.puts("[SK2] transfer replies: #{inspect(kinds)}")

    assert Enum.count(kinds, &(&1 == :disposition)) == 2,
           "expected 2 decodable dispositions, got #{inspect(kinds)}"
  end

  test "SK2b: decoder never RAISES on valid remote input; nil-described / list0 typed" do
    frame = fn body ->
      size = 8 + byte_size(body)
      <<size::32, 2::8, 0::8, 0::16, body::binary>>
    end

    cases = %{
      end_nil_value: <<0, 0x53, 0x17, 0x40>>,
      list0_end: <<0, 0x53, 0x17, 0x45>>,
      accepted_disposition:
        <<0, 0x53, 0x15, 0xC0, 12, 5, 0x56, 1, 0x52, 11, 0x40, 0x56, 1, 0, 0x53, 0x24, 0x45>>
    }

    for {tag, body} <- cases do
      r =
        try do
          Smalt.Amqp10.FrameDecoder.decode_frame(frame.(body))
        rescue
          e -> {:raised, Exception.message(e)}
        end

      IO.puts("[SK2b] #{tag} => #{inspect(r)}")

      assert match?({:ok, %{performative: {_, _}}, <<>>}, r) or match?({:error, _}, r),
             "decoder neither decoded nor typed its refusal on #{tag}: #{inspect(r)}"
    end
  end

  # -- claim 3: credit law ------------------------------------------------------

  test "SK3: single 100-credit grant, no replenishment; enforcement observed" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    [_, _, _, flow] = handshake!(sock)
    {_, ff} = flow.performative
    assert ff[:link_credit] == 100

    # Unique delivery-id base: the settled ledger outlives connections, so
    # low ids collide with other courts' rows in a shared-VM run.
    base = 300_000
    ref = Process.monitor(conn)

    for i <- 1..105, do: :ok = :gen_tcp.send(sock, transfer_frame(base + i, "sk3-#{i}"))

    # Typed credit exhaustion: transfer 300_101 arrives with zero credit and
    # the link exits typed; the cascade kills the connection (crash-only law:
    # the boundary is an auditable transition, not a silent drop).

    assert_receive {:DOWN, ^ref, :process, ^conn,
                    {:child_crash, _session, {:amqp10_link_credit_exhausted, 0, 300_101}}},
                   5_000

    {replies, _} = drain_available(sock, <<>>, [], System.monotonic_time(:millisecond) + 3_000)

    {dispositions, flows} =
      Enum.reduce(replies, {0, 0}, fn
        {:undecodable, _}, {d, f} -> {d, f}
        f, {d, fl} ->
          case elem(f.performative, 0) do
            :disposition -> {d + 1, fl}
            :flow -> {d, fl + 1}
            _ -> {d, fl}
          end
      end)

    ets_rows = Enum.count(1..100, fn i -> :ets.member(:amqp10_settled, {0, base + i}) end)

    IO.puts("[SK3] dispositions=#{dispositions}/105 replenishing_flows=#{flows} ets_rows=#{ets_rows}")

    # Enforced-100 credit law (canonical, measured post-fix): exactly 100
    # settled transfers answered, no replenishing flow, exactly 100 ETS rows.
    assert dispositions == 100, "expected exactly 100 dispositions, got #{dispositions}"
    assert flows == 0, "unexpected replenishing flow(s): #{flows}"
    assert ets_rows == 100
  end

  # -- claim 4: partial-frame buffering ------------------------------------------

  test "SK4: 10 random mid-header / mid-body splits all complete on next chunk" do
    Process.flag(:trap_exit, true)
    {_lpid, _conn, sock} = start_router!()

    full = IO.iodata_to_binary(handshake_bytes())
    len = byte_size(full)

    for i <- 1..10 do
      sock =
        if i == 1 do
          sock
        else
          :gen_tcp.close(sock)
          {_lp, _c, sock2} = start_router!()
          sock2
        end

      cut =
        if rem(i, 2) == 0 do
          min(:rand.uniform(7) + if(i <= 6, do: 0, else: 8), len - 1)
        else
          min(9 + :rand.uniform(max(len - 10, 1)), len - 1)
        end

      {a, b} = String.split_at(full, cut)
      :ok = :gen_tcp.send(sock, a)

      # Buffering law at the decoder level: chunk A's partial tail frame must
      # be {:more, _}, never an error or a premature parse. The 8-byte
      # protocol header is stripped first (the connection consumes it before
      # any frame decoding).
      if byte_size(a) >= 8 do
        rest_after_header = drop_header(a)
        # decode complete frames in chunk A; the partial tail must be :more
        tail = a_partial_only(rest_after_header, cut)

        assert {:more, _} = Smalt.Amqp10.FrameDecoder.decode_frame(tail)
      end

      :ok = :gen_tcp.send(sock, b)
      frames = recv_n(sock, 4, <<>>)
      kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
      assert kinds == [:open, :begin, :attach, :flow], "split #{i} cut=#{cut}: #{inspect(kinds)}"
      IO.puts("[SK4] split #{i}: cut=#{cut}/#{len} ok")
    end
  end

  defp drop_header(<<_::binary-size(8), rest::binary>>), do: rest

  # decode chunk A's complete frames; whatever remains must be {:more, _}
  defp a_partial_only(a, cut) do
    _ = cut

    case Smalt.Amqp10.FrameDecoder.decode_frame(a) do
      {:ok, _f, rest} -> a_partial_only(rest, cut)
      {:more, _} -> a
      {:error, r} -> flunk("chunk A decode error: #{inspect(r)}")
    end
  end

  # -- claim 5: ETS growth law ---------------------------------------------------

  test "SK5: :amqp10_settled growth bounded by enforced credit law" do
    Process.flag(:trap_exit, true)
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    ref = Process.monitor(conn)

    payload = String.duplicate("p", 512)
    before = :ets.info(:amqp10_settled, :size) || 0

    # 2000 attempted transfers against a 100-credit link: the socket dies at
    # the exhaustion boundary, so sends past the close are tolerated.
    base = 400_000

    for i <- 1..2000 do
      case :gen_tcp.send(sock, transfer_frame(base + i, payload)) do
        :ok -> :ok
        # Transport already dead from the exhaustion cascade (graceful close
        # or RST); the typed boundary is asserted on the connection DOWN.
        {:error, _dead} -> :ok
      end
    end

    # Typed credit exhaustion observed on the connection DOWN.
    assert_receive {:DOWN, ^ref, :process, ^conn,
                    {:child_crash, _session, {:amqp10_link_credit_exhausted, 0, 400_101}}},
                   5_000

    # Bounded-window growth: exactly the 100 granted credits settle into the
    # ledger within the window (growth intent preserved; the 2000-attempt
    # over-run is bounded by the credit law, never unbounded).
    wait_rows!(100, base, System.monotonic_time(:millisecond) + 10_000)

    settled = Enum.count(1..100, fn i -> :ets.member(:amqp10_settled, {0, base + i}) end)
    after_size = :ets.info(:amqp10_settled, :size) || 0

    IO.puts(
      "[SK5] ETS rows before=#{before} after=#{after_size} (+#{after_size - before}) " <>
        "settled_in_window=#{settled}"
    )

    # Growth intent: the ledger grew, by exactly the credit boundary —
    # 100 settled of 2000 attempted, nothing more (enforced credit bounds
    # the growth; eviction would show as < 100).
    assert after_size - before == 100
    assert settled == 100
    refute :ets.member(:amqp10_settled, {0, base + 101})
  end

  defp wait_rows!(wanted, base, deadline) do
    now = System.monotonic_time(:millisecond)
    assert now < deadline, "timed out waiting for ETS rows"

    have =
      Enum.count(1..wanted, fn i ->
        :ets.member(:amqp10_settled, {0, base + i})
      end)

    if have < wanted, do: wait_rows!(wanted, base, deadline)
  end
end
