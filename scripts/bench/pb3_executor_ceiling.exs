# PB-3 (bench, OTP-29) — Smalt.POWL2.Executor concurrency ceiling sweep.
#
# N independent 4-step settlement orchestration instances, all through
# Smalt.POWL2.Executor.execute_admitted/6 (Task-based frontier parallelism,
# in-kernel, no socket). Sweep N = 64/256/512/1024/2048. Typed wall_level at
# the first error cliff (T3 methodology). Compare vs the wire wall
# (T3: clean through L4096, typed wall at L8192).
#
# Run: mix run scripts/bench/pb3_executor_ceiling.exs
# Out: tmp/bench/pb3-executor-ceiling.jsonl

out_path = Path.expand("tmp/bench/pb3-executor-ceiling.jsonl", File.cwd!())
File.mkdir_p!(Path.dirname(out_path))

machine = %{
  cpu:
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"]) do
      {v, 0} -> String.trim(v)
      _ -> "unknown"
    end,
  cores: :erlang.system_info(:logical_processors_available),
  elixir: System.version(),
  otp: :erlang.system_info(:otp_release) |> to_string(),
  darwin:
    case System.cmd("sw_vers", ["-productVersion"]) do
      {v, 0} -> String.trim(v)
      _ -> "unknown"
    end
}

# One shared real DETS table (receipts persist under {:powl2_receipt, id}).
table = :"pb3_powl2_receipts_#{System.unique_integer([:positive])}"
path = Path.expand("tmp/pb3_#{table}.dets", File.cwd!())
{:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path))

transition = Smalt.POWL2.Reticle.AST.Transition
partial_order = Smalt.POWL2.Reticle.AST.PartialOrder

# 4-step settlement: debit -> hold -> capture -> settle (linear partial order).
mk_t = fn id, next ->
  %{
    __struct__: transition,
    id: id,
    label: Atom.to_string(id),
    op: fn ctx -> {:ok, next.(ctx)} end
  }
end

settlement_model = fn inst ->
  %{
    __struct__: partial_order,
    id: :"settle_#{inst}",
    children: %{
      debit: mk_t.(:debit, &Map.put(&1, :debit, 1)),
      hold: mk_t.(:hold, &Map.put(&1, :hold, &1.debit + 1)),
      capture: mk_t.(:capture, &Map.put(&1, :capture, &1.hold + 1)),
      settle: mk_t.(:settle, &Map.put(&1, :settle, &1.capture + 1))
    },
    order: [debit: :hold, hold: :capture, capture: :settle]
  }
end

sweep = [64, 256, 512, 1024, 2048, 4096, 8192]

results =
  Enum.map(sweep, fn n ->
    t0 = System.monotonic_time(:millisecond)

    tasks =
      for i <- 1..n do
        me = self()

        Task.async(fn ->
          ti0 = System.monotonic_time(:millisecond)
          res = Smalt.POWL2.Executor.execute_admitted(:"pb3_#{i}", {:ok, settlement_model.(i)}, %{}, table, me)
          dt = System.monotonic_time(:millisecond) - ti0
          {res, dt}
        end)
      end

    timeout = n * 10_000 + 60_000

    {oks, fails, latencies} =
      Enum.reduce(Task.yield_many(tasks, timeout), {0, 0, []}, fn
        {_task, {:ok, {res, dt}}}, {o, f, l} ->
          case res do
            :ok -> {o + 1, f, [dt | l]}
            {:error, _} -> {o, f + 1, [dt | l]}
          end

        _, {o, f, l} ->
          {o, f, l}
      end)

    wall = System.monotonic_time(:millisecond) - t0
    lat_sorted = Enum.sort(latencies)

    p = fn q ->
      if lat_sorted == [], do: nil, else: Enum.at(lat_sorted, trunc(q / 100 * (length(lat_sorted) - 1)))
    end

    IO.puts(
      "N=#{n} wall_ms=#{wall} errors=#{fails} " <>
        "p50=#{p.(50)} p95=#{p.(95)} p99=#{p.(99)} lat_count=#{length(latencies)}"
    )

    %{
      lane: "pb3",
      surface: "powl2_executor_inproc",
      op: "settle4_ramp",
      n: n,
      wall_ms: wall,
      ops_per_sec: Float.round(n / (wall / 1000), 1),
      p50_ms: p.(50),
      p95_ms: p.(95),
      p99_ms: p.(99),
      errors: fails,
      wall_level: "unreached",
      machine: machine
    }
  end)

# Typed wall detection: first N with errors > 0 (T3 methodology).
first_err = Enum.find(results, &(&1.errors > 0))

rows =
  case first_err do
    nil ->
      results

    row ->
      Enum.map(results, fn
        %{n: n} = r when n >= row.n -> %{r | wall_level: "L#{n}"}
        r -> r
      end)
  end

summary = %{
  lane: "pb3",
  surface: "powl2_executor_inproc",
  op: "wall_summary",
  n: nil,
  wall_level: (first_err && "L#{first_err.n}") || "unreached-at-#{Enum.max(sweep)}",
  errors: Enum.sum(Enum.map(results, & &1.errors)),
  machine: machine
}

File.write!(
  out_path,
  ((rows ++ [summary]) |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")) <> "\n"
)

:dets.sync(table)
:dets.close(table)
File.rm(path)

IO.puts("wrote #{out_path}")
IO.puts("wall_level=#{summary.wall_level} total_errors=#{summary.errors}")
