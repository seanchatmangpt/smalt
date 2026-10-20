# ERRC wave-3 lane (F-w2i-1): SB topic fan-out over the queue store.
#
# Chicago discipline: real QueueStore GenServer, real ETS store, real
# settlement — final state asserted, no mocks. The ARM materialization seam
# (router lane) is exercised via the same QueueStore.ensure_queue/1 call the
# router's sb_materialize_amqp/2 makes.
#
# Provenance (lib/ read fresh):
#   - lib/smalt/messaging/amqp/queue_store.ex: enqueue/3 routes to topic
#     fan-out when live "<topic>/Subscriptions/<sub>" rows exist in
#     :smalt_sb_queues; fan-out is one serialized claim inside the
#     queue_store server (check-all-then-insert-all, atomic refusal).
#   - lib/smalt/arm_gateway/router.ex: topic PUT provisions the topic entity;
#     subscription PUT provisions "<topic>/Subscriptions/<sub>".
defmodule InternalTier.SbTopicFanoutTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.QueueStore

  setup do
    {:ok, _} = GenServer.start_link(Smalt.Store, [])
    {:ok, _} = QueueStore.ensure_queue("wt")
    on_exit(fn ->
      if :ets.info(:smalt_sb_queues) != :undefined do
        for k <- Smalt.Store.keys(:smalt_sb_queues),
            is_binary(k) and String.contains?(k, "wt") do
          Smalt.Store.delete(:smalt_sb_queues, k)
        end

        for {k, _} <- :ets.tab2list(:smalt_sb_messages) do
          if is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), "wt") do
            :ets.delete(:smalt_sb_messages, k)
          end
        end

        Smalt.Store.delete(
          :smalt_resources,
          "/subscriptions/sub/resourcegroups/rg/providers/microsoft.servicebus/namespaces/ns/queues/wt/subscriptions/a"
        )
      end
    end)

    :ok
  end

  test "send to topic fans out a copy to every subscription queue" do
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/a")
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/b")

    for i <- 1..3, do: assert({:ok, {:fanout, 2}} = QueueStore.enqueue("wt", "m#{i}"))

    for sub <- ["a", "b"] do
      {:ok, msgs} = QueueStore.peek("wt/Subscriptions/#{sub}")
      assert length(msgs) == 3
      assert Enum.map(msgs, & &1.body) == ["m1", "m2", "m3"]
    end

    # The topic entity itself holds nothing under fan-out.
    {:ok, topic_msgs} = QueueStore.peek("wt")
    assert topic_msgs == []
  end

  test "zero subscriptions: parked face — message lands in the topic entity (disclosed)" do
    assert {:ok, seq} = QueueStore.enqueue("wt", "parked")
    assert is_integer(seq)

    {:ok, msgs} = QueueStore.peek("wt")
    assert Enum.map(msgs, & &1.body) == ["parked"]
  end

  test "complete in sub A leaves sub B's copies intact" do
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/a")
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/b")

    for i <- 1..3, do: QueueStore.enqueue("wt", "m#{i}")

    {:ok, m, lock} = QueueStore.dequeue_matching("wt/Subscriptions/a")
    :ok = QueueStore.complete("wt/Subscriptions/a", m.seq, lock_token: lock.lock_token)

    {:ok, a_rest} = QueueStore.peek("wt/Subscriptions/a")
    {:ok, b_all} = QueueStore.peek("wt/Subscriptions/b")
    assert length(a_rest) == 2
    assert length(b_all) == 3
  end

  test "subscription addresses never re-fan-out (no nested topics)" do
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/a")
    assert QueueStore.subscription_queues("wt/Subscriptions/a") == []
  end

  test "fan-out refusal is atomic: session-required sub refuses the whole fan-out" do
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/a")
    {:ok, _} = QueueStore.ensure_queue("wt/Subscriptions/b")

    # Real ARM seam: queue_settings/1 reads requiresSession from the
    # :smalt_resources record whose downcased id ends "/queues/<entity>".
    Smalt.Store.put(:smalt_resources, "/subscriptions/sub/resourcegroups/rg/providers/microsoft.servicebus/namespaces/ns/queues/wt/subscriptions/a", %{
      "properties" => %{"requiresSession" => true}
    })

    assert {:error, :session_required} = QueueStore.enqueue("wt", "m1")

    # Atomicity: the refusal must not have delivered the copy into b.
    {:ok, a} = QueueStore.peek("wt/Subscriptions/a")
    {:ok, b} = QueueStore.peek("wt/Subscriptions/b")
    assert a == []
    assert b == []
  end
end
