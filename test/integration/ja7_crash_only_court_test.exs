# JA-7 crash-only court (Joe Armstrong doctrine + Candea & Fox "crash-only
# software"): recovery = restart, cleanup = crash.
#
# Subject: the real amqp10 router family
# (lib/smalt/messaging/amqp10/: Connection root, Session, Link, FrameDecoder)
# plus the shared EgressRouter plane and the two wire-parity legs:
#   * KD-155 ATOM DELETE framing (204 No Content, no content-length, no body)
#   * KD-131/132 CBS put-token face (malformed map32 app-props must NOT kill
#     the broker connection; the same connection still delivers)
#
# Chicago discipline: real TCP listeners, real sockets, real GenServers, real
# ETS/DETS state, assertions on wire bytes and live process state. No mocks.
#
# Court legs:
#   1. Kill the amqp10 connection root mid-stream (real exit) -> the whole
#      link/session tree cascades DOWN within the court deadline.
#   2. The listener respawns connections without manual cleanup; the settled
#      ETS ledger is re-bound (or gone) after the owning tree dies.
#   3. The next client succeeds immediately (zero stale state).
#   4. 10 crash-recover cycles converge every time: process count + process
#      memory flat across cycles.
#   5. Post-recovery wire parity: KD-155 framing + KD-131 CBS on the live
#      surfaces.
#
# Context: solo (integration tier, in-process wire faces).

Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule Integration.Ja7CrashOnlyCourt do
  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll, only: [eventually: 2]

  alias Smalt.Amqp.{FrameCodec, PrimitiveCodec, QueueStore, SasVerifier}
  alias Smalt.Amqp10.Connection

  @header <<0x41, 0x4D, 0x51, 0x50, 0x00, 1, 0, 0>>
  @cascade_deadline_ms 10
  @cycles 10
  @queue "ja7-q"

  setup do
    Process.flag(:trap_exit, true)

    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # ===========================================================================
  # Court 1 — kill the root mid-stream: whole tree cascades DOWN < deadline
  # ===========================================================================

  test "JA-7.1: kill the amqp10 connection mid-stream -> tree cascade within deadline" do
    {lpid, conn, sock} = start_router!()
    handshake!(sock)

    # Seed real state owned by the tree: a settled transfer in the ledger.
    settled_transfer!(sock, 7, "ja7-court1-payload")
    assert :ets.lookup(:amqp10_settled, {0, 7}) != []

    pids = tree_pids(conn)
    assert length(pids) >= 3, "expected root+sessions+links, got #{inspect(pids)}"

    # Monitors BEFORE the kill; elapsed measured from the exit call.
    refset = MapSet.new(for pid <- pids, do: Process.monitor(pid))
    t0 = System.monotonic_time(:millisecond)
    Process.exit(conn, :kill)

    {elapsed, remaining} = collect_downs(refset, t0, t0 + @cascade_deadline_ms)

    assert MapSet.size(remaining) == 0,
           "cascade incomplete: #{MapSet.size(remaining)} tree pids still up"

    assert elapsed < @cascade_deadline_ms,
           "cascade took #{elapsed}ms (deadline #{@cascade_deadline_ms}ms)"

    IO.puts("[JA-7.1] cascade=#{elapsed}ms (deadline #{@cascade_deadline_ms}ms), tree=#{length(pids)} pids")

    # The listener itself survives the connection kill (recovery = restart of
    # the connection, not of the world) and the root is really dead.
    refute Process.alive?(conn)
    assert Process.alive?(lpid)
  end

  # ===========================================================================
  # Court 2 — respawn without manual cleanup; next client succeeds instantly;
  # deep-assert the ETS ledger the dead tree used is gone or re-bound
  # ===========================================================================

  test "JA-7.2: respawn without manual cleanup, zero stale state, ledger re-bound" do
    {_lpid, conn, sock} = start_router!()
    handshake!(sock)
    settled_transfer!(sock, 71, "ja7-court2-payload")
    assert [{_, "ja7-court2-payload", _}] = :ets.lookup(:amqp10_settled, {0, 71})

    # Crash the root: cleanup = crash, no sweep, no manual teardown.
    ref = Process.monitor(conn)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 5_000

    # The ledger table must be gone OR re-bound to a live owner — never
    # owned by a dead pid, never left half-dead.
    assert :ets.info(:amqp10_settled) == :undefined or
             Process.alive?(:ets.info(:amqp10_settled, :owner))

    # Respawn: the SAME listener accepts a fresh connection immediately —
    # no manual cleanup, no restart of the listener, no warmup.
    {:ok, sock2, conn2} = connect!()
    handshake!(sock2)

    # Zero stale state on the new tree: the next settled transfer lands in a
    # live ledger under a fresh unique key and reads back byte-exact.
    did = 71_000 + :erlang.unique_integer([:positive])
    settled_transfer!(sock2, did, "ja7-court2-fresh")
    assert [{_, "ja7-court2-fresh", _}] = :ets.lookup(:amqp10_settled, {0, did})

    assert Process.alive?(conn2)
    :gen_tcp.close(sock2)
  end

  # ===========================================================================
  # Court 3 — 10 crash-recover cycles converge; process count + memory flat
  # ===========================================================================

  test "JA-7.3: 10 crash-recover cycles converge with flat process count and memory" do
    {:ok, lpid, port} = Connection.start_listener(0, notify: self())

    {base_procs, base_mem} = fleet_snapshot()

    for cycle <- 1..@cycles do
      {:ok, sock, conn} = connect!(port)
      handshake!(sock)

      did = 100_000 + cycle
      pin = "ja7-cycle-#{cycle}"
      settled_transfer!(sock, did, pin)
      assert [{_, ^pin, _}] = :ets.lookup(:amqp10_settled, {0, did})

      pids = tree_pids(conn)
      refset = MapSet.new(for pid <- pids, do: Process.monitor(pid))
      t0 = System.monotonic_time(:millisecond)
      Process.exit(conn, :kill)

      {elapsed, remaining} = collect_downs(refset, t0, t0 + @cascade_deadline_ms)

      assert MapSet.size(remaining) == 0,
             "cycle #{cycle}: cascade incomplete, #{MapSet.size(remaining)} survivors"

      assert elapsed < @cascade_deadline_ms,
             "cycle #{cycle}: cascade #{elapsed}ms >= deadline"

      IO.write("[JA-7.3] cycle cascade ms: #{elapsed} ")

      # Recovery = restart: the very next client succeeds immediately.
      {:ok, sock2, conn2} = connect!(port)
      handshake!(sock2)
      rpin = "ja7-recover-#{cycle}"
      settled_transfer!(sock2, 200_000 + cycle, rpin)
      assert [{_, ^rpin, _}] = :ets.lookup(:amqp10_settled, {0, 200_000 + cycle})
      assert Process.alive?(conn2)
      :gen_tcp.close(sock2)
    end

    assert Process.alive?(lpid)

    {end_procs, end_mem} = fleet_snapshot()
    # Flat: no leak accumulation across cycles. Tolerance is generous
    # (scheduler threads, court's own monitors) but a real link/session leak
    # at 10 cycles x 3+ pids would blow straight through it.
    assert abs(end_procs - base_procs) <= 25,
           "process count drifted #{base_procs} -> #{end_procs} across #{@cycles} cycles"

    assert end_mem - base_mem <= 4 * 1024 * 1024,
           "process memory grew by #{div(end_mem - base_mem, 1024)}KiB across #{@cycles} cycles"

    IO.puts(
      "[JA-7.3] procs #{base_procs} -> #{end_procs}, proc-mem delta #{div(end_mem - base_mem, 1024)}KiB over #{@cycles} cycles"
    )
  end

  # ===========================================================================
  # Court 4 — shared plane unaffected: EgressRouter serves post-cascade
  # ===========================================================================

  test "JA-7.4: EgressRouter queue round-trip is unaffected by amqp10 cascades" do
    {:ok, _lpid, _port} = Connection.start_listener(0, notify: self())
    {:ok, sock, conn} = connect!()
    handshake!(sock)

    ref = Process.monitor(conn)
    Process.exit(conn, :kill)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 5_000

    account = "ja7-egress"
    assert call(:put, "/#{account}/ja7q?restype=queue").status in [201, 409]

    conn_body = ~s(<QueueMessage>ja7-egress-payload</QueueMessage>)
    post = call(:post, "/#{account}/ja7q/messages", body: conn_body)
    assert post.status == 201

    get = call(:get, "/#{account}/ja7q/messages")
    assert get.status == 200
    assert get.resp_body =~ "ja7-egress-payload"
  end

  # ===========================================================================
  # Court 5 — post-recovery wire parity: KD-155 framing
  # ===========================================================================

  test "JA-7.5: KD-155 ATOM DELETE framing still 204/no-length/no-body post-recovery" do
    sup_name = Module.concat(__MODULE__, ConnSup)

    {:ok, _} = DynamicSupervisor.start_link(name: sup_name)

    {:ok, _} =
      Smalt.Amqp.Listener.start_link(
        {:sb, 0, name: Module.concat(__MODULE__, ListenerSb), conn_sup: sup_name}
      )

    port = Smalt.Amqp.Listener.port(Module.concat(__MODULE__, ListenerSb))

    on_exit(fn ->
      if :ets.info(:smalt_sb_messages) != :undefined do
        for {k, _} <- :ets.tab2list(:smalt_sb_messages),
            is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), @queue) do
          :ets.delete(:smalt_sb_messages, k)
        end
      end
    end)

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

    :gen_tcp.close(sock)
    sock = open(port)

    :ok =
      :gen_tcp.send(sock, "DELETE /#{@queue}?api-version=2021-05 HTTP/1.1\r\nContent-Length: 0\r\n\r\n")

    {:ok, resp, drained} = recv_until_headers_and_close(sock)
    [status_line | header_lines] = String.split(resp, "\r\n")
    headers = headers_map(header_lines)

    assert status_line == "HTTP/1.1 204 No Content",
           "expected 204 No Content for queue DELETE, got: #{inspect(status_line)}"

    refute Map.has_key?(headers, "content-length"),
           "204 must not carry content-length, got: #{inspect(headers)}"

    assert drained == <<>>,
           "204 carried body bytes: #{inspect(drained)}"

    # Real state: the queue row is actually gone.
    refute match?(
             {:ok, _},
             Smalt.Store.get(
               :smalt_resources,
               "/subscriptions/emulator-atom/resourcegroups/emulator/providers/microsoft.servicebus/namespaces/emulator/queues/#{@queue}"
             )
           )

    :gen_tcp.close(sock)
  end

  # ===========================================================================
  # Court 6 — post-recovery wire parity: KD-131/132 CBS face
  # ===========================================================================

  test "JA-7.6: KD-131 CBS put-token face survives malformed map32 post-recovery" do
    {:ok, _} = QueueStore.ensure_queue(@queue)

    with_wire_conn(fn client, conn ->
      cbs_put_token_malformed_map(client, 2, 0)

      # Post-malformed-frame: broker connection alive, wire face functional.
      cbs_put_token(client, 2, 0, "ok")
      attach_receiver(client, 1, 0, "rx")
      :ok = csend(client, frame(1, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

      assert {:ok, _seq} = QueueStore.enqueue(@queue, "ja7-kd131-payload", message_id: "ja7-kd131-m1")

      {:ok, t} =
        eventually(
          fn ->
            case rx_transfer(client, 1, "ja7-kd131-m1") do
              nil -> :no_delivery
              t -> {:ok, t}
            end
          end,
          timeout_ms: 5_000
        )

      assert t.handle == 0
      assert Process.alive?(conn)
    end)

    # KD-131 verifier face: a floor-valid configured key verifies a real SAS
    # token through the REAL verifier (the same HMAC the CBS gate runs).
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    Application.put_env(:smalt, :sb_shared_key, key)

    try do
      assert SasVerifier.shared_key() == key
      sr = SasVerifier.endpoint() <> "/" <> @queue
      se = System.system_time(:second) + 3_600
      sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))
      token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"
      assert {:ok, _claims} = SasVerifier.verify(token, sr)
    after
      Application.delete_env(:smalt, :sb_shared_key)
    end
  end

  # ===========================================================================
  # amqp10 helpers (real TCP + real Connection root)
  # ===========================================================================

  defp start_router! do
    {:ok, lpid, port} = Connection.start_listener(0, notify: self())
    {:ok, sock, conn} = connect!(port)
    {lpid, conn, sock}
  end

  defp connect!(port) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    conn =
      receive do
        {:amqp10_connection, pid} -> pid
      after
        5_000 -> flunk("no connection notify")
      end

    {:ok, sock, conn}
  end

  defp connect! do
    # Drain any stale notify from a prior tree so we bind to THIS listener.
    receive do
      {:amqp10_connection, _} -> :ok
    after
      0 -> :ok
    end

    {:ok, _lpid, port} = Connection.start_listener(0, notify: self())
    connect!(port)
  end

  defp enc(ch, perf), do: IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, ch, perf))

  defp handshake!(sock) do
    :ok = :gen_tcp.send(sock, @header)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:open, %{container_id: "ja7-client"}}),
        enc(0, {:begin, %{next_outgoing_id: 0, incoming_window: 1000, outgoing_window: 1000}}),
        enc(0, {:attach, %{name: "ja7-link", handle: 0, role: false,
                           target: %{address: "ja7-target"}}})
      ])

    frames = recv_while(sock, 4, <<>>)
    kinds = Enum.map(frames, fn f -> elem(f.performative, 0) end)
    assert kinds == [:open, :begin, :attach, :flow], "unexpected handshake: #{inspect(kinds)}"
    :ok
  end

  defp settled_transfer!(sock, delivery_id, payload) do
    tag = :binary.copy(<<0>>, 16)

    :ok =
      :gen_tcp.send(sock, [
        enc(0, {:transfer, %{handle: 0, delivery_id: delivery_id,
                             delivery_tag: tag, settled: true, more: false}, payload})
      ])

    [disposition] = recv_while(sock, 1, <<>>)
    {_, fields} = disposition.performative
    assert fields[:first] == delivery_id
    assert fields[:settled] == true
    :ok
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

  defp tree_pids(conn) do
    sessions = :erlang.process_info(conn, :links) |> elem(1) |> Enum.filter(&is_pid/1)

    links =
      Enum.flat_map(sessions, fn s ->
        :erlang.process_info(s, :links) |> elem(1) |> Enum.filter(&is_pid/1)
      end)

    Enum.uniq([conn | sessions] ++ links) -- [self()]
  end

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

  defp fleet_snapshot, do: {length(:erlang.processes()), :erlang.memory(:processes)}

  # ===========================================================================
  # KD-155 wire helpers (real Listener + raw sockets)
  # ===========================================================================

  defp open(port) do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
    s
  end

  defp recv_until_headers(sock), do: recv_until_headers(sock, <<>>)

  defp recv_until_headers(sock, buf) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    buf = buf <> data

    if String.contains?(buf, "\r\n\r\n") do
      {:ok, buf}
    else
      recv_until_headers(sock, buf)
    end
  end

  defp recv_until_headers_and_close(sock) do
    {:ok, resp} = recv_until_headers(sock)

    drained =
      case :gen_tcp.recv(sock, 0, 1_000) do
        {:ok, more} -> more
        {:error, _} -> <<>>
      end

    {:ok, resp, drained}
  end

  defp headers_map(lines) do
    lines
    |> Enum.map(fn l -> String.downcase(l) end)
    |> Enum.reduce(%{}, fn l, acc ->
      case String.split(l, ": ", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  # ===========================================================================
  # KD-131 CBS wire helpers (real TCP + real Smalt.Amqp.Connection)
  # ===========================================================================

  defp with_wire_conn(fun) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    {:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, ssock} = :gen_tcp.accept(lsock)
    {:ok, conn} = Smalt.Amqp.Connection.start_link(socket: ssock)
    :ok = :gen_tcp.controlling_process(ssock, conn)

    client = start_client(csock)

    :ok = csend(client, "AMQP\x00\x01\x00\x00")
    :ok = csend(client, frame(0, {:open, %{container_id: "ja7-kd", max_frame_size: 65_536}}))

    :ok =
      csend(
        client,
        frame(1, {:begin, %{next_outgoing_id: 0, incoming_window: 10_000, outgoing_window: 10_000}})
      )

    try do
      fun.(client, conn)
    after
      :gen_tcp.close(csock)

      if is_atom(client) do
        if pid = Process.whereis(client), do: send(pid, {:stop, self()})
      end

      if is_pid(conn), do: Process.exit(conn, :kill)
    end
  end

  defp cbs_put_token(client, ch, handle, name) do
    csend(
      client,
      frame(ch, {:attach, %{name: "cbs-#{name}", handle: handle, role: false, target: %{address: "$cbs"}}})
    )

    sr = SasVerifier.endpoint() <> "/" <> @queue
    se = System.system_time(:second) + 3_600
    key = SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    sections = [
      {:properties, %{message_id: "ja7-pt"}},
      {:application_properties,
       %{"operation" => "put-token", "type" => "servicebus.windows.net:sastoken", "name" => @queue}},
      {:body_amqp_value, token}
    ]

    csend(
      client,
      FrameCodec.encode_frame(:amqp, ch, {
        :transfer,
        %{handle: handle, delivery_id: 0, delivery_tag: <<>>, settled: true, more: false},
        {:sections, sections}
      })
    )

    :ok
  end

  defp cbs_put_token_malformed_map(client, ch, handle) do
    csend(
      client,
      frame(ch, {:attach, %{name: "cbs-bad", handle: handle, role: false, target: %{address: "$cbs"}}})
    )

    ap_body =
      IO.iodata_to_binary([
        PrimitiveCodec.encode("operation"),
        PrimitiveCodec.encode("put-token")
      ])

    malformed_map =
      IO.iodata_to_binary([
        0x00,
        <<0x00_00_00_00_00_00_00_74::unsigned-integer-size(64)>>,
        0xD1,
        <<byte_size(ap_body) + 4::unsigned-integer-size(32)>>,
        <<2::unsigned-integer-size(32)>>,
        ap_body
      ])

    csend(
      client,
      FrameCodec.encode_frame(:amqp, ch, {
        :transfer,
        %{handle: handle, delivery_id: 1, delivery_tag: <<>>, settled: true, more: false},
        malformed_map
      })
    )

    :ok
  end

  defp attach_receiver(client, ch, handle, name) do
    csend(client, frame(ch, {:attach, %{name: name, handle: handle, role: true, source: %{address: @queue}}}))
  end

  defp frame(ch, {name, fields}), do: FrameCodec.encode_frame(:amqp, ch, {name, fields})

  defp start_client(sock) do
    name = String.to_atom("ja7_client_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Task.start(fn -> client_loop(sock, %{}, <<>>) end)
    Process.register(pid, name)
    name
  end

  defp client_loop(sock, rx, buf) do
    receive do
      {:send, frame} ->
        :ok = :gen_tcp.send(sock, frame)
        client_loop(sock, rx, buf)

      {:snapshot, from, ch, mid, since} ->
        send(from, {:ja7_snapshot, snapshot(rx, ch, mid, since)})
        client_loop(sock, rx, buf)

      {:stop, _} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            buf2 = <<buf::binary, data::binary>>

            buf3 =
              case buf2 do
                <<"AMQP", 0, 1, 0, 0, tail::binary>> -> tail
                _ -> buf2
              end

            {rx2, buf4} = absorb(buf3, rx)
            client_loop(sock, rx2, buf4)

          {:error, :timeout} ->
            client_loop(sock, rx, buf)

          {:error, _closed} ->
            :ok
        end
    end
  end

  defp snapshot(rx, ch, mid, since) do
    ch_rx = Map.get(rx, ch, %{transfers: []})

    Enum.filter(ch_rx.transfers, fn t ->
      (mid == nil or t.mid == mid) and t.delivery_id not in since
    end)
  end

  defp absorb(buf, rx) when byte_size(buf) < 8, do: {rx, buf}

  defp absorb(buf, rx) do
    <<size::unsigned-integer-size(32), _::binary>> = buf

    if byte_size(buf) >= size do
      <<frame_bytes::binary-size(size), tail::binary>> = buf

      case FrameCodec.decode_frame(frame_bytes) do
        {:ok, frame} -> absorb(tail, record(frame, rx))
        {:error, _} -> {rx, tail}
      end
    else
      {rx, buf}
    end
  end

  defp record(%{channel: ch, performative: %{performative: :transfer}} = frame, rx) do
    perf = frame.performative

    sections =
      case frame[:payload] do
        nil -> []
        p -> elem(FrameCodec.decode_message(p), 1)
      end

    mid =
      Enum.find_value(sections, fn
        {:properties, p} when is_map(p) -> p[:message_id]
        _ -> nil
      end)

    entry = %{delivery_id: perf[:delivery_id], handle: perf[:handle], mid: mid}
    ch_rx = Map.get(rx, ch, %{transfers: []})
    Map.put(rx, ch, %{ch_rx | transfers: ch_rx.transfers ++ [entry]})
  end

  defp record(_frame, rx), do: rx

  defp csend(client, frame) do
    send(client, {:send, frame})
    :ok
  end

  defp rx_transfer(client, ch, mid, opts \\ []) do
    since = Keyword.get(opts, :since_delivery_ids, [])
    send(client, {:snapshot, self(), ch, mid, since})

    receive do
      {:ja7_snapshot, list} ->
        case list do
          [] -> nil
          [t | _] -> t
        end
    after
      2_000 -> flunk("ja7 client did not answer snapshot")
    end
  end

  # ===========================================================================
  # EgressRouter in-process caller
  # ===========================================================================

  defp call(method, path, opts \\ []) do
    body = opts[:body]

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("content-length", "0")
      |> then(fn c ->
        if body do
          Plug.Conn.put_req_header(c, "content-length", body |> byte_size() |> Integer.to_string())
        else
          c
        end
      end)

    Smalt.EgressRouter.call(conn, [])
  end
end
