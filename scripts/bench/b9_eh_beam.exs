# scripts/bench/b9_eh_beam.exs — lane B-9: Event Hubs BEAM-level benchmark.
#
# Measures Smalt.Messaging.EventHubs raw pipeline (direct module calls, no AMQP
# wire framing) plus the SB claim-path lock tier:
#   (a) send_event/3  1 KiB events, sequential, >= 20k events  -> events/sec
#   (b) receive_events/3 drain of the ingested set              -> events/sec
#   (c) next_sequence/1 and reserve_processing/4 per-event cost -> us/op
#   (d) LockManager acquire+release pairs                       -> pairs/sec
#
# Boot mirrors scripts/bench/lib.sh bench_boot: MIX_ENV=test, --no-start,
# private ports, then Application.ensure_all_started(:smalt) in-process.
# The measured path is ETS + a named GenServer only; nothing touches the wire.
#
# Output: docs/jira/v26.10.14/bench/b9-eh-beam.jsonl (lib.sh record shape).
# No lib edits, no commits.

defmodule SmaltBench.B9 do
  alias Smalt.Messaging.EventHubs, as: EH
  alias Smalt.Amqp.LockManager

  @result_file System.get_env("B9_RESULT_FILE") ||
                 "docs/jira/v26.10.14/bench/b9-eh-beam.jsonl"
  @body_1k :binary.copy("x", 1024)
  @send_n 25_000
  @seq_n 50_000
  @reserve_n 20_000
  @lock_n 20_000
  @drain_batch 500

  # -- timing helpers -----------------------------------------------------------

  defp timed(fun) do
    t0 = System.monotonic_time(:native)
    result = fun.()
    {result, System.monotonic_time(:native) - t0}
  end

  defp ns_to_ms(ns), do: ns / 1_000_000.0

  defp pct(_lats, _p, []), do: 0.0
  defp pct(lats, p, _) do
    v = Enum.sort(lats)
    Enum.fetch!(v, round(p / 100.0 * (length(v) - 1))) |> Float.round(3)
  end

  defp cpu_name do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp machine_spec do
    cores = :erlang.system_info(:logical_processors_available)

    ram_gb =
      case File.read("/proc/meminfo") do
        {:ok, txt} ->
          ~r/MemTotal:\s+(\d+) kB/
          |> Regex.run(txt)
          |> tl()
          |> hd()
          |> String.to_integer()
          |> div(1024 * 1024)

        {:error, _} ->
          {out, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
          String.trim(out) |> String.to_integer() |> div(1024 * 1024 * 1024)
      end

    %{
      "cpu" => cpu_name(),
      "cores" => cores,
      "ram_gb" => ram_gb,
      "elixir" => System.version(),
      "otp" => :erlang.system_info(:otp_release) |> to_string(),
      "darwin" => :os.type() |> elem(1) |> to_string()
    }
  end

  defp emit(surface, op, n, ops_per_sec, lats, errors) do
    rec = %{
      lane: "b9",
      surface: surface,
      op: op,
      n: n,
      ops_per_sec: Float.round(ops_per_sec * 1.0, 1),
      p50_ms: pct(lats, 50, lats),
      p95_ms: pct(lats, 95, lats),
      p99_ms: pct(lats, 99, lats),
      errors: errors,
      machine: machine_spec()
    }

    File.mkdir_p!(Path.dirname(@result_file))
    File.write!(@result_file, Jason.encode!(rec) <> "\n", [:append])
    IO.puts(
      "[b9] #{op}: #{rec.ops_per_sec} ops/s (n=#{n}, p50=#{rec.p50_ms}ms " <>
        "p95=#{rec.p95_ms}ms p99=#{rec.p99_ms}ms errors=#{errors})"
    )

    rec
  end

  # -- (a) send_event/3, 1 KiB sequential ---------------------------------------

  defp bench_send(partition, n) do
    # per-op latency would dominate the JSONL with 25k points; sample every 10th
    lats =
      1..n
      |> Enum.map(fn _i ->
        {res, ns} = timed(fn -> EH.send_event(partition, @body_1k) end)
        {:ok, _seq, _ev} = res
        ns_to_ms(ns)
      end)

    sampled = lats |> Enum.take_every(10)
    total_ms = Enum.sum(lats)
    {n / (total_ms / 1000.0), sampled, 0}
  end

  # -- (b) receive_events/3 drain ------------------------------------------------

  defp bench_drain(partition, n) do
    drain(partition, _after_seq = 0, n, _got = 0, _lats = [], _total_ns = 0)
  end

  defp drain(partition, after_seq, n, got, lats, total_ns) when got < n do
    {events, ns} = timed(fn -> EH.receive_events(partition, after_seq, @drain_batch) end)

    case events do
      [] ->
        drain(partition, after_seq, n, got, lats, total_ns + ns)

      evs ->
        next_after = evs |> List.last() |> Map.fetch!("seq")
        drain(partition, next_after, n, got + length(evs), [ns_to_ms(ns) | lats], total_ns + ns)
    end
  end

  defp drain(_p, _a, _n, got, lats, total_ns) do
    ops = got / (ns_to_ms(total_ns) / 1000.0)
    {ops, Enum.reverse(lats)}
  end

  # -- (c) next_sequence / reserve_processing per-event us ----------------------

  defp bench_next_seq(partition, n) do
    {total_ns, last_seq, errors} =
      Enum.reduce(1..n, {0, 0, 0}, fn _i, {acc, _prev, errs} ->
        {res, ns} = timed(fn -> EH.next_sequence(partition) end)

        case res do
          {:ok, seq} when is_integer(seq) -> {acc + ns, seq, errs}
          _ -> {acc + ns, :none, errs + 1}
        end
      end)

    us_per = ns_to_ms(total_ns) * 1000.0 / n
    errors = if last_seq == :none, do: errors + 1, else: errors
    {us_per, errors}
  end

  defp bench_reserve(group, partition, n, owner) do
    {total_ns, errors} =
      Enum.reduce(1..n, {0, 0}, fn _i, {acc, errs} ->
        {res, ns} = timed(fn -> EH.reserve_processing(group, partition, owner, 60_000) end)

        case res do
          :ok -> {acc + ns, errs}
          _ -> {acc + ns, errs + 1}
        end
      end)

    {ns_to_ms(total_ns) * 1000.0 / n, errors}
  end

  # -- (d) LockManager acquire+release pairs ------------------------------------

  defp bench_locks(queue, n) do
    {total_ns, errors} =
      Enum.reduce(1..n, {0, 0}, fn seq, {acc, errs} ->
        t0 = System.monotonic_time(:native)

        case LockManager.acquire(queue, seq, duration_ms: 60_000) do
          {:ok, lock} ->
            :ok = LockManager.release(lock.lock_token)
            {acc + (System.monotonic_time(:native) - t0), errs}

          _ ->
            {acc, errs + 1}
        end
      end)

    {n / (ns_to_ms(total_ns) / 1000.0), errors}
  end

  # -- entry point ----------------------------------------------------------------

  def run do
    {:ok, _} = Application.ensure_all_started(:smalt)
    EH.ensure_tables()

    uniq = System.unique_integer([:positive])
    part_send = "ns/b9-hub/send-#{uniq}"
    part_seq = "ns/b9-hub/seq-#{uniq}"
    part_res = "ns/b9-hub/res-#{uniq}"

    IO.puts("[b9] BEAM-level EH benchmark, send_n=#{@send_n} seq_n=#{@seq_n} " <> "reserve_n=#{@reserve_n} lock_n=#{@lock_n}")

    # (a) send
    {send_ops, send_lats, send_errs} = bench_send(part_send, @send_n)
    emit("eh-beam", "send_event_1kib", @send_n, send_ops, send_lats, send_errs)

    # (b) drain of exactly the ingested set
    {drain_ops, drain_lats} = bench_drain(part_send, @send_n)
    drain_errs = 0
    emit("eh-beam", "receive_events_drain_1kib", @send_n, drain_ops, drain_lats, drain_errs)

    # (c) next_sequence + reserve_processing per-event cost
    {seq_us, seq_errs} = bench_next_seq(part_seq, @seq_n)
    IO.puts("[b9] next_sequence: #{Float.round(seq_us, 3)} us/op (n=#{@seq_n}, errors=#{seq_errs})")

    File.write!(@result_file, jseq(seq_us, seq_errs) <> "\n", [:append])

    {res_us, res_errs} = bench_reserve("b9-group", part_res, @reserve_n, :b9_owner)
    IO.puts("[b9] reserve_processing: #{Float.round(res_us, 3)} us/op (n=#{@reserve_n}, errors=#{res_errs})")

    File.write!(@result_file, jres(res_us, res_errs) <> "\n", [:append])

    # (d) locks
    {lock_ops, lock_errs} = bench_locks("ns/b9-queue", @lock_n)
    emit("sb-lock", "lock_acquire_release", @lock_n, lock_ops, [], lock_errs)

    IO.puts("[b9] done -> #{@result_file}")
  end

  defp jseq(us, errs) do
    Jason.encode!(%{
      lane: "b9",
      surface: "eh-beam",
      op: "next_sequence",
      n: @seq_n,
      ops_per_sec: Float.round(1_000_000.0 / us, 1),
      p50_ms: 0.0,
      p95_ms: 0.0,
      p99_ms: 0.0,
      errors: errs,
      us_per_op: Float.round(us, 3),
      machine: machine_spec()
    })
  end

  defp jres(us, errs) do
    Jason.encode!(%{
      lane: "b9",
      surface: "eh-beam",
      op: "reserve_processing",
      n: @reserve_n,
      ops_per_sec: Float.round(1_000_000.0 / us, 1),
      p50_ms: 0.0,
      p95_ms: 0.0,
      p99_ms: 0.0,
      errors: errors_count(errs),
      us_per_op: Float.round(us, 3),
      machine: machine_spec()
    })
  end

  defp errors_count(e), do: e
end

SmaltBench.B9.run()
