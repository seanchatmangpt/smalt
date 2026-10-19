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
  `mix test test/azsim/amqp_saturation_test.exs --include stress`).
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
    # one-time atom set of the phase machinery itself (308 measured) is
    # minted here, unasserted, so the budget below measures queue scaling
    run_saturation_phase(256, drained_assert?: false, bounds_assert?: false)
    run_saturation_phase(@n_queues, drained_assert?: true, bounds_assert?: true)
  end

  test "8192 queues: atom delta stays bounded on the warmed table" do
    run_saturation_phase(256, drained_assert?: false, bounds_assert?: false)
    run_saturation_phase(@n_queues_big, drained_assert?: true, bounds_assert?: true)
  end

  test "poisoned messages deadletter with typed reason at saturation scale" do
    _baseline = warm_baseline(8)

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

  defp run_saturation_phase(n_queues, drained_assert?: drained_assert?, bounds_assert?: ba) do
    baseline = warm_baseline(256)
    atoms0 = baseline.atoms
    mods0 = MapSet.new(:code.all_loaded(), fn {m, _} -> m end)

    queues = for i <- 1..n_queues, do: "sat-q-#{System.unique_integer([:positive])}-#{i}"

    all_conns =
      for wave <- Enum.chunk_every(queues, @wave_size) do
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
          for {:ok, {:ok, conn}} <- results do
            conn
          end

        if length(wave_conns) != length(wave) do
          bad = Enum.find(results, &(!match?({:ok, {:ok, _conn}}, &1)))

          claim_diag =
            if :ets.info(:smalt_cbs_claims) != :undefined do
              rows = :ets.tab2list(:smalt_cbs_claims)
              alive = rows |> Enum.map(fn {{o, _}, _} -> o end) |> Enum.uniq() |> Enum.count(&Process.alive?/1)

              "claims=#{length(rows)} alive_owners=#{alive}"
            else
              "no-table"
            end

          flunk("at least one queue cycle failed: #{inspect(bad)} (#{claim_diag})")
        end

        # link teardown is observable per wave: every connection must die on
        # socket close before the next wave claims its CBS slot (the broker
        # caps total claims at 4096 and reaps dead owners lazily - a conn
        # that survives its close is a link leak, the falsifier with teeth).
        assert_conns_dead(wave_conns)

        # Broker claim-cap constraint (disclosed): CbsRouter caps the table at
        # 4096 claims and reaps dead owners by Process.alive?/1 - which Erlang
        # pid recycling defeats across a 12k-connection storm (a dead conn's
        # pid can be reissued, pinning the claim "alive"). 429
        # CLAIM_CAPACITY is the typed broker refusal; the test restarts the
        # router at wave boundaries for a fresh claims table.
        if GenServer.whereis(Smalt.Amqp.CbsRouter), do: GenServer.stop(Smalt.Amqp.CbsRouter)
        {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)

        wave_conns
      end

    _ = all_conns

    for q <- Enum.take(queues, 64) do
      assert QueueStore.queue_settings(q) != :error
    end

    # --- atom budget (the i22 class) ---
    mods1 = MapSet.new(:code.all_loaded(), fn {m, _} -> m end)
    atom_delta = :erlang.system_info(:atom_count) - atoms0

    if ba do
      assert atom_delta < @atom_budget,
             "ATOM_LEAK: atom table grew by #{atom_delta} over #{n_queues} queues " <>
               "(budget #{@atom_budget}) - unbounded atom growth in the link path; " <>
               "new_modules=#{inspect(MapSet.to_list(MapSet.difference(mods1, mods0)))}"
    end
    if drained_assert? do
      remaining = drained_total(queues)
      if ba do
        assert remaining == 0,
               "expected all #{n_queues * @msgs_per_queue} messages drained, #{remaining} remain"
      end
    end

    if ba do
      assert closed_probe_count() == 0,
             "UNTAGGED :closed logger lines seen: #{closed_probe_count()}"
    end

    # drop harness references before the bounds read: the residual must be
    # broker state, not the test process's retained phase data
    queues = :ok
    _ = queues
    all_conns = :ok
    _ = all_conns

    if ba do
      assert_saturation_bounds(baseline, n_queues, "saturation-#{n_queues}")
    end

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

      # Wait for the server's close echo: the conn process has then actually
      # processed :close (deterministic protocol teardown, no reliance on a
      # blocked recv waking on RST). Bounded - a peer that never echoes is
      # still RST-closed below.
      echo? =
        try do
          frame = recv_frame(client, 2000)
          frame.performative.performative == :close
        rescue
          _ -> false
        catch
          _, _ -> false
        end

      _ = echo?
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
              socktype: (case :inet.sockname(sock) do
                           {:ok, sp} -> inspect(sp)
                           e -> inspect(e)
                         end)
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

  # Baseline after warm-up: force-loads the lazy OTP modules and warms the
  # CbsRouter restart cycle, sweeps GC, and waits for a stable process count
  # so the ±1% / ±10% / atom budgets measure the saturation phase, not
  # harness warm-up. The anti-vacuity shim (one String.to_atom per queue
  # name) still blows the atom budget by orders of magnitude.
  defp warm_baseline(n_warm) do
    # lazy-loaded OTP modules (e.g. :sys, pulled in by the first
    # GenServer stop/restart at a wave boundary) mint their atom sets on
    # first load - force-load before the baseline so the atom budget
    # measures queue-count scaling only.
    :code.ensure_loaded(:sys)

    for _ <- 1..3 do
      if GenServer.whereis(Smalt.Amqp.CbsRouter), do: GenServer.stop(Smalt.Amqp.CbsRouter)
      {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)
    end

    warm = for i <- 1..n_warm, do: "sat-warm-#{System.unique_integer([:positive])}-#{i}"

    warm
    |> Task.async_stream(
      &queue_cycle/1,
      max_concurrency: 16,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.to_list()
    |> Enum.each(fn
      {:ok, {:ok, conn}} -> assert_conns_dead([conn])
      other -> flunk("warm-up cycle failed: #{inspect(other)}")
    end)

    :ok = gc_sweep()

    # process count must be stable before the baseline reads (prior-test
    # leftovers otherwise inflate the baseline and the ±1%/±10% bounds read
    # as false leaks on the DOWN side).
    SmaltTest.AssertEventually.eventually_stays(
      fn -> {:ok, :erlang.system_info(:process_count)} end,
      within_ms: 5000,
      stability_ms: 300,
      interval_ms: 50,
      desc: "stable process count"
    )

    memory = :erlang.memory(:processes)

    if System.get_env("AZB16_MEM_DEBUG") do
      IO.inspect(processes: :erlang.memory(:processes), processes_used: :erlang.memory(:processes_used), system: :erlang.memory(:system), atom: :erlang.memory(:atom), label: "MEM_baseline")
    end

    %{
      atoms: :erlang.system_info(:atom_count),
      processes: :erlang.system_info(:process_count),
      memory: memory
    }
  end

  defp assert_saturation_bounds(baseline, n, phase) do
    :ok = gc_sweep()

    p_after = :erlang.system_info(:process_count)
    leak_pct = abs(p_after - baseline.processes) / max(baseline.processes, 1) * 100

    assert leak_pct <= @process_budget_pct,
           "PROCESS_LEAK[#{phase}]: process count #{baseline.processes} -> #{p_after} " <>
             "after #{n} queue cycles (±1% budget)"

    # teardown/GC quiesce: memory must SETTLE, not snap-read mid-drain
    SmaltTest.AssertEventually.eventually_stays(
      fn -> {:ok, :erlang.memory(:processes)} end,
      within_ms: 20_000,
      stability_ms: 3000,
      interval_ms: 100,
      desc: "process memory settled"
    )

    mem_after = :erlang.memory(:processes)
    mem_pct = abs(mem_after - baseline.memory) / max(baseline.memory, 1) * 100

    if System.get_env("AZB16_MEM_DEBUG") do
      IO.inspect(processes: :erlang.memory(:processes), processes_used: :erlang.memory(:processes_used), system: :erlang.memory(:system), atom: :erlang.memory(:atom), label: "MEM_after_#{phase}")
    end


    if mem_pct > @mem_budget_pct do
      top5 =
        Process.list()
        |> Enum.map(fn pid ->
          info = :erlang.process_info(pid, [:memory, :registered_name]) || [memory: 0]
          {info[:memory] || 0, "#{inspect(pid)}=#{info[:memory] || 0}B#{if info[:registered_name], do: "(#{inspect(info[:registered_name])})", else: ""}"}
        end)
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.take(5)
        |> Enum.map(&elem(&1, 1))
        |> Enum.join(", ")

      flunk(
        "MEMORY_DRIFT[#{phase}]: process memory #{baseline.memory} -> #{mem_after} bytes " <>
          "after #{n} queue cycles (10% budget); top5=[#{top5}]"
      )
    end

    :ok
  end

  defp gc_sweep do
    :erlang.garbage_collect()

    for pid <- Process.list() do
      # major (fullsweep) GC: ordinary incremental GC leaves long-lived
      # processes on their storm-grown heaps, reading as memory drift
      :erlang.garbage_collect(pid, type: :major)
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
        # :ets counter (persistent_term:update_counter/2 does not exist on
        # this OTP - the original counter call was silently killing this
        # handler, which would have made the zero-assert vacuous)
        case :ets.info(:azb16_closed_probe) do
          :undefined ->
            :ok

          _ ->
            :ets.update_counter(:azb16_closed_probe, :untagged, {2, 1}, {:untagged, 0})
        end
      end
    end

    defp count(_), do: :ok
  end

  defp install_closed_probe do
    if :ets.info(:azb16_closed_probe) != :undefined, do: :ets.delete(:azb16_closed_probe)

    :ets.new(:azb16_closed_probe, [:named_table, :public, :set])
    :ets.insert(:azb16_closed_probe, {:untagged, 0})

    case :logger.get_handler_config(:azb16_closed_probe) do
      {:ok, _} ->
        :ok

      {:error, {:not_found, :azb16_closed_probe}} ->
        :logger.add_handler(:azb16_closed_probe, ClosedProbe, %{config: %{}, level_config: %{level: :all}})
    end

    :ok
  end

  defp closed_probe_count do
    case :ets.info(:azb16_closed_probe) do
      :undefined -> 0
      _ -> :ets.lookup_element(:azb16_closed_probe, :untagged, 2)
    end
  end

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
