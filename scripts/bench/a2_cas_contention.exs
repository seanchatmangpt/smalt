# A-2: high-contention optimistic CAS bench (BEAM tier) — Store.compare_and_swap/4
# Run: MIX_ENV=test mix run --no-start scripts/bench/a2_cas_contention.exs
#
# For N ∈ {10, 100, 1000}: spawn N concurrent actors that all race on ONE key
# with the same expected value per round. Exactly one wins (:ok), N-1 get
# {:error, :conflict} — the 412 PreconditionFailed analog (every conflict is a
# consumed attempt that made no progress, the Azure throttling-loop economics).
# After each round the value is read back; value_after == value_before + 1
# proves zero phantom overwrites. Latency sampled per attempt; total process
# runtime vs wall-clock sampled for scheduler-contention evidence.

{:ok, _} = Smalt.Store.start_link([])

t0 = :erlang.monotonic_time(:millisecond)
:rand.seed(:exsss, {t0, t0 * 7919 + 13, t0 * 104729 + 7})

tbl = :smalt_resources
batch = System.unique_integer([:positive])
key = "a2-cas-#{batch}"

:ok = Smalt.Store.put(tbl, key, 0)

rounds = 20

percentiles = fn lats ->
  v = Enum.sort(lats)

  if v == [] do
    {0.0, 0.0, 0.0}
  else
    at = fn p -> Enum.at(v, round(p / 100 * (length(v) - 1))) / 1000 end
    {at.(50), at.(95), at.(99), length(v)}
  end
end

fmt = fn x, d -> :erlang.float_to_binary(x * 1.0, decimals: d) end

emit = fn map ->
  body =
    Enum.map_join(map, ",", fn {k, v} ->
      vs = if is_binary(v), do: ~s("#{v}"), else: v
      ~s("#{k}":#{vs})
    end)

  IO.puts("{#{body}}")
end

IO.puts(
  ~s({"lane":"a2","tier":"beam","op":"meta","otp":#{:erlang.system_info(:otp_release) |> List.to_string() |> inspect()},"schedulers_online":#{:erlang.system_info(:schedulers_online)},"logical":#{:erlang.system_info(:logical_processors_available)}})
)

results =
  for n <- [10, 100, 1000] do
    winners = :counters.new(1, [:atomics])
    conflicts = :counters.new(1, [:atomics])
    phantom = :counters.new(1, [:atomics])
    unexpected = :counters.new(1, [:atomics])
    lats = :ets.new(:a2_lats, [:bag, :public, :named_table])

    {rt_before, _} = :erlang.statistics(:runtime)

    round_rows =
      for r <- 1..rounds do
        {:ok, base} = Smalt.Store.get(tbl, key)

        procs =
          for _ <- 1..n do
            spawn(fn ->
              s = :erlang.monotonic_time(:microsecond)

              res =
                try do
                  # every actor races with the SAME expected value (the round's
                  # base) — the true read-etag-then-If-Match-replace contention
                  # shape: exactly one etag match, N-1 get the 412 analog
                  Smalt.Store.compare_and_swap(tbl, key, base, base + 1)
                rescue
                  e -> {:error, :raised, Exception.message(e)}
                end

              dt = :erlang.monotonic_time(:microsecond) - s
              :ets.insert(lats, {dt})

              case res do
                :ok -> :counters.add(winners, 1, 1)
                {:error, :conflict} -> :counters.add(conflicts, 1, 1)
                _ -> :counters.add(unexpected, 1, 1)
              end
            end)
          end

        Enum.each(procs, &Process.monitor/1)

        t_start = :erlang.monotonic_time(:microsecond)

        for _ <- 1..n do
          receive do
            {:DOWN, _, :process, _, _} -> :ok
          after
            60_000 -> exit(:a2_round_timeout)
          end
        end

        dt_ms = (:erlang.monotonic_time(:microsecond) - t_start) / 1000

        # zero-phantom proof: value advanced by EXACTLY one despite N racers
        {:ok, final} = Smalt.Store.get(tbl, key)

        if final != base + 1, do: :counters.add(phantom, 1, 1)

        {r, dt_ms, final, base}
      end

    {rt_after, _} = :erlang.statistics(:runtime)
    runtime_ms = rt_after - rt_before

    total_attempts = n * rounds
    w = :counters.get(winners, 1)
    c = :counters.get(conflicts, 1)
    ph = :counters.get(phantom, 1)
    un = :counters.get(unexpected, 1)

    all_lats = :ets.tab2list(lats) |> Enum.map(&elem(&1, 0))
    :ets.delete(lats)
    {p50, p95, p99, lat_count} = percentiles.(all_lats)

    wall_ms = round_rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    schedulers = :erlang.system_info(:schedulers_online)

    # scheduler-contention evidence: fraction of scheduler capacity consumed
    busy_frac = runtime_ms / (wall_ms * schedulers)

    emit.(
      lane: "a2",
      tier: "beam",
      op: "cas_contention",
      n: n,
      rounds: rounds,
      attempts: total_attempts,
      winners: w,
      conflicts_412_analog: c,
      unexpected: un,
      phantom_overwrites: ph,
      exactly_one_winner_per_round: w == rounds and c == total_attempts - rounds and ph == 0 and un == 0,
      attempts_per_success: fmt.(total_attempts / max(w, 1), 2),
      wall_ms: fmt.(wall_ms, 1),
      attempts_per_sec: fmt.(total_attempts / (wall_ms / 1000), 0),
      p50_us: fmt.(p50, 1),
      p95_us: fmt.(p95, 1),
      p99_us: fmt.(p99, 1),
      latency_samples: lat_count,
      proc_runtime_ms: fmt.(runtime_ms, 0),
      sched_busy_frac: fmt.(busy_frac, 4)
    )

    {n, round_rows}
  end

# round-by-round zero-phantom proof lines (all N legs)
Enum.each(results, fn {n, round_rows} ->
  Enum.each(round_rows, fn {r, dt_ms, final, base} ->
    IO.puts(
      ~s({"lane":"a2","tier":"beam","op":"round_proof","n":#{n},"round":#{r},"wall_ms":#{fmt.(dt_ms, 2)},"value_after":#{final},"expected_after":#{base + 1},"ok":#{final == base + 1}})    )
  end)
end)

Smalt.Store.clear()
IO.puts(~s({"lane":"a2","tier":"beam","op":"done"}))
