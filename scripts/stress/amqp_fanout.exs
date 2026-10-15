# AMQP fan-out stress driver — pure Elixir over Smalt.Amqp.QueueStore /
# LockManager / Store. No network listeners required. Run with:
#
#   mix run --no-start scripts/stress/amqp_fanout.exs
#
# Phases:
#   A. 200 receivers (credit 1 each) + 20 senders on ONE queue: per-receiver
#      delivery counts, max/min fairness ratio, total throughput, lock
#      contention effects on queue_store under 200 dequeue_matching racers.
#   B. 200 concurrent session receivers on ONE session queue: assert exclusive
#      session lock (one winner, 199 clean {:error, :already_locked} — the
#      store-level form of com.microsoft:session-cannot-be-locked), no crashes.

defmodule Smalt.Stress.AmqpFanout do
  @receivers 200
  @senders 20
  @msgs_per_sender 50
  @total_msgs @senders * @msgs_per_sender
  @queue_a "stress.fanout"
  @queue_b "stress.session"

  def run do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Smalt.Store.start_link([])
    :ok = Smalt.Telemetry.attach()
    wipe()

    t0 = System.monotonic_time(:millisecond)
    phase_a()
    ta = System.monotonic_time(:millisecond) - t0

    wipe()

    t1 = System.monotonic_time(:millisecond)
    phase_b()
    tb = System.monotonic_time(:millisecond) - t1

    IO.puts("\n== phase timings: fanout=#{ta}ms session=#{tb}ms ==")
    :ok
  end

  # -- Phase A: delivery fan-out ------------------------------------------------

  defp phase_a do
    {:ok, _} = Smalt.Amqp.QueueStore.ensure_queue(@queue_a)
    counts = :ets.new(:fanout_counts, [:public, :named_table, :ordered_set])
    contention = :ets.new(:fanout_contention, [:public, :named_table])

    receivers =
      for id <- 1..@receivers do
        Task.async(fn -> receiver_loop(id, counts, contention, 0) end)
      end

    senders =
      for s <- 1..@senders do
        Task.async(fn ->
          for i <- 1..@msgs_per_sender do
            case Smalt.Amqp.QueueStore.enqueue(@queue_a, <<s::32, i::32>>,
                   app_props: %{"stress" => true}
                 ) do
              {:ok, _seq} -> :ok
              {:error, :capacity} -> Process.sleep(1)
            end
          end
        end)
      end

    Task.await_many(senders, 120_000)
    :ets.insert(contention, {:senders_done, true})
    enqueue_done = System.monotonic_time(:millisecond)

    drain_until_empty(@queue_a, enqueue_done, 60_000)

    Enum.each(receivers, &Task.shutdown(&1, :brutal_kill))

    totals =
      counts
      |> :ets.tab2list()
      |> Enum.map(fn {_id, n} -> n end)

    min_c = Enum.min(totals)
    max_c = Enum.max(totals)
    zero_receivers = Enum.count(totals, &(&1 == 0))
    settled = Enum.sum(totals)
    ratio = if min_c == 0, do: nil, else: max_c / min_c

    spurious = read_counter(contention, :spurious_empty)
    races = read_counter(contention, :lock_race_retries)
    read_races = read_counter(contention, :store_read_races)

    # queue must be empty after drain
    residual =
      :ets.select_count(:smalt_sb_messages, [{{{@queue_a, :_}, :_}, [], [true]}])

    IO.puts("""

    == Phase A: fan-out fairness (#{@receivers} receivers x credit 1, one queue) ==
    messages enqueued   : #{@total_msgs}
    messages settled    : #{settled}
    residual in queue   : #{residual} (expect 0)
    receivers           : #{@receivers}
    active receivers    : #{@receivers - zero_receivers} (served >= 1)
    deliveries min/max  : #{min_c} / #{max_c}
    fairness max/min    : #{if ratio, do: Float.round(ratio, 3), else: "inf (some receivers starved)"}
    spurious :empty     : #{spurious} (messages existed but scan/lock got none)
    lock race retries   : #{races}
    store read races    : #{read_races} (rescued MatchError in messages/1)
    orphaned locks      : #{:ets.info(:smalt_sb_locks, :size)} (tokens never released)
    per-receiver hist   : #{histogram(totals)}
    """)

    verdict_a(settled, zero_receivers, ratio, residual)
  end

  # Receiver with credit 1: holds at most one in-flight message; after each
  # settle it immediately reaches for the next (hot loop under contention).
  defp receiver_loop(id, counts, contention, polls) do
    # credit-1 throttle: give the scheduler a breather every 64 polls
    polls = polls + 1
    if rem(polls, 16) == 0, do: Process.sleep(1)

    try do
      Smalt.Amqp.QueueStore.dequeue_matching(@queue_a)
    rescue
      _e ->
        # lib-level read race (QueueStore.messages/1: seq listed by :ets.match,
        # deleted by a concurrent complete/2 before Store.get) — observed, not
        # fabricated: record and retry.
        :ets.update_counter(contention, :store_read_races, 1, {:store_read_races, 0})
        receiver_loop(id, counts, contention, polls)
    else
      {:ok, msg, _lock} ->
        case Smalt.Amqp.QueueStore.complete(@queue_a, msg.seq) do
          :ok ->
            :ets.update_counter(counts, id, 1, {id, 0})
            receiver_loop(id, counts, contention, polls)

          other ->
            :ets.update_counter(contention, :lock_race_retries, 1, {:lock_race_retries, 0})
            _ = other
            receiver_loop(id, counts, contention, polls)
        end

      :empty ->
        cond do
          queue_empty?(@queue_a) and senders_done?(contention) ->
            :ok

          queue_empty?(@queue_a) ->
            # genuinely empty: idle-wait instead of hot-polling the metric
            Process.sleep(1)
            receiver_loop(id, counts, contention, polls)

          true ->
            # messages exist but this racer's scan saw none/none-lockable —
            # contention signal (all locked by other racers, or scan/lock race)
            :ets.update_counter(contention, :spurious_empty, 1, {:spurious_empty, 0})
            Process.sleep(1)
            receiver_loop(id, counts, contention, polls)
        end
    end
  end

  defp senders_done?(contention) do
    case :ets.lookup(contention, :senders_done) do
      [{:senders_done, true}] -> true
      _ -> false
    end
  end

  defp queue_empty?(queue),
    do: :ets.select_count(:smalt_sb_messages, [{{{queue, :_}, :_}, [], [true]}]) == 0

  # Receivers never exit on their own; the coordinator brutally kills them
  # after the drain window (drain deadline bounds their lifetime).

  defp drain_until_empty(queue, _from, budget_ms) do
    do_drain(queue, System.monotonic_time(:millisecond) + budget_ms)
  end

  defp do_drain(queue, deadline) do
    if queue_empty?(queue) or System.monotonic_time(:millisecond) > deadline do
      :ok
    else
      Process.sleep(10)
      do_drain(queue, deadline)
    end
  end

  # -- Phase B: session exclusivity ----------------------------------------------

  defp phase_b do
    {:ok, _} = Smalt.Amqp.QueueStore.enqueue(@queue_b, "seed", session_id: "s1")

    results =
      1..@receivers
      |> Task.async_stream(
        fn _ ->
          case Smalt.Amqp.LockManager.session_acquire(@queue_b, "s1", duration_ms: 5_000) do
            {:ok, lock} ->
              r = Smalt.Amqp.QueueStore.dequeue_matching(@queue_b, session_id: "s1")
              {:winner, lock.lock_token, r}

            {:error, :already_locked} ->
              {:loser, :already_locked}
          end
        end,
        max_concurrency: @receivers,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, v} -> v end)

    win = Enum.count(results, &match?({:winner, _, _}, &1))
    losers = Enum.count(results, &match?({:loser, :already_locked}, &1))

    crashes =
      Enum.count(results, fn
        {:winner, _, {:ok, _, _}} -> false
        {:winner, _, :empty} -> false
        {:winner, _, _other} -> true
        {:loser, :already_locked} -> false
        {:loser, _other} -> true
      end)

    delivered = Enum.count(results, &match?({:winner, _, {:ok, _, _}}, &1))

    IO.puts("""

    == Phase B: session exclusivity (#{@receivers} racers, one session) ==
    winners              : #{win} (expect 1)
    clean already_locked : #{losers} (expect 199)
    crashes/unexpected   : #{crashes} (expect 0)
    winner got message   : #{delivered} (expect 1)
    """)

    verdict_b(win, crashes)
  end

  defp read_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp histogram(totals) do
    Enum.frequencies(totals)
    |> Enum.sort()
    |> Enum.map(fn {n, c} -> "#{n}x#{c}" end)
    |> Enum.join(" ")
    |> String.slice(0, 200)
  end

  defp verdict_a(settled, zero, ratio, residual) do
    cond do
      settled == @total_msgs and residual == 0 and zero == 0 and is_float(ratio) and ratio <= 2.0 ->
        "VERDICT A: PASS — full drain, all 200 receivers served, fair (max/min <= 2.0)"

      settled == @total_msgs and residual == 0 and zero == 0 ->
        "VERDICT A: WEAK — full drain, all receivers served, unfair (max/min #{ratio})"

      true ->
        "VERDICT A: FAIL — settled=#{settled}/#{@total_msgs} idle=#{zero} residual=#{residual}"
    end
  end

  defp verdict_b(1, 0), do: "VERDICT B: PASS — exclusive session, 199 clean refusals, no crashes"
  defp verdict_b(w, c), do: "VERDICT B: FAIL — winners=#{w} crashes=#{c}"

  # -- shared --------------------------------------------------------------------

  defp wipe do
    for t <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_sessions] do
      if :ets.info(t) != :undefined, do: :ets.delete_all_objects(t)
    end
  end
end

Smalt.Stress.AmqpFanout.run()
