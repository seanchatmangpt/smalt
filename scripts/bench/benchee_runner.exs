# scripts/bench/benchee_runner.exs — ERRC lane 2 (Raise): benchee-driven BEAM
# microbenchmarks mirroring the hand-rolled b7/b8/b9 scenarios.
#
# The hand-rolled scripts (b7_store_beam.exs, b8_amqp_beam.exs, b9_eh_beam.exs)
# stay untouched as the falsifier records; this runner emits benchee's statistics
# into the same JSONL row shape (ops_per_sec + p50/p95/p99 ms from benchee's
# run_time percentiles) into NEW files so the bench dir keeps both:
#
#   docs/jira/v26.10.14/bench/b7b-store-beam.jsonl
#   docs/jira/v26.10.14/bench/b8b-amqp-beam.jsonl
#   docs/jira/v26.10.14/bench/b9b-eh-beam.jsonl
#
# Run (one lane at a time):
#   MIX_ENV=test mix run --no-start scripts/bench/benchee_runner.exs b7b
#   MIX_ENV=test mix run --no-start scripts/bench/benchee_runner.exs b8b
#   MIX_ENV=test mix run --no-start scripts/bench/benchee_runner.exs b9b
#   MIX_ENV=test mix run --no-start scripts/bench/benchee_runner.exs all
#
# BENCHEE_TIME / BENCHEE_WARMUP env vars override the 5s/2s defaults.

{opts, _argv, _invalid} = OptionParser.parse(System.argv(), strict: [lane: :string])
lane_arg = opts[:lane] || Enum.at(System.argv(), 0) || "all"

Application.put_env(:smalt_bench, :bench_time, String.to_integer(System.get_env("BENCHEE_TIME") || "5"))
Application.put_env(:smalt_bench, :bench_warmup, String.to_integer(System.get_env("BENCHEE_WARMUP") || "2"))

defmodule SmaltBench.Runner do
  @moduledoc false

  alias Smalt.Amqp.{FrameCodec, LockManager, QueueStore}
  alias Smalt.Messaging.EventHubs, as: EH

  @body_1k :binary.copy("x", 1024)
  @n_queues 13

  # -- JSONL emission (same row shape as the hand-rolled lanes) -----------------

  def machine_spec do
    {cpu_out, 0} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
    {ram_out, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])

    %{
      "cpu" => String.trim(cpu_out),
      "cores" => :erlang.system_info(:logical_processors_available),
      "ram_gb" => String.trim(ram_out) |> String.to_integer() |> div(1024 * 1024 * 1024),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "darwin" => :os.type() |> elem(1) |> to_string()
    }
  end

  defp emit(path, lane, surface, op, n, scenario, extra, ips_mult \\ 1) do
    st = scenario.run_time_data.statistics

    p = fn key ->
      case st.percentiles[key] do
        nil -> 0.0
        us -> Float.round(us / 1000.0, 3)
      end
    end

    rec =
      Map.merge(
        %{
          lane: lane,
          surface: surface,
          op: op,
          n: n,
          ops_per_sec: Float.round(st.ips * ips_mult * 1.0, 1),
          p50_ms: p.(50),
          p95_ms: p.(95),
          p99_ms: p.(99),
          errors: 0,
          benchee: %{
            time_s: Application.fetch_env!(:smalt_bench, :bench_time),
            warmup_s: Application.fetch_env!(:smalt_bench, :bench_warmup),
            samples: st.sample_size,
            run_time_mean_ms: Float.round(st.average / 1000.0, 3),
            run_time_std_dev_ratio: Float.round(st.std_dev_ratio, 3),
            ips_std_dev_ratio: Float.round(st.std_dev_ips / max(st.ips, 1.0), 3),
            median_ms: Float.round(st.median / 1000.0, 3)
          },
          machine: machine_spec()
        },
        extra
      )

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(rec) <> "\n", [:append])
    IO.puts("[benchee] #{lane}/#{op}: #{rec.ops_per_sec} ops/s p50=#{rec.p50_ms}ms p99=#{rec.p99_ms}ms samples=#{st.sample_size}")
  end

  defp run_suite(jobs, path, lane, surface, name_to_op) do
    suite =
      Benchee.run(
        jobs,
        warmup: Application.fetch_env!(:smalt_bench, :bench_warmup),
        time: Application.fetch_env!(:smalt_bench, :bench_time),
        memory_time: 0,
        reduction_time: 0,
        parallel: 1,
        print: [configuration: false, fast_warning: false],
        formatters: [fn _suite -> :ok end]
      )

    Enum.each(suite.scenarios, fn scenario ->
      op = Map.fetch!(name_to_op, scenario.job_name)
      emit(path, lane, surface, op, scenario.run_time_data.statistics.sample_size, scenario, %{})
    end)
  end

  # -- lane b7b: Smalt.Store put / get / compare_and_swap -----------------------

  def run_b7b(path) do
    {:ok, _} = Smalt.Store.start_link([])
    tbl = :smalt_resources
    batch = System.unique_integer([:positive])
    counter = :atomics.new(1, signed: true)

    # 100-key JIT warmup + bounded 100k-key keyspace (mirrors b7's ~120k scale;
    # keys cycle so the table cannot grow unbounded across benchee samples).
    Enum.each(1..100, fn i -> Smalt.Store.put(tbl, "b7b-warm-#{batch}-#{i}", %{"v" => i}) end)

    Enum.each(1..100_000, fn i ->
      Smalt.Store.put(tbl, "b7b-put-#{batch}-#{i}", %{"v" => i, "pad" => String.duplicate("x", 64)})
    end)

    cas_keys = Enum.map(1..100, fn i -> "b7b-cas-#{batch}-#{i}" end)
    Enum.each(cas_keys, fn k -> Smalt.Store.put(tbl, k, 0) end)

    jobs = %{
      "put" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        Smalt.Store.put(tbl, "b7b-put-#{batch}-#{rem(i, 100_000) + 1}", %{"v" => i, "pad" => String.duplicate("x", 64)})
      end,
      "get" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        Smalt.Store.get(tbl, "b7b-put-#{batch}-#{rem(i, 100_000) + 1}")
      end,
      "compare_and_swap" => fn ->
        k = Enum.at(cas_keys, rem(:atomics.add_get(counter, 1, 1), 100))
        {:ok, cur} = Smalt.Store.get(tbl, k)
        Smalt.Store.compare_and_swap(tbl, k, cur, cur + 1)
      end
    }

    run_suite(jobs, path, "b7b", "store-beam", %{
      "put" => "put",
      "get" => "get",
      "compare_and_swap" => "compare_and_swap"
    })

    Smalt.Store.clear()
    IO.puts("[benchee] b7b done -> #{path}")
  end

  # -- lane b8b: QueueStore enqueue / dequeue+ack / session RT / codec ----------

  def run_b8b(path) do
    tables = [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_sessions, :smalt_resources]

    Enum.each(tables, fn t ->
      if :ets.info(t) == :undefined do
        :ets.new(t, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      end

      :ets.delete_all_objects(t)
    end)

    :ets.insert(:smalt_resources, {"bench-sess-q", %{props: %{"requiresSession" => true}}})

    case Process.whereis(QueueStore) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _} = QueueStore.start_link([])

    qs = Enum.map(0..(@n_queues - 1), &"bench-q-#{&1}")

    Enum.each(qs, fn q ->
      {:ok, _} = QueueStore.ensure_queue(q)
    end)

    counter = :atomics.new(1, signed: true)

    # Suite A: empty-queue scenarios (enqueue at depth ~1, e2e RT, session RT,
    # codec). The queue scan is O(depth), so the dequeue prefill must not be
    # resident while these run.
    clean_jobs = %{
      # enqueue at depth ~1 (enqueue+complete) — mirrors b8's enqueue_1kib_depth1.
      "enqueue_depth1" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        q = Enum.at(qs, rem(i, @n_queues))
        {:ok, seq} = QueueStore.enqueue(q, @body_1k, app_props: %{"n" => i})
        :ok = QueueStore.complete(q, seq)
      end,
      # full enqueue -> dequeue -> complete round trip — mirrors e2e_store_rt_1kib.
      "e2e" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        q = Enum.at(qs, rem(i, @n_queues))
        {:ok, _} = QueueStore.enqueue(q, @body_1k, app_props: %{"n" => i})
        {:ok, msg, _} = QueueStore.dequeue_matching(q, lock_duration_ms: 60_000)
        :ok = QueueStore.complete(q, msg.seq)
      end,
      # session round trip including the per-iteration enqueue (hand-rolled b8
      # pre-enqueued 4000 session messages outside the timer — disclosed caveat
      # in the comparison receipt)
      "session_rt" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        q = "bench-sess-q"
        sid = "s-#{rem(i, 4096)}"
        {:ok, _} = QueueStore.enqueue(q, @body_1k, session_id: sid)
        {:ok, _} = LockManager.session_acquire(q, sid, duration_ms: 60_000)
        {:ok, msg, _} = QueueStore.dequeue_matching(q, session_id: sid, lock_duration_ms: 60_000)
        :ok = QueueStore.complete(q, msg.seq)
        :ok = LockManager.session_release(q, sid)
      end,
      # pure codec — mirrors b8's frame_transfer_encdec
      "frame_transfer_encdec" => fn ->
        i = :atomics.add_get(counter, 1, 1)

        sections = [
          {:header, %{durable: true}},
          {:application_properties, %{"n" => i}},
          {:body_data, @body_1k}
        ]

        f =
          IO.iodata_to_binary(
            FrameCodec.encode_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: i}, {:sections, sections}})
          )

        {:ok, %{payload: p}} = FrameCodec.decode_frame(f)
        {:ok, _} = FrameCodec.decode_message(p)
      end
    }

    run_suite(clean_jobs, path, "b8b", "amqp-beam", %{
      "enqueue_depth1" => "enqueue_1kib_depth1",
      "e2e" => "e2e_store_rt_1kib",
      "session_rt" => "session_delivery_rt",
      "dequeue_ack" => "dequeue_ack_1kib",
      "frame_transfer_encdec" => "frame_transfer_encdec"
    })

    # Suite B: prefill 1000 msgs/queue, then dequeue+ack (depth declines across
    # the run; refills one message whenever a queue reads empty).
    Enum.each(qs, fn q ->
      Enum.each(1..1000, fn i -> {:ok, _} = QueueStore.enqueue(q, @body_1k, app_props: %{"pre" => i}) end)
    end)

    drain_jobs = %{
      "dequeue_ack" => fn ->
        i = :atomics.add_get(counter, 1, 1)
        q = Enum.at(qs, rem(i, @n_queues))

        case QueueStore.dequeue_matching(q, lock_duration_ms: 60_000) do
          {:ok, msg, _} -> :ok = QueueStore.complete(q, msg.seq)
          :empty -> {:ok, _} = QueueStore.enqueue(q, @body_1k, app_props: %{"refill" => i})
        end
      end
    }

    run_suite(drain_jobs, path, "b8b", "amqp-beam", %{
      "dequeue_ack" => "dequeue_ack_1kib"
    })

    Enum.each(qs, &drain_queue(&1, 0))
    IO.puts("[benchee] b8b done -> #{path}")
  end


  defp drain_queue(q, acc) do
    case QueueStore.dequeue_matching(q, lock_duration_ms: 60_000) do
      {:ok, msg, _lock} ->
        :ok = QueueStore.complete(q, msg.seq)
        drain_queue(q, acc + 1)

      :empty ->
        acc
    end
  end

  # -- lane b9b: EventHubs send / drain / next_sequence / reserve / locks -------

  def run_b9b(path) do
    {:ok, _} = Application.ensure_all_started(:smalt)
    EH.ensure_tables()

    uniq = System.unique_integer([:positive])
    part_send = "ns/b9b-hub/send-#{uniq}"
    part_seq = "ns/b9b-hub/seq-#{uniq}"
    part_res = "ns/b9b-hub/res-#{uniq}"
    lock_q = "ns/b9b-queue"

    # pre-ingest 2500 events for the drain scenario (5 batches of 500)
    Enum.each(1..2500, fn _i -> {:ok, _, _} = EH.send_event(part_send, @body_1k) end)

    drain_counter = :atomics.new(1, signed: true)
    lock_counter = :atomics.new(1, signed: true)

    jobs = %{
      "send_event" => fn -> {:ok, _, _} = EH.send_event(part_send, @body_1k) end,
      # one batch read of up to 500 events; ops_per_sec in the JSONL row is
      # normalized to EVENTS/sec (ips x 500) to match the hand-rolled b9 metric.
      # Sweeps 0->2500 then wraps.
      "receive_events_drain" => fn ->
        pos = :atomics.add_get(drain_counter, 1, 1)
        after_seq = rem(pos - 1, 5) * 500
        evs = EH.receive_events(part_send, after_seq, 500)
        _ = List.last(evs)
        :ok
      end,
      "next_sequence" => fn -> {:ok, _} = EH.next_sequence(part_seq) end,
      "reserve_processing" => fn -> :ok = EH.reserve_processing("b9b-group", part_res, :b9b_owner, 60_000) end,
      "lock_acquire_release" => fn ->
        seq = :atomics.add_get(lock_counter, 1, 1)
        {:ok, lock} = LockManager.acquire(lock_q, seq, duration_ms: 60_000)
        :ok = LockManager.release(lock.lock_token)
      end
    }

    name_to_op = %{
      "send_event" => "send_event_1kib",
      "receive_events_drain" => "receive_events_drain_1kib",
      "next_sequence" => "next_sequence",
      "reserve_processing" => "reserve_processing",
      "lock_acquire_release" => "lock_acquire_release"
    }

    suite =
      Benchee.run(
        jobs,
        warmup: Application.fetch_env!(:smalt_bench, :bench_warmup),
        time: Application.fetch_env!(:smalt_bench, :bench_time),
        memory_time: 0,
        reduction_time: 0,
        parallel: 1,
        print: [configuration: false, fast_warning: false],
        formatters: [fn _suite -> :ok end]
      )

    Enum.each(suite.scenarios, fn scenario ->
      op = Map.fetch!(name_to_op, scenario.job_name)
      st = scenario.run_time_data.statistics
      {extra, mult} =
        if op == "receive_events_drain_1kib" do
          {%{"batch" => 500}, 500}
        else
          {%{}, 1}
        end

      emit(path, "b9b", "eh-beam", op, st.sample_size, scenario, extra, mult)
    end)

    IO.puts("[benchee] b9b done -> #{path}")
  end

  def run(lane, out_dir) do
    case lane do
      "b7b" -> run_b7b(Path.join(out_dir, "b7b-store-beam.jsonl"))
      "b8b" -> run_b8b(Path.join(out_dir, "b8b-amqp-beam.jsonl"))
      "b9b" -> run_b9b(Path.join(out_dir, "b9b-eh-beam.jsonl"))
      "all" ->
        run_b7b(Path.join(out_dir, "b7b-store-beam.jsonl"))
        run_b8b(Path.join(out_dir, "b8b-amqp-beam.jsonl"))
        run_b9b(Path.join(out_dir, "b9b-eh-beam.jsonl"))
    end
  end
end

out_dir = System.get_env("BENCH_OUT_DIR") || "docs/jira/v26.10.14/bench"

# BK-EPLAW2: fail-closed fence — this harness self-boots :smalt in-process
# (run_b7b/run_b8b/run_b9b each call Application.ensure_all_started(:smalt)).
# Pin every listener to a probed-free port and abort on contract violation.
Code.require_file("test_boot_ports.exs", Path.join(File.cwd!(), "scripts/lib"))
SmaltTestBoot.pin!()
SmaltTestBoot.fence!("benchee_runner")

SmaltBench.Runner.run(lane_arg, out_dir)
