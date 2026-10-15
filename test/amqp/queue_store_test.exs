defmodule Smalt.Amqp.QueueStoreTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.{LockManager, QueueStore}

  @tables [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks, :smalt_sb_sessions]

  setup do
    # Bootstrap sb tables if the coordinator's Store revision hasn't landed yet.
    Enum.each(@tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      end
    end)

    Enum.each(@tables, &:ets.delete_all_objects/1)

    # queue_settings/1 reads the ARM resource table; bootstrap it too so the
    # suite runs green standalone (no app boot) and under full `mix test`.
    if :ets.info(:smalt_resources) == :undefined do
      :ets.new(:smalt_resources, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    :ets.delete_all_objects(:smalt_resources)
    :ok
  end

  describe "ensure_queue/1" do
    test "creates and is idempotent" do
      assert {:ok, %{capacity: 4096, name: "q"}} = QueueStore.ensure_queue("q")
      assert {:ok, info2} = QueueStore.ensure_queue("q")
      assert info2.name == "q"
    end
  end

  describe "enqueue/3" do
    test "assigns monotonic per-queue sequence numbers" do
      assert {:ok, 1} = QueueStore.enqueue("q", "a")
      assert {:ok, 2} = QueueStore.enqueue("q", "b")
      assert {:ok, 3} = QueueStore.enqueue("q", "c")
    end

    test "sequence counters are per-queue" do
      assert {:ok, 1} = QueueStore.enqueue("q1", "a")
      assert {:ok, 1} = QueueStore.enqueue("q2", "b")
      assert {:ok, 2} = QueueStore.enqueue("q1", "c")
    end

    test "parallel enqueues get unique, monotonically dense sequence numbers" do
      tasks =
        for i <- 1..50 do
          Task.async(fn -> QueueStore.enqueue("par", "body-#{i}") end)
        end

      seqs = Enum.map(tasks, &Task.await/1) |> Enum.map(fn {:ok, s} -> s end)

      assert length(Enum.uniq(seqs)) == 50
      assert Enum.sort(seqs) == Enum.to_list(1..50)
    end

    test "rejects bodies over 1 MiB with :too_large" do
      big = :binary.copy(<<"x">>, 1 * 1024 * 1024 + 1)
      assert {:error, :too_large} = QueueStore.enqueue("q", big)
      # exactly 1 MiB is fine
      assert {:ok, _} = QueueStore.enqueue("q", :binary.copy(<<"x">>, 1 * 1024 * 1024))
    end

    test "rejects the 4097th message with :capacity" do
      for _ <- 1..4096, do: QueueStore.enqueue("capq", "x")
      assert {:error, :capacity} = QueueStore.enqueue("capq", "over")
    end

    test "stores session_id and annotations" do
      {:ok, _} = QueueStore.enqueue("q", "s", session_id: "sess-1", annotations: %{"k" => "v"})
      assert {:ok, msg} = Smalt.Store.get(:smalt_sb_messages, {"q", 1})
      assert msg.session_id == "sess-1"
      assert msg.annotations == %{"k" => "v"}
      assert msg.state == :available
    end
  end

  describe "dequeue_matching/2" do
    test "delivers in sequence order and locks" do
      {:ok, _} = QueueStore.enqueue("q", "a")
      {:ok, _} = QueueStore.enqueue("q", "b")
      now = 1_000

      assert {:ok, m1, lock1} = QueueStore.dequeue_matching("q", now_ms: now, lock_duration_ms: 500)
      assert m1.seq == 1
      assert m1.delivery_count == 1
      assert m1.state == :locked
      assert lock1.locked_until == 1_500

      assert {:ok, m2, _} = QueueStore.dequeue_matching("q", now_ms: now, lock_duration_ms: 500)
      assert m2.seq == 2

      assert :empty = QueueStore.dequeue_matching("q", now_ms: now)
    end

    test "skips locked-until > now but redelivers after expiry with incremented delivery_count" do
      {:ok, _} = QueueStore.enqueue("q", "a")
      {:ok, m, lock} = QueueStore.dequeue_matching("q", now_ms: 1_000, lock_duration_ms: 500)
      assert m.seq == 1

      # still locked
      assert :empty = QueueStore.dequeue_matching("q", now_ms: 1_400)
      # expired: redelivered, delivery_count incremented
      assert {:ok, m2, lock2} = QueueStore.dequeue_matching("q", now_ms: 1_501)
      assert m2.seq == 1
      assert m2.delivery_count == 2
      assert lock2.lock_token != lock.lock_token
    end

    test "skips deferred and dead messages" do
      {:ok, s1} = QueueStore.enqueue("q", "a")
      {:ok, s2} = QueueStore.enqueue("q", "b")
      {:ok, _} = QueueStore.enqueue("q", "c")

      :ok = QueueStore.defer("q", s1)
      {:ok, _, _} = QueueStore.dequeue_matching("q", now_ms: 1_000)
      {:ok, _} = QueueStore.deadletter("q", s2, "bad")
      assert {:ok, m, _} = QueueStore.dequeue_matching("q", now_ms: 1_000)
      assert m.seq == 3
    end

    test "session filter matches only messages with that session_id" do
      {:ok, _} = QueueStore.enqueue("q", "plain")
      {:ok, _} = QueueStore.enqueue("q", "s1", session_id: "sess-1")
      {:ok, _} = QueueStore.enqueue("q", "s2", session_id: "sess-2")

      assert {:ok, m, _} = QueueStore.dequeue_matching("q", now_ms: 1_000, session_id: "sess-2")
      assert m.body == "s2"

      # no session filter: the nil-session "plain" message is next in seq order
      assert {:ok, p, _} = QueueStore.dequeue_matching("q", now_ms: 1_000, session_id: nil)
      assert p.body == "plain"
      # the sess-1 message is still there and matches its own session filter
      assert {:ok, m1, _} = QueueStore.dequeue_matching("q", now_ms: 1_000, session_id: "sess-1")
      assert m1.body == "s1"
    end
  end

  describe "peek/2" do
    test "returns {:ok, messages} without changing state" do
      for i <- 1..5, do: QueueStore.enqueue("q", "m#{i}")

      assert {:ok, [%{seq: 1}, %{seq: 2}]} = QueueStore.peek("q", message_count: 2)
      assert {:ok, [%{seq: 3}, %{seq: 4}, %{seq: 5}]} = QueueStore.peek("q", from_sequence_number: 3)

      # peek does not lock or increment delivery_count
      assert {:ok, m} = Smalt.Store.get(:smalt_sb_messages, {"q", 1})
      assert m.state == :available and m.delivery_count == 0
    end

    test "clamps message_count to 1..100" do
      assert {:ok, []} = QueueStore.peek("empty-q")

      for i <- 1..5, do: QueueStore.enqueue("q", "m#{i}")
      assert {:ok, msgs} = QueueStore.peek("q", message_count: 0)
      assert length(msgs) == 1
      assert {:ok, msgs} = QueueStore.peek("q", message_count: 1000)
      assert length(msgs) == 5
    end
  end

  # `$management` pinned contracts that lane 6's management_rpc_test.exs tagged
  # :amqp_wire to re-run against these concrete sibling modules. Exercised here
  # directly (that file is not this lane's to edit).
  describe "management rpc contract (amqp_wire, real modules)" do
    @now 1_700_000_000_000

    test "renew_lock/2 returns {:ok, expiry_ms} for a live lock" do
      {:ok, lock} = LockManager.acquire("q", 1, now_ms: @now, duration_ms: 5_000)
      assert {:ok, expiry} = LockManager.renew_lock(lock.lock_token, @now + 1_000)
      assert is_integer(expiry)
      assert expiry == @now + 6_000
    end

    test "renew_lock/2 unknown token -> :not_found, expired -> :lock_lost" do
      assert {:error, :not_found} = LockManager.renew_lock("00000000-0000-4000-8000-000000000000", @now)

      {:ok, lock} = LockManager.acquire("q", 1, now_ms: @now, duration_ms: 500)
      assert {:error, :lock_lost} = LockManager.renew_lock(lock.lock_token, @now + 500)
    end

    test "renew_session_lock/3 returns {:ok, expiry_ms}; expired -> :session_lock_lost" do
      {:ok, _} = LockManager.session_acquire("q", "s1", now_ms: @now, duration_ms: 5_000)
      assert {:ok, expiry} = LockManager.renew_session_lock("q", "s1", @now + 1_000)
      assert expiry == @now + 6_000

      {:ok, _} = LockManager.session_acquire("q", "s2", now_ms: @now, duration_ms: 500)
      assert {:error, :session_lock_lost} = LockManager.renew_session_lock("q", "s2", @now + 500)
      assert {:error, :not_found} = LockManager.renew_session_lock("q", "ghost", @now)
    end

    test "peek/2 accepts the management peek opts and returns {:ok, messages}" do
      for i <- 1..3, do: QueueStore.enqueue("peek-mp", "m#{i}")

      opts = [from_sequence_number: 1, message_count: 2, now: @now]
      assert {:ok, [%{seq: 1, body: "m1"}, %{seq: 2, body: "m2"}]} = QueueStore.peek("peek-mp", opts)

      assert {:ok, []} =
               QueueStore.peek("peek-mp", from_sequence_number: 99, message_count: 1, now: @now)
    end

    test "peek/2 clamps message_count outside 1..100 (management bounds)" do
      for i <- 1..3, do: QueueStore.enqueue("peek-mp", "m#{i}")
      assert {:ok, one} = QueueStore.peek("peek-mp", message_count: 0, now: @now)
      assert length(one) == 1
      assert {:ok, all} = QueueStore.peek("peek-mp", message_count: 1000, now: @now)
      assert length(all) == 3
    end
  end

  describe "defer/3 and release/3" do
    test "defer makes message invisible to dequeue" do
      {:ok, s} = QueueStore.enqueue("q", "a")
      {:ok, _, _} = QueueStore.dequeue_matching("q", now_ms: 1_000)
      assert :ok = QueueStore.defer("q", s)
      assert :empty = QueueStore.dequeue_matching("q", now_ms: 2_000)
      assert {:ok, m} = Smalt.Store.get(:smalt_sb_messages, {"q", s})
      assert m.state == :deferred
    end

    test "release after lock expiry returns message to :available" do
      {:ok, s} = QueueStore.enqueue("q", "a")
      {:ok, _, _} = QueueStore.dequeue_matching("q", now_ms: 1_000)
      assert :ok = QueueStore.release("q", s)
      assert {:ok, m} = Smalt.Store.get(:smalt_sb_messages, {"q", s})
      assert m.state == :available
      assert m.lock_token == nil
      assert {:ok, m2, _} = QueueStore.dequeue_matching("q", now_ms: 1_100)
      assert m2.seq == s
      assert m2.delivery_count == 2
    end

    test "defer/release of unknown sequence returns :error" do
      assert :error = QueueStore.defer("q", 999)
      assert :error = QueueStore.release("q", 999)
    end
  end

  describe "deadletter/5" do
    test "moves message to DLQ with fresh seq, preserving body and stamping DLQ props" do
      {:ok, _} = QueueStore.enqueue("q", "poison")
      {:ok, seq} = QueueStore.enqueue("q", "second", annotations: %{"orig" => "yes"})

      assert {:ok, dlq_seq} = QueueStore.deadletter("q", seq, "max-delivery", "too many tries")

      assert {:ok, dlq_msg} = Smalt.Store.get(:smalt_sb_messages, {"q/$deadletterqueue", dlq_seq})
      assert dlq_msg.body == "second"
      assert dlq_msg.annotations["DeadLetterReason"] == "max-delivery"
      assert dlq_msg.annotations["DeadLetterErrorDescription"] == "too many tries"
      assert dlq_msg.annotations["orig"] == "yes"

      # source message removed
      assert :error = Smalt.Store.get(:smalt_sb_messages, {"q", seq})

      # DLQ is its own entity with its own sequence space and is dequeueable
      assert {:ok, d, _} =
               QueueStore.dequeue_matching("q/$deadletterqueue", now_ms: 1_000)

      assert d.body == "second"
    end

    test "DLQ sequence counter is independent of the source queue" do
      {:ok, _} = QueueStore.enqueue("q", "one")
      {:ok, s} = QueueStore.enqueue("q", "two")
      {:ok, dlq_seq} = QueueStore.deadletter("q", s, "reason")
      assert dlq_seq == 1

      {:ok, s2} = QueueStore.enqueue("q", "three")
      {:ok, dlq_seq2} = QueueStore.deadletter("q", s2, "reason")
      assert dlq_seq2 == 2
    end

    test "unknown sequence returns :error" do
      assert :error = QueueStore.deadletter("q", 42, "reason")
    end

    test "deadlettering a locked message releases its lock" do
      {:ok, s} = QueueStore.enqueue("q", "x")
      {:ok, m, lock} = QueueStore.dequeue_matching("q", now_ms: 1_000)
      {:ok, _} = QueueStore.deadletter("q", m.seq, "reason")
      assert :error = LockManager.get(lock.lock_token)
      assert s == m.seq
    end
  end

  describe "parse_iso8601_duration/1" do
    test "parses seconds, composite and hour forms" do
      assert QueueStore.parse_iso8601_duration("PT30S") == 30_000
      assert QueueStore.parse_iso8601_duration("PT1M30S") == 90_000
      assert QueueStore.parse_iso8601_duration("PT2H") == 7_200_000
      assert QueueStore.parse_iso8601_duration("PT1M") == 60_000
      assert QueueStore.parse_iso8601_duration("P1D") == 86_400_000
      assert QueueStore.parse_iso8601_duration("P1DT1M") == 86_460_000
    end

    test "invalid or missing duration returns nil" do
      assert QueueStore.parse_iso8601_duration("garbage") == nil
      assert QueueStore.parse_iso8601_duration("PT") == nil
      assert QueueStore.parse_iso8601_duration("PT1X") == nil
      assert QueueStore.parse_iso8601_duration("") == nil
      assert QueueStore.parse_iso8601_duration(nil) == nil
      assert QueueStore.parse_iso8601_duration(42) == nil
    end
  end

  describe "queue_settings/1" do
    test "defaults when no ARM record exists" do
      assert %{requires_session: false, lock_duration_ms: 30_000, max_delivery_count: 10} =
               QueueStore.queue_settings("no-arm-q")
    end

    test "reads properties from the ARM resource record" do
      :ets.insert(:smalt_resources, {
        String.downcase("/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns1/queues/sessq"),
        %{
          "id" => "ignored",
          "name" => "sessq",
          "type" => "Microsoft.ServiceBus/namespaces/queues",
          "properties" => %{
            "requiresSession" => true,
            "lockDuration" => "PT15S",
            "maxDeliveryCount" => 3
          }
        }
      })

      assert %{requires_session: true, lock_duration_ms: 15_000, max_delivery_count: 3} =
               QueueStore.queue_settings("sessq")
    end

    test "clamps lock duration and falls back to default max delivery count" do
      :ets.insert(:smalt_resources, {
        String.downcase("/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns2/queues/oddq"),
        %{
          "properties" => %{"lockDuration" => "PT5S", "maxDeliveryCount" => "bogus"}
        }
      })

      assert %{lock_duration_ms: 5_000, max_delivery_count: 10} = QueueStore.queue_settings("oddq")

      :ets.insert(:smalt_resources, {
        String.downcase("/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns3/queues/tightq"),
        %{"properties" => %{"lockDuration" => "PT1S"}}
      })

      # 1000ms is within bounds; below 100ms clamps up
      :ets.insert(:smalt_resources, {
        String.downcase("/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/ns4/queues/tinyq"),
        %{"properties" => %{"lockDuration" => "PT0.05S"}}
      })

      # fractional seconds are not supported by the parser -> default 30000
      assert %{lock_duration_ms: 30_000} = QueueStore.queue_settings("tinyq")
      assert %{lock_duration_ms: 1_000} = QueueStore.queue_settings("tightq")
    end
  end

  describe "session_required enforcement" do
    test "enqueue without session_id fails when the queue requires sessions" do
      seed_arm_queue("sess-enf", %{"requiresSession" => true})

      assert {:error, :session_required} = QueueStore.enqueue("sess-enf", "x")
      assert {:ok, _} = QueueStore.enqueue("sess-enf", "x", session_id: "s1")

      # plain queue unaffected
      assert {:ok, _} = QueueStore.enqueue("plain-q", "x")
    end
  end

  describe "max delivery count deadletter" do
    test "abandon at max_delivery_count deadletters instead of releasing" do
      seed_arm_queue("mdq", %{"maxDeliveryCount" => 2})
      {:ok, seq} = QueueStore.enqueue("mdq", "poison")

      # delivery 1 -> abandon releases
      {:ok, m1, _} = QueueStore.dequeue_matching("mdq", now_ms: 1_000)
      assert m1.seq == seq
      assert :ok = QueueStore.release("mdq", seq)
      assert {:ok, %{state: :available}} = Smalt.Store.get(:smalt_sb_messages, {"mdq", seq})

      # delivery 2 (count now 2 >= max 2) -> abandon deadletters
      {:ok, m2, _} = QueueStore.dequeue_matching("mdq", now_ms: 2_000)
      assert m2.delivery_count == 2
      assert :ok = QueueStore.release("mdq", seq)

      assert :error = Smalt.Store.get(:smalt_sb_messages, {"mdq", seq})
      assert {:ok, dlq_msg} = Smalt.Store.get(:smalt_sb_messages, {"mdq/$deadletterqueue", 1})
      assert dlq_msg.annotations["DeadLetterReason"] == "MaxDeliveryCountExceeded"
      assert dlq_msg.body == "poison"
    end

    test "default queue keeps releasing below the default max of 10" do
      {:ok, seq} = QueueStore.enqueue("ddq", "a")
      {:ok, _, _} = QueueStore.dequeue_matching("ddq", now_ms: 1_000)
      assert :ok = QueueStore.release("ddq", seq)
      assert {:ok, %{state: :available, delivery_count: 1}} = Smalt.Store.get(:smalt_sb_messages, {"ddq", seq})
    end
  end

  describe "lock duration from queue settings" do
    test "dequeue uses the ARM lockDuration unless overridden by opt" do
      seed_arm_queue("ldq", %{"lockDuration" => "PT15S"})
      {:ok, _} = QueueStore.enqueue("ldq", "a")

      {:ok, _m, lock} = QueueStore.dequeue_matching("ldq", now_ms: 1_000)
      assert lock.locked_until == 1_000 + 15_000

      {:ok, _} = QueueStore.enqueue("ldq", "b")
      {:ok, _m2, lock2} = QueueStore.dequeue_matching("ldq", now_ms: 1_000, lock_duration_ms: 500)
      assert lock2.locked_until == 1_500
    end
  end

  describe "concurrency (ST4 court)" do
    test "200-racer dequeue: 1000 messages -> exactly 1000 deliveries, no duplicates, no orphaned tokens" do
      total = 1000

      for i <- 1..total, do: {:ok, _} = QueueStore.enqueue("race-q", <<i::32>>)

      # drain concurrently with 200 racers, each settling what it claims
      delivered =
        1..200
        |> Enum.map(fn _ ->
          Task.async(fn ->
            try do
              drain_loop("race-q")
            rescue
              e -> flunk("dequeue_matching raised: #{Exception.format(:error, e)}")
            end
          end)
        end)
        |> Task.await_many(60_000)
        |> List.flatten()

      assert length(delivered) == total
      assert length(Enum.uniq(delivered)) == total

      # queue fully drained
      assert :ets.select_count(:smalt_sb_messages, [{{{"race-q", :_}, :_}, [], [true]}]) == 0

      # zero orphaned lock tokens after complete-all
      assert :ets.info(:smalt_sb_locks, :size) == 0
    end

    test "dequeue + complete under contention never raises (messages/1 read race is gone)" do
      for i <- 1..200, do: {:ok, _} = QueueStore.enqueue("churn-q", <<i::32>>)

      completers =
        for _ <- 1..50 do
          Task.async(fn ->
            for _ <- 1..200, do: QueueStore.complete("churn-q", :rand.uniform(400))
          end)
        end

      claimers =
        for _ <- 1..50 do
          Task.async(fn ->
            try do
              for _ <- 1..200, do: QueueStore.dequeue_matching("churn-q")
            rescue
              e -> flunk("dequeue_matching raised: #{Exception.format(:error, e)}")
            end
          end)
        end

      Task.await_many(completers ++ claimers, 60_000)
    end

    test "sweep/0 reclaims expired message locks back to :available" do
      {:ok, _} = QueueStore.enqueue("sweep-q", "a")
      {:ok, m, lock} = QueueStore.dequeue_matching("sweep-q", now_ms: 1_000, lock_duration_ms: 500)

      now = System.system_time(:millisecond)
      real_sweeps = QueueStore.sweep()
      assert is_integer(real_sweeps)

      # deterministic re-queue of an expired lock (real now: nothing expired yet,
      # so backdate by hand and sweep via the serialized path)
      Smalt.Store.put(:smalt_sb_messages, {"sweep-q", m.seq}, %{m | locked_until: now - 1})

      assert QueueStore.sweep() >= 1
      assert {:ok, %{state: :available, lock_token: nil}} = Smalt.Store.get(:smalt_sb_messages, {"sweep-q", m.seq})
      assert :error = LockManager.get(lock.lock_token)
    end
  end

  defp drain_loop(queue) do
    case QueueStore.dequeue_matching(queue) do
      {:ok, msg, _lock} ->
        :ok = QueueStore.complete(queue, msg.seq)
        [msg.seq | drain_loop(queue)]

      :empty ->
        []
    end
  end

  defp seed_arm_queue(name, props) do
    key =
      String.downcase(
        "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ServiceBus/namespaces/test-ns/queues/#{name}"
      )

    :ets.insert(:smalt_resources, {key, %{"properties" => props}})
  end
end
