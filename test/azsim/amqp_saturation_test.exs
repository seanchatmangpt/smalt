defmodule Smalt.Amqp.SaturationTest do
  @moduledoc """
  AZB-16 - AMQP saturation: 4096 queues (plus 8192 variant), 1 sender + 1
  receiver wire link each, 10 msgs/queue - under the i22 atom-flood class.

  Asserts (ticket, binding):

    - atom table growth bounded: `:erlang.system_info(:atom_count)` delta < 64
      per saturation phase (i22 class). The anti-vacuity shim proves the
      assertion has teeth: a behavior-identical `String.to_atom/1` round-trip
      shimmed into the attach (link) path fails this suite - see
      receipts/azb-16-amqp-saturation.md;
    - process count returns to baseline (±1%) after link teardown;
    - zero UNTAGGED `:closed` logger lines (i22 law: `:closed` is terminal,
      silent; a `:closed` line WITHOUT the `[amqp-atom]` tag is an unguarded
      path - that is the failure signal; tagged lines are the fix working);
    - DLQ correct for poisoned messages (MaxDeliveryCountExceeded, body
      preserved);
    - memory returns within 10% of baseline after a full
      `:erlang.garbage_collect` sweep.

  Standing: stress tier (`@moduletag :stress`, excluded from plain `mix test`;
  `mix test test/azsim/amqp_saturation_testexs --include stress`).
  Container acceptance: `docker/burn/container-burn.sh --saturation` runs this
  suite x3 inside the smalt-burn test image under `--cpus 2`.
  """

  use ExUnit.Case, async: false

  @moduletag :stress
  @moduletag timeout: :infinity

  alias Smalt.Amqp.{Connection, FrameCodec, QueueStore}

  @header "AMQP" <> <<0, 1, 0, 0>>
  @sasl_header "AMQP" <> <<3, 1, 0, 0>>

  @test_key "test-shared-key-0123456789abcdef012345"

  @n_queues 4096
  @n_queues_big 8192
  @msgs_per_queue 10
  @link_concurrency 32
  @poison_queues 8
  @atom_budget 64
  @wave_size 256
  @process_budget_pct 1.0
  @mem_budget_pct 10.0

  setup do
    SmaltTest.Env.put_restored(sb_shared_key: @test_key)
    SmaltTest.Lifecycle.ensure_store_up()

    for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_tokens] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    # the CBS claim cache may persist across tests; same reset as
    # test/amqp/connection_test.exs setup
    if GenServer.whereis(Smalt.Amqp.CbsRouter) do
      GenServer.stop(Smalt.Amqp.CbsRouter)
    end

    {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)

    install_closed_probe()

    {:ok, %{}}
  end

  # ===========================================================================
  # Phases
  # ===========================================================================

  test "4096 queues: atom delta bounded, links drain, teardown clean" do
    run_saturation_phase(@n_queues, drained_assert?: true)
  end

  test "TMP single full cycle conn dies on close" do
    baseline = baseline()
    queue = "sat-tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, {:ok, conn}} = Task.async_stream([queue], &queue_cycle/1,
      max_concurrency: 1, timeout: :infinity) |> Enum.to_list() |> hd()
    Process.sleep(100)
    assert !Process.alive?(conn), "single full-cycle conn survived close"
  end

  test "8192 queues: atom delta stays bounded on the warmed table" do
    run_saturation_phase(@n_queues_big, drained_assert?: false)
  end

  test "poisoned messages deadletter with typed reason at saturation scale" do
    baseline = baseline()

    queues =
      for i <- 1..@poison_queues, do: "sat-poison-#{System.unique_integer([:positive])}-#{i}"

    for q <- queues do
      :ets.insert(:smalt_resources, {
        "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns/queues/" <>
          String.downcase(q),
        %{"properties" => %{"maxDeliveryCount" => 2}}
      })
    end

    for q <- queues do
      assert {:ok, _} = QueueStore.enqueue(q, "poison-#{q}")
      assert {:ok, m1, _lock1} = QueueStore.dequeue_matching(q)
      assert :ok = QueueStore.release(q, m1.seq)
      assert {:ok, m2, _lock2} = QueueStore.dequeue_matching(q)
      assert :ok = QueueStore.release(q, m2.seq)
    end

    for q <- queues do
      dlq = QueueStore.deadletter_queue(q)

      for {{^dlq, _}, msg} <- dl_msgs(q) do
        assert msg.annotations["DeadLetterReason"] == "MaxDeliveryCountExceeded"
        assert String.starts_with?(msg.body, "poison-")
      end
    end
  end

  # ===========================================================================
  # Saturation engine
  # ===========================================================================

  defp run_saturation_phase(n_queues, drained_assert?: drained_assert?) do
    baseline = baseline()
    atoms0 = baseline.atoms

    queues = for i <- 1..n_queues, do: "sat-q-#{System.unique_integer([:positive])}-#{i}"

    conns =
      queues
      |> Enum.chunk_every(@wave_size)
      |> Enum.flat_map(fn wave ->
        results =
          wave
          |> Task.async_stream(
            &queue_cycle/1,
            max_concurrency: @link_concurrency,
            timeout: :infinity,
            ordered: false
          )
          |> Enum.to_list()

        wave_conns =
          case Enum.filter(results, &(!match?({:ok, {:ok, _conn}}, &1))) do
            [] ->
              Enum.map(results, fn {:ok, {:ok, conn}} -> conn end)

          bad ->
            flunk("at least one queue cycle failed: #{inspect(hd(bad))}")
        end

        # link teardown is observable per wave: every connection must die on
        # socket close before the next wave claims its CBS slot (the broker
        # caps total claims at 4096 and reaps dead owners lazily — a conn
        # that survives its close is a link leak, the falsifier with teeth).
            assert_conns_dead(wave_conns)
      end)

    for q <- Enum.take(queues, 64) do
      assert QueueStore.queue_settings(q) != :error
    end

    # --- atom budget (the i22 class) ---
    atom_delta = :erlang.system_info(:atom_count) - atoms0

    assert atom_delta < @atom_budget,
           "ATOM_LEAK: atom table grew by #{atom_delta} over #{n_queues} queues " <>
             "(budget #{@atom_budget}) - unbounded atom growth in the link path"

    # --- teardown: bounds after every link is gone ---
    assert_saturation_bounds(baseline, n_queues, "saturation-#{n_queues}")

    if drained_assert? do
      remaining = drained_total(queues)
      assert remaining == 0,
             "expected all #{n_queues * @msgs_per_queue} messages drained, #{remaining} remain"
    end

    assert closed_probe_count() == 0,
           "UNTAGGED :closed logger lines seen: #{closed_probe_count()}"

    :ok
  end

  # Full wire cycle for one queue: own connection, SASL ANONYMOUS + open +
  # begin handshake, CBS token, sender link (10 settled transfers, accepted
  # echoes), receiver link (credit 10, 10 deliveries, batch-accepted), then
  # the socket closes (the client side of the teardown the bounds assert).
  defp queue_cycle(queue) do
    {client, conn} = wire_conn!()

    try do
      :ok = handshake(client)
      assert {:ok, {200, _}} = Smalt.Amqp.CbsRouter.put_token(Smalt.Amqp.CbsRouter, sas_request(queue), conn)

      # --- sender link: 10 settled transfers, accepted echoes -------------
      :ok = send_frame(client, {:attach, %{name: "s-" <> queue, handle: 0, role: false, target: %{address: queue}}})

      assert %{performative: %{performative: :attach}} = recv_frame(client)

      for i <- 1..@msgs_per_queue do
        :ok =
          send_frame(client, {:transfer,
           %{
             handle: 0,
             delivery_id: i,
             delivery_tag: <<0, 0, i::16>>,
             message_format: 0,
             settled: true,
             more: false
           }, {:sections, [{:body_amqp_value, "m-" <> queue <> "-#{i}"}]}})
      end

      for _ <- 1..@msgs_per_queue do
        assert %{performative: %{performative: :disposition, state: :accepted}} = recv_frame(client)
      end

      # --- receiver link: credit 10, drain 10, batch accept ---------------
      :ok = send_frame(client, {:attach, %{name: "r-" <> queue, handle: 1, role: true, source: %{address: queue}}})

      assert %{performative: %{performative: :attach}} = recv_frame(client)
      :ok = send_frame(client, {:flow, %{handle: 1, link_credit: @msgs_per_queue}})

      ids =
        for _ <- 1..@msgs_per_queue do
          tr = recv_frame(client)
          assert %{performative: %{performative: :transfer, handle: 1}} = tr
          tr.performative.delivery_id
        end

      :ok =
        send_frame(client, {:disposition,
         %{role: true, first: Enum.min(ids), last: Enum.max(ids), settled: true, state: :accepted}})

      {:ok, conn}
    after
      # Teardown protocol: an AMQP close performative (server stops its conn
      # process deterministically), then a linger{0} abortive close (RST) —
      # a graceful-only close on 12k rapid connections drives the host into
      # TIME_WAIT ephemeral-port exhaustion (:eaddrnotavail). Data is fully
      # settled before close, so nothing in-flight is lost.
      send_frame(client, {:close, %{}})
      :inet.setopts(client, linger: {true, 0})
      :gen_tcp.close(client)
    end
  end

  # Every connection must be DEAD before the next wave: bounded poll, no
  # fixed sleep. A conn that survives its socket close is a link leak — the
  # process-count falsifier with per-wave teeth.
  defp assert_conns_dead(conns) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    wait_dead = fn wait ->
      if Enum.any?(conns, &Process.alive?/1) do
        if System.monotonic_time(:millisecond) < deadline, do: wait.(wait), else: :timeout
      else
        :all_dead
      end
    end

    case wait_dead.(wait_dead) do
      :all_dead ->
        :ok

      :timeout ->
        # diagnostics: kick each survivor's recv pump, then re-check
        alive = Enum.filter(conns, &Process.alive?/1)
        Enum.each(alive, &send(&1, :recv))
        kick_deadline = System.monotonic_time(:millisecond) + 3000

        wait_kick = fn wk ->
          if Enum.any?(alive, &Process.alive?/1) do
            if System.monotonic_time(:millisecond) < kick_deadline, do: wk.(wk), else: :still_alive_after_kick
          else
            :died_after_kick
          end
        end

        kick_result = wait_kick.(wait_kick)

        first = hd(alive)

        sock_info =
          try do
            st = :sys.get_state(first)
            sock = st[:sock]

            [
              peername: (case :inet.peername(sock) do
                           {:ok, p} -> inspect(p)
                           e -> inspect(e)
                         end),
              sock_count: :erlang.ports(:all)
            ]
          rescue
            _ -> [sock: :unavailable]
          catch
            _, _ -> [sock: :unavailable]
          end

        flunk(
          "LINK_LEAK: #{length(alive)}/#{length(conns)} connection processes still alive after socket close " <>
            "(kick result: #{inspect(kick_result)}; sample #{inspect(first)}: " <>
            "#{inspect(:erlang.process_info(first, [:current_function, :message_queue_len]))} " <>
            "sock=#{inspect(sock_info)})"
        )
    end
  end

  defp dl_msgs(q) do
    dlq = QueueStore.deadletter_queue(q)
    msgs = :ets.match_object(:smalt_sb_messages, {{dlq, :_}, :_})
    assert msgs != [], "queue #{q} never deadlettered"
    msgs
  end

  # ===========================================================================
  # Bounds asserts (atom / process / memory)
  # ===========================================================================

  defp baseline do
    %{
      atoms: :erlang.system_info(:atom_count),
      processes: :erlang.system_info(:process_count),
      memory: :erlang.memory(:processes)
    }
  end

  defp assert_saturation_bounds(baseline, n, phase) do
    :ok = gc_sweep()

    p_after = :erlang.system_info(:process_count)
    leak_pct = abs(p_after - baseline.processes) / max(baseline.processes, 1) * 100

    assert leak_pct <= @process_budget_pct,
           "PROCESS_LEAK[#{phase}]: process count #{baseline.processes} -> #{p_after} " <>
             "after #{n} queue cycles (±1% budget)"

    mem_after = :erlang.memory(:processes)
    mem_pct = abs(mem_after - baseline.memory) / max(baseline.memory, 1) * 100

    assert mem_pct <= @mem_budget_pct,
           "MEMORY_DRIFT[#{phase}]: process memory #{baseline.memory} -> #{mem_after} bytes " <>
             "after #{n} queue cycles (10% budget)"

    :ok
  end

  defp gc_sweep do
    :erlang.garbage_collect()

    for pid <- Process.list() do
      :erlang.garbage_collect(pid)
    end

    :ok
  end

  # Messages left in the queues after the drain (0 expected: the wire receiver
  # took all 10 per queue and the batch disposition settled them).
  defp drained_total(queues) do
    queues
    |> Task.async_stream(
      fn q -> length(:ets.match_object(:smalt_sb_messages, {{q, :_}, :_})) end,
      max_concurrency: 64,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(0, fn {:ok, n}, acc -> acc + n end)
  end

  # ===========================================================================
  # Untagged-:closed logger probe (i22 law)
  # :closed is terminal for the socket - it must exit silently. A line WITHOUT
  # the [amqp-atom] tag is an unguarded path; that is the failure signal.
  # ===========================================================================

  defmodule ClosedProbe do
    @moduledoc "Counts `:closed` logger lines that LACK the [amqp-atom] guard tag."
    @behaviour :logger_handler

    def init(config), do: config

    def log(%{msg: {:text, text}}, _config) do
      try do
        count(IO.iodata_to_binary(text))
      rescue
        _ -> :ok
      end
    end

    def log(%{msg: {:string, s}}, config), do: log(%{msg: {:text, s}}, config)

    def log(%{msg: {fmt, args}} = ev, config),
      do: log(%{ev | msg: {:text, IO.iodata_to_binary(:io_lib.format(fmt, args))}}, config)

    def log(_, _), do: :ok

    defp count(text) when is_binary(text) do
      if String.contains?(text, "request read failed: :closed") and
           not String.contains?(text, "[amqp-atom]") do
        :persistent_term.update_counter({__MODULE__, :untagged_closed}, 1)
      end
    end

    defp count(_), do: :ok
  end

  defp install_closed_probe do
    :persistent_term.put({ClosedProbe, :untagged_closed}, 0)

    case :logger.get_handler_config(:azb16_closed_probe) do
      {:ok, _} ->
        :ok

      {:error, {:not_found, :azb16_closed_probe}} ->
        :logger.add_handler(:azb16_closed_probe, ClosedProbe, %{config: %{}, level_config: %{level: :all}})
    end

    :ok
  end

  defp closed_probe_count, do: :persistent_term.get({ClosedProbe, :untagged_closed}, 0)

  # ===========================================================================
  # Wire harness (per-queue ephemeral listener + raw gen_tcp client)
  # ===========================================================================

  defp wire_conn! do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    accept_task =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listener, 5000)
        {:ok, pid} = Connection.start_link(socket: sock)
        :ok = :gen_tcp.controlling_process(sock, pid)
        {:ok, pid}
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    {:ok, conn} = Task.await(accept_task, 5000)
    :gen_tcp.close(listener)
    {client, conn}
  end

  defp sas_request(queue) do
    sr = "sb://127.0.0.1:5672/" <> queue
    se = System.system_time(:second) + 600

    sig =
      Base.encode64(:crypto.mac(:hmac, :sha256, @test_key, sr <> "\n" <> Integer.to_string(se)))

    token =
      "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    %{
      operation: "put-token",
      type: "servicebus.windows.net:sastoken",
      name: sr,
      expiration: se,
      token: token
    }
  end

  # ===========================================================================
  # Frame helpers (mirrors test/amqp/connection_test.exs)
  # ===========================================================================

  defp handshake(client) do
    :ok = :gen_tcp.send(client, @sasl_header)
    assert {:ok, @sasl_header} = recv_exact(client, 8)

    mech = recv_frame(client)
    assert mech.performative.performative == :sasl_mechanisms
    assert mech.performative.server_mechanisms == [{:symbol, "ANONYMOUS"}]

    :ok = send_frame(client, {:sasl_init, %{mechanism: "ANONYMOUS"}})

    outcome = recv_frame(client)
    assert outcome.performative.performative == :sasl_outcome
    assert outcome.performative.code == 0

    :ok = :gen_tcp.send(client, @header)
    assert {:ok, @header} = recv_exact(client, 8)

    :ok =
      send_frame(client, {:open, %{container_id: "azb16", max_frame_size: 65_536, channel_max: 65_535}})

    assert %{performative: %{performative: :open}} = recv_frame(client)

    :ok =
      send_frame(client, {:begin,
       %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

    assert %{performative: %{performative: :begin}} = recv_frame(client)
    :ok
  end

  defp send_frame(client, {:sasl_init, %{}} = perf) do
    :gen_tcp.send(client, FrameCodec.encode_frame(:sasl, 0, perf))
  end

  defp send_frame(client, perf), do: :gen_tcp.send(client, FrameCodec.encode_frame(:amqp, 0, perf))

  defp recv_until(client, name, timeout \\ 5000) do
    frame = recv_frame(client, timeout)
    if frame.performative.performative == name, do: frame, else: recv_until(client, name, timeout)
  end

  defp recv_frame(client, timeout \\ 5000) do
    frame = do_recv_frame(client, timeout)

    if frame.performative.performative == :flow, do: recv_frame(client, timeout), else: frame
  end

  defp do_recv_frame(client, timeout) do
    {:ok, hdr} = recv_exact(client, 8, timeout)
    <<size::unsigned-integer-size(32), _doff, _type, _channel::16>> = hdr
    {:ok, body} = recv_exact(client, size - 8, timeout)

    case FrameCodec.decode_frame(hdr <> body) do
      {:ok, frame} -> frame
      other -> flunk("frame decode failed: #{inspect(other)}")
    end
  end

  defp recv_exact(client, n, timeout \\ 5000)
  defp recv_exact(_client, 0, _timeout), do: {:ok, <<>>}

  defp recv_exact(client, n, timeout) do
    case :gen_tcp.recv(client, n, timeout) do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> {:ok, <<>>}
    end
  end
end
