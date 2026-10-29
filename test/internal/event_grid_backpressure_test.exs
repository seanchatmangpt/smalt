defmodule Smalt.EventGridBackpressureTest do
  @moduledoc """
  SCVD-T8 remediation tests (backpressure audit HIGH-1/HIGH-2).

  Chicago-style: real `Smalt.Messaging.EventGrid` process, real
  publish/deliver over in-proc messages — no mocks. Asserts the typed
  capacity bounds actually drop/prune and the telemetry counters increment.
  """

  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventGrid

  @queue_overflow [:smalt, :event_grid, :queue_overflow_dropped]
  @dedup_evicted [:smalt, :event_grid, :dedup_evicted]

  setup do
    prev = Application.get_env(:smalt, :event_grid)

    counter = :"eg_bp_ctr_#{System.unique_integer([:positive])}"
    :ets.new(counter, [:public, :named_table, :set])
    :ets.insert(counter, [{@queue_overflow, 0}, {@dedup_evicted, 0}])

    handler_id = :"eg_bp_q_#{System.unique_integer([:positive])}"
    dedup_handler_id = :"eg_bp_d_#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @queue_overflow,
        fn _name, %{count: n}, _meta, tbl ->
          :ets.update_counter(tbl, @queue_overflow, n)
        end,
        counter
      )

    :ok =
      :telemetry.attach(
        dedup_handler_id,
        @dedup_evicted,
        fn _name, %{count: n}, _meta, tbl ->
          :ets.update_counter(tbl, @dedup_evicted, n)
        end,
        counter
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :telemetry.detach(dedup_handler_id)
      restore_env(prev)
      if :ets.whereis(counter) != :undefined, do: :ets.delete(counter)
    end)

    {:ok, counter: counter}
  end

  defp restore_env(nil), do: Application.delete_env(:smalt, :event_grid)
  defp restore_env(prev), do: Application.put_env(:smalt, :event_grid, prev)

  defp count(tbl, key), do: :ets.lookup_element(tbl, key, 2)

  defp set_env(kw) do
    Application.put_env(:smalt, :event_grid, kw)
  end

  test "queue cap: overflow drops the oldest queued events, counter increments", %{
    counter: counter
  } do
    set_env(max_queue_len: 20)
    topic = :"eg-bp-queue-#{System.unique_integer([:positive])}"
    EventGrid.reset(topic)

    # A real, live subscriber that never acks: first published event goes
    # inflight, the rest accumulate in the queue until the cap prunes.
    subscriber = spawn(__MODULE__, :never_acking_subscriber, [])

    EventGrid.subscribe(topic, :bp_sub, subscriber)

    for i <- 1..22 do
      assert EventGrid.publish(topic, %{id: "e-#{i}"}) == :fresh
    end

    {pending, inflight, _alive} = EventGrid.status(topic, :bp_sub)
    assert pending == 20
    assert {id, _ev, _ts, _attempts} = inflight
    assert id == "e-1"

    # 22 published - 1 inflight - 20 queued = 1 dropped (the oldest).
    assert count(counter, @queue_overflow) == 1

    # The queue retained the NEWEST events (drop-oldest, e-2 was dropped):
    # ack through the pipe — e-1 inflight, then e-3..e-22 in order.
    for i <- [1] ++ Enum.to_list(3..22), do: EventGrid.ack(topic, :bp_sub, "e-#{i}")
    {pending2, _inflight2, _alive2} = EventGrid.status(topic, :bp_sub)
    assert pending2 == 0

    Process.exit(subscriber, :kill)
    EventGrid.reset(topic)
  end

  def never_acking_subscriber do
    receive do
      _ -> never_acking_subscriber()
    end
  end

  test "seen_ids cap: FIFO eviction of oldest ids, counter increments", %{counter: counter} do
    set_env(max_seen_ids: 50)
    topic = :"eg-bp-dedup-#{System.unique_integer([:positive])}"
    EventGrid.reset(topic)

    for i <- 1..60 do
      assert EventGrid.publish(topic, %{id: "d-#{i}"}) == :fresh
    end

    # Oldest 10 ids evicted from the dedup window.
    assert count(counter, @dedup_evicted) == 10

    # Evicted id is re-admitted as :fresh (bounded window).
    assert EventGrid.publish(topic, %{id: "d-1"}) == :fresh
    assert count(counter, @dedup_evicted) == 11

    # Recent id is still deduplicated.
    assert EventGrid.publish(topic, %{id: "d-60"}) == :duplicate

    EventGrid.reset(topic)
  end
end
