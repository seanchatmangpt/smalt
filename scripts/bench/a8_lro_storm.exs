# A-8: LRO sweeper storm under high-rate cancellation (BEAM tier)
# Run: MIX_ENV=test mix run --no-start scripts/bench/a8_lro_storm.exs
#
# (1) Mint 10,000 InProgress LRO records directly into :smalt_operations in the
#     exact Smalt.ArmGateway.LRO.start_op/1 record shape (startedAtMs +
#     delayMs, delay spread 1-30s).
# (2) Cancel 5,000 mid-flight (status -> "Cancelled") with dispatch times
#     spread uniformly over the 30s delay window — cancellation races the live
#     sweeper head-on. Cancels are CAS-serialized (Store.compare_and_swap/4 on
#     the observed InProgress record) against the sweeper's shared evaluate/2
#     write, so exactly one of {cancel, sweeper-flip} wins per op and the
#     loser is counted as a missed cancel — the terminal is whichever landed,
#     never a zombie.
# (3) Sweeper live at 30s tick; convergence = wall-clock from mint t0 until
#     ALL 10,000 records are terminal.
# (4) :erlang.memory(:ets) sampled every 500ms during the storm.
# (5) Invariants at convergence:
#     - zero non-terminal records
#     - zero resurrected records (a cancel-WIN never ends anything but
#       "Cancelled"; a cancel MISS is a sweeper-won race ending Succeeded —
#       counted, legal)
#
# Real-Azure divergence: ~1.2k writes/hour/subscription → 10k writes need 8+
# hours and 8+ subscription shards on one subscription; the emulator mints all
# 10,000 in under a second. That gap IS the divergence row.

defmodule Bench.A8LROStorm do
  alias Smalt.Store

  @n 10_000
  @n_cancel 5_000
  @window_ms 30_000
  @tick_ms 30_000
  @poll_ms 200
  @sample_ms 500

  def run do
    {:ok, _} = Store.start_link([])
    Application.put_env(:smalt, :lro_sweep_interval_ms, @tick_ms)
    {:ok, _} = Smalt.ArmGateway.LRO.Sweeper.start_link([])
    Process.sleep(50)

    seed = :erlang.monotonic_time(:millisecond)
    :rand.seed(:exsss, {seed, seed * 7919 + 13, seed * 104_729 + 7})

    now = System.system_time(:millisecond)

    # ---- (1) mint ----
    t0 = System.system_time(:millisecond)

    ops =
      for i <- 1..@n do
        op_id = :io_lib.format("a8-~10..0b-~6..0b", [batch_tag(), i]) |> IO.iodata_to_binary()
        {op_id, 1_000 + :rand.uniform(29_000), now}
      end

    Enum.each(ops, fn {op_id, delay, started} ->
      :ok =
        Store.put(:smalt_operations, op_id, %{
          "id" => "/subscriptions/00000000-0000-0000-0000-000000000000/operations/#{op_id}",
          "name" => op_id,
          "status" => "InProgress",
          "startTime" => iso(started),
          "endTime" => nil,
          "resourceId" =>
            "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/a8-storm/providers/Microsoft.Smalt/whatever/#{op_id}",
          "startedAtMs" => started,
          "delayMs" => delay
        })
    end)

    mint_ms = System.system_time(:millisecond) - t0
    IO.puts("[a8] minted=#{@n} in #{mint_ms}ms")

    # ---- (4) ets sampler ----
    :ets.new(:a8_ets_samples, [:named_table, :public, :ordered_set])
    sampler = spawn_link(fn -> loop_samples(0) end)

    # ---- (2) cancel storm, dispatch spread over the window ----
    cancel_targets =
      ops |> Enum.take_random(@n_cancel) |> Enum.map(fn {id, _, _} -> id end) |> MapSet.new()

    cancel_at =
      ops
      |> Enum.filter(fn {id, _, _} -> MapSet.member?(cancel_targets, id) end)
      |> Enum.map(fn {id, _, _} -> {id, :rand.uniform(@window_ms)} end)
      |> Enum.sort_by(fn {_id, at} -> at end)

    parent = self()

    cancel_worker =
      spawn_link(fn ->
        Enum.each(cancel_at, fn {op_id, at} ->
          wait_until(t0 + at)
          sent_at = System.system_time(:millisecond) - t0

          result =
            case Store.get(:smalt_operations, op_id) do
              {:ok, %{"status" => "InProgress"} = rec} ->
                cancelled =
                  rec
                  |> Map.put("status", "Cancelled")
                  |> Map.put("endTime", iso(System.system_time(:millisecond)))

                case Store.compare_and_swap(:smalt_operations, op_id, rec, cancelled) do
                  :ok -> {:win, op_id}
                  {:error, :conflict} -> {:miss_conflict, op_id}
                end

              {:ok, _terminal} ->
                {:miss_already_terminal, op_id}

              :error ->
                {:miss_gone, op_id}
            end

          send(parent, {:cancel, result, sent_at})
        end)

        send(parent, {:cancels_done, self()})
      end)

    # ---- (3) convergence poll + drain cancel results ----
    {convergence_ms, wins, misses, miss_kinds, cancel_ats} =
      wait_convergence(t0, cancel_worker)
    total_ms = System.system_time(:millisecond) - t0

    # ---- (5) invariant sweep ----
    a8_keys = MapSet.new(ops, fn {id, _, _} -> id end)

    {a8_count, statuses, non_terminal, cancelled_intact, _resurrected} =
      :smalt_operations
      |> Store.keys()
      |> Enum.reduce({0, %{}, 0, 0, 0}, fn k, acc ->
        case Store.get(:smalt_operations, k) do
          {:ok, r} when is_map(r) ->
            if MapSet.member?(a8_keys, k), do: fold_record(k, r, wins, acc), else: acc

          _ ->
            acc
        end
      end)

    a8 = a8_count
    miss_list = MapSet.new(misses)

    # Any cancel TARGET that ended Succeeded must be a sweeper-won race (a miss).
    targets_succeeded_but_won =
      Enum.count(MapSet.to_list(wins), fn k ->
        final_status(k) == "Succeeded"
      end)

    ets_samples = :ets.tab2list(:a8_ets_samples) |> Enum.map(fn {_i, b} -> b end)

    ets_stats =
      if ets_samples == [] do
        {0, 0, 0.0, 0}
      else
        {Enum.min(ets_samples), Enum.max(ets_samples), Enum.sum(ets_samples) / length(ets_samples),
         length(ets_samples)}
      end

    {ets_min, ets_max, ets_mean, ets_n} = ets_stats

    # Win/miss outcome vs dispatch time (5s buckets over the 30s window).
    buckets =
      Enum.map(Enum.reverse(cancel_ats |> Map.to_list()), fn {op_id, at} ->
        {div(at, 5_000), if(MapSet.member?(wins, op_id), do: :win, else: :miss)}
      end)

    hist =
      Enum.group_by(buckets, fn {b, _} -> b end, fn {_, o} -> o end)
      |> Enum.map(fn {b, os} ->
        {b, Enum.count(os, &(&1 == :win)), Enum.count(os, &(&1 == :miss))}
      end)
      |> Enum.sort()

    summary = %{
      n: a8,
      n_cancel: @n_cancel,
      cancel_wins: MapSet.size(wins),
      cancel_misses: MapSet.size(miss_list),
      targets_succeeded_but_won: targets_succeeded_but_won,
      non_terminal: non_terminal,
      cancelled_intact: cancelled_intact,
      statuses: statuses,
      mint_ms: mint_ms,
      convergence_ms: convergence_ms,
      total_ms: total_ms,
      ets_min_mb: Float.round(ets_min / 1_048_576, 1),
      ets_max_mb: Float.round(ets_max / 1_048_576, 1),
      ets_mean_mb: Float.round(ets_mean / 1_048_576, 1),
      ets_samples: ets_n,
      miss_kinds: Map.to_list(miss_kinds),
      cancel_outcome_hist_5s: hist
    }

    emit(summary)
    Process.unlink(sampler)
    Process.exit(sampler, :kill)
    Process.unlink(cancel_worker)
    if Process.alive?(cancel_worker), do: Process.exit(cancel_worker, :kill)
    :ok
  end

  # Fold one terminal record into the invariant counters.
  defp fold_record(k, r, wins, {n, statuses, non_terminal, cancelled_intact, resurrected}) do
    st = r["status"]
    win? = MapSet.member?(wins, k)

    resurrected =
      if win? and st != "Cancelled", do: resurrected + 1, else: resurrected

    cancelled_intact =
      if st == "Cancelled", do: cancelled_intact + 1, else: cancelled_intact

    non_terminal =
      if st != "Succeeded" and st != "Cancelled", do: non_terminal + 1, else: non_terminal

    {n + 1, Map.update(statuses, st, 1, &(&1 + 1)), non_terminal, cancelled_intact, resurrected}
  end

  defp final_status(k) do
    case Store.get(:smalt_operations, k) do
      {:ok, %{"status" => s}} -> s
      _ -> nil
    end
  end

  defp wait_convergence(t0, worker) do
    deadline = t0 + @window_ms * 3
    do_wait(t0, deadline, MapSet.new(), MapSet.new(), %{}, worker)
  end

  # wins/misses keyed by op_id; miss_kinds aggregates miss kind -> count;
  # cancel_ats records op_id -> dispatch time (ms into the window) for the
  # win/miss-vs-time histogram.
  defp do_wait(t0, deadline, wins, misses, miss_kinds, worker, cancel_ats \\ %{}) do
    pending = count_in_progress()

    cond do
      pending == 0 and MapSet.size(wins) + MapSet.size(misses) == @n_cancel ->
        {System.system_time(:millisecond) - t0, wins, misses, miss_kinds, cancel_ats}

      System.system_time(:millisecond) > deadline ->
        IO.puts("[a8] DEADLINE exceeded: pending=#{pending}")
        {System.system_time(:millisecond) - t0, wins, misses, miss_kinds, cancel_ats}

      true ->
        receive do
          {:cancel, {kind, op_id}, at} ->
            {wins, misses, miss_kinds} =
              if kind == :win do
                {MapSet.put(wins, op_id), misses, miss_kinds}
              else
                {wins, MapSet.put(misses, op_id),
                 Map.update(miss_kinds, kind, 1, &(&1 + 1))}
              end

            do_wait(t0, deadline, wins, misses, miss_kinds, worker,
              Map.put(cancel_ats, op_id, at)
            )

          {:cancels_done, _} ->
            do_wait(t0, deadline, wins, misses, miss_kinds, worker, cancel_ats)
        after
          @poll_ms -> do_wait(t0, deadline, wins, misses, miss_kinds, worker, cancel_ats)
        end
    end
  end

  defp count_in_progress do
    :smalt_operations
    |> Store.keys()
    |> Enum.count(fn k ->
      match?({:ok, %{"status" => "InProgress"}}, Store.get(:smalt_operations, k))
    end)
  end

  defp loop_samples(i) do
    :ets.insert(:a8_ets_samples, {i, :erlang.memory(:ets)})
    Process.sleep(@sample_ms)
    loop_samples(i + 1)
  end

  defp wait_until(t) do
    now = System.system_time(:millisecond)

    if now < t do
      Process.sleep(min(t - now, 200))
      wait_until(t)
    end
  end

  defp batch_tag, do: System.system_time(:millisecond) |> rem(10_000_000)

  defp iso(ms) do
    DateTime.from_unix!(ms, :millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp emit(m) do
    lines = [
      %{lane: "a8", op: "mint", items: m.n, wall_ms: m.mint_ms,
        items_per_sec: Float.round(m.n / max(m.mint_ms, 1) * 1000, 1)},
      %{lane: "a8", op: "cancel_storm", items: m.n_cancel,
        cancel_wins: m.cancel_wins, cancel_misses: m.cancel_misses,
        miss_kinds: m.miss_kinds,
        wins_pct: Float.round(m.cancel_wins / max(m.n_cancel, 1) * 100, 1)},
      %{lane: "a8", op: "cancel_outcome_vs_time", bucket_ms: 5000, hist: m.cancel_outcome_hist_5s},
      %{lane: "a8", op: "sweeper_convergence", items: m.n, wall_ms: m.convergence_ms,
        tick_ms: @tick_ms, window_ms: @window_ms, all_terminal: m.non_terminal == 0},
      %{lane: "a8", op: "ets_memory", samples: m.ets_samples,
        min_mb: m.ets_min_mb, max_mb: m.ets_max_mb, mean_mb: m.ets_mean_mb},
      %{lane: "a8", op: "invariants", non_terminal: m.non_terminal,
        resurrected_cancel_win_non_cancelled: m.targets_succeeded_but_won,
        cancelled_intact: m.cancelled_intact,
        statuses: Enum.map_join(m.statuses, " ", fn {k, v} -> "#{k}=#{v}" end),
        verdict: (if m.non_terminal == 0 and m.targets_succeeded_but_won == 0, do: "PASS", else: "FAIL")},
      %{lane: "a8", op: "real_azure_divergence", azure_writes_per_hour_per_sub: 1200,
        azure_hours_for_10k_one_sub: 8.3, azure_subs_shards_needed: 9,
        emulator_total_ms: m.total_ms,
        note: "10k writes in seconds vs 8+ hours of single-subscription quota"}
    ]

    path = "docs/jira/v26.10.14/bench/a8-lro-storm.jsonl"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", &inspect/1) <> "\n")
    Enum.each(lines, fn l -> IO.puts(inspect(l, limit: :infinity)) end)
  end
end

Bench.A8LROStorm.run()
