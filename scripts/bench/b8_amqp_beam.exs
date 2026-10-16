# Lane B-8: AMQP frame-tier (BEAM) bench.
# Run: MIX_ENV=test mix run --no-start scripts/bench/b8_amqp_beam.exs

defmodule Bench.B8 do
  alias Smalt.Amqp.{FrameCodec, LockManager, QueueStore}

  @tables [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_sessions, :smalt_resources]
  @body :binary.copy(<<"x">>, 1024)
  @n_msg 50_000
  @n_sess 4_000
  @n_frame 50_000
  @n_e2e 50_000

  def run(path) do
    boot()
    rows = [enqueue(), dequeue_ack(), session_rt(), frame_encdec(), e2e(), enqueue_depth1()]

    File.mkdir_p!(Path.dirname(path))
    Enum.each(rows, fn r -> File.write!(path, r <> "\n", [:append]) end)
    Enum.each(rows, &IO.puts/1)
  end

  defp boot do
    Enum.each(@tables, fn t ->
      if :ets.info(t) == :undefined do
        :ets.new(t, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      end

      :ets.delete_all_objects(t)
    end)

    :ets.insert(:smalt_resources, {"bench-q", %{props: %{"requiresSession" => false}}})
    :ets.insert(:smalt_resources, {"bench-sess-q", %{props: %{"requiresSession" => true}}})

    case Process.whereis(QueueStore) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _} = QueueStore.start_link([])
  end

  defp timed(name, n, fun) do
    :erlang.garbage_collect()
    Process.sleep(100)
    {us, _} = :timer.tc(fun)
    ops = Float.round(n / (us / 1_000_000), 1)
    ms = Float.round(us / 1000, 1)
    IO.iodata_to_binary([
      ~s({"lane":"b8","surface":"amqp-beam","op":"),
      name,
      ~s(","n":#{n},"ops_per_sec":#{ops},"p50_ms":0.0,"p95_ms":0.0,"p99_ms":0.0,"errors":0,"elapsed_ms":#{ms},"machine":),
      machine()
    ])
  end

  defp machine do
    cpu =
      case :os.type() do
        {:unix, :darwin} ->
          {out, 0} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"])
          String.trim(out)

        _ ->
          "unknown"
      end

    {darwin, 0} = System.cmd("sw_vers", ["-productVersion"])
    darwin = String.trim(darwin)

    ~s({"cpu":"#{cpu}","cores":#{:erlang.system_info(:logical_processors_available)},"ram_gb":#{ram_gb()},"elixir":"#{System.version()}","otp":"#{System.otp_release()}","darwin":"#{darwin}"})
  end

  defp ram_gb do
    {out, _} = System.cmd("sysctl", ["-n", "hw.memsize"])
    div(String.trim(out) |> String.to_integer(), 1024 * 1024 * 1024)
  end

  # @capacity is 4096, so spread across round-robin queues.
  @n_queues 13

  defp qname(i), do: "bench-q-#{rem(i, @n_queues)}"

  defp enqueue do
    Enum.each(0..(@n_queues - 1), fn i ->
      :ets.insert(:smalt_resources, {"bench-q-#{i}", %{props: %{"requiresSession" => false}}})
    end)

    timed("enqueue_1kib", @n_msg, fn ->
      for i <- 1..@n_msg do
        {:ok, _} = QueueStore.enqueue(qname(i), @body, app_props: %{"n" => i})
      end
    end)
  end

  defp dequeue_ack do
    qs = Enum.map(0..(@n_queues - 1), &"bench-q-#{&1}")

    {us, drained} =
      :timer.tc(fn ->
        Enum.reduce(qs, 0, fn q, acc -> acc + drain_queue(q) end)
      end)

    ops = Float.round(drained / (us / 1_000_000), 1)
    errors = @n_msg - drained
    ms = Float.round(us / 1000, 1)

    IO.iodata_to_binary([
      ~s({"lane":"b8","surface":"amqp-beam","op":"dequeue_ack_1kib","n":#{drained},"ops_per_sec":#{ops},"p50_ms":0.0,"p95_ms":0.0,"p99_ms":0.0,"errors":#{errors},"elapsed_ms":#{ms},"machine":),
      machine()
    ])
  end

  defp drain_queue(q) do
    drain_queue(q, 0)
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

  defp session_rt do
    q = "bench-sess-q"

    Enum.each(1..@n_sess, fn i ->
      {:ok, _} = QueueStore.enqueue(q, @body, session_id: "s-#{i}")
    end)

    timed("session_delivery_rt", @n_sess, fn ->
      for i <- 1..@n_sess do
        sid = "s-#{i}"
        {:ok, _} = LockManager.session_acquire(q, sid, duration_ms: 60_000)
        {:ok, msg, _} = QueueStore.dequeue_matching(q, session_id: sid, lock_duration_ms: 60_000)
        :ok = QueueStore.complete(q, msg.seq)
        :ok = LockManager.session_release(q, sid)
      end
    end)
  end

  defp frame_encdec do
    sections = [{:header, %{durable: true}}, {:application_properties, %{"n" => 1}}, {:body_data, @body}]

    frame =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 1}, {:sections, sections}})
      )

    {:ok, %{payload: payload}} = FrameCodec.decode_frame(frame)
    {:ok, _} = FrameCodec.decode_message(payload)

    timed("frame_transfer_encdec", @n_frame, fn ->
      for i <- 1..@n_frame do
        f =
          IO.iodata_to_binary(
            FrameCodec.encode_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: i}, {:sections, sections}})
          )

        {:ok, %{payload: p}} = FrameCodec.decode_frame(f)
        {:ok, _} = FrameCodec.decode_message(p)
      end
    end)
  end

  # Control: enqueue with the queue drained every iteration (depth ~1) —
  # isolates per-op cost from the O(n) capacity/count scan at depth.
  defp enqueue_depth1 do
    q = "bench-q-depth1"

    timed("enqueue_1kib_depth1", @n_msg, fn ->
      for i <- 1..@n_msg do
        {:ok, seq} = QueueStore.enqueue(q, @body, app_props: %{"n" => i})
        :ok = QueueStore.complete(q, seq)
      end
    end)
  end

  defp e2e do
    q = "bench-q2"
    {:ok, _} = QueueStore.ensure_queue(q)

    timed("e2e_store_rt_1kib", @n_e2e, fn ->
      for i <- 1..@n_e2e do
        {:ok, _} = QueueStore.enqueue(q, @body, app_props: %{"n" => i})
        {:ok, msg, _} = QueueStore.dequeue_matching(q, lock_duration_ms: 60_000)
        :ok = QueueStore.complete(q, msg.seq)
      end
    end)
  end
end

Bench.B8.run(Path.expand("docs/jira/v26.10.14/bench/b8-amqp-beam.jsonl", File.cwd!()))
