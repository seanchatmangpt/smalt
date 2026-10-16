defmodule Smalt.Amqp.ManagementRpcTest do
  use ExUnit.Case, async: true

  alias Smalt.Amqp.ManagementRpc

  @now 1_700_000_000_000

  # Real in-test collaborators (not mocks): hand-written real implementations
  # of the pinned lane-3 contracts, matching the signatures in the module
  # docs. Sibling modules (Smalt.Amqp.LockManager / Smalt.Amqp.QueueStore) are
  # other lanes' files; until they land, the module under test resolves them
  # through the context map, so these tests exercise the real dispatch +
  # status tables against real collaborators. #amqp_wire marks the tests that
  # must be re-run against the concrete sibling modules once lane 3 lands.
  defmodule TestLockManager do
    def renew_lock("lost", _now), do: {:error, :lock_lost}
    def renew_lock(_token, now), do: {:ok, now + 30_000}

    def renew_session_lock(_queue, "gone", _now), do: {:error, :session_lock_lost}
    def renew_session_lock(_queue, _session_id, now), do: {:ok, now + 30_000}
  end

  defmodule TestQueueStore do
    def peek(_queue, opts) do
      from = Keyword.fetch!(opts, :from_sequence_number)
      count = Keyword.fetch!(opts, :message_count)
      available = [%{body: "m0"}, %{body: "m1"}, %{body: "m2"}]
      {:ok, Enum.slice(available, from, count)}
    end
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        lock_manager: TestLockManager,
        queue_store: TestQueueStore,
        now: @now
      },
      overrides
    )
  end

  describe "com.microsoft:renew-lock" do
    @tag :amqp_wire
    test "200 with expirations timestamps" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:renew-lock",
            body: %{"lock-tokens" => ["tok-a", "tok-b"]},
            correlation_id: "corr-1"
          },
          ctx()
        )

      assert resp == %{
               status_code: 200,
               status_description: "OK",
               body: %{
                 "expirations" => [
                   {:timestamp, @now + 30_000},
                   {:timestamp, @now + 30_000}
                 ]
               },
               correlation_id: "corr-1"
             }
    end

    test "410 MESSAGE_LOCK_LOST when lock no longer held" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:renew-lock",
            body: %{"lock-tokens" => ["lost"]},
            correlation_id: "c2"
          },
          ctx()
        )

      assert %{status_code: 410, status_description: "MESSAGE_LOCK_LOST", body: nil} = resp
      assert resp.correlation_id == "c2"
    end

    test "400 LOCK_TOKEN_REQUIRED on missing or empty lock-tokens" do
      for body <- [%{}, %{"lock-tokens" => []}, %{"lock-tokens" => [nil]}] do
        resp = ManagementRpc.handle(%{operation: "com.microsoft:renew-lock", body: body}, ctx())
        assert resp.status_code == 400
        assert resp.status_description == "LOCK_TOKEN_REQUIRED"
      end
    end

    test "accepts symbol operation form" do
      resp =
        ManagementRpc.handle(
          %{
            operation: {:symbol, "com.microsoft:renew-lock"},
            body: %{"lock-tokens" => ["tok"]}
          },
          ctx()
        )

      assert resp.status_code == 200
    end
  end

  describe "com.microsoft:renew-session-lock" do
    @tag :amqp_wire
    test "200 with expiration timestamp" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:renew-session-lock",
            body: %{"session-id" => "s1", queue: "q"},
            correlation_id: "c3"
          },
          ctx()
        )

      assert resp == %{
               status_code: 200,
               status_description: "OK",
               body: %{"expiration" => {:timestamp, @now + 30_000}},
               correlation_id: "c3"
             }
    end

    test "410 SESSION_LOCK_LOST when session lock expired" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:renew-session-lock",
            body: %{"session-id" => "gone", queue: "q"}
          },
          ctx()
        )

      assert %{status_code: 410, status_description: "SESSION_LOCK_LOST"} = resp
    end

    test "400 SESSION_ID_REQUIRED on missing or empty session-id" do
      for body <- [%{}, %{"session-id" => nil}, %{"session-id" => ""}] do
        resp =
          ManagementRpc.handle(
            %{operation: "com.microsoft:renew-session-lock", body: body},
            ctx()
          )

        assert resp.status_code == 400
        assert resp.status_description == "SESSION_ID_REQUIRED"
      end
    end
  end

  describe "com.microsoft:peek-message" do
    test "200 with messages wrapper" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:peek-message",
            body: %{"from-sequence-number" => 1, "message-count" => 2, queue: "q"},
            correlation_id: "c4"
          },
          ctx()
        )

      assert resp == %{
               status_code: 200,
               status_description: "OK",
               body: %{"messages" => [%{"message" => "m1"}, %{"message" => "m2"}]},
               correlation_id: "c4"
             }
    end

    test "204 NO_CONTENT when nothing to peek" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:peek-message",
            body: %{"from-sequence-number" => 99, "message-count" => 1, queue: "q"}
          },
          ctx()
        )

      assert %{status_code: 204, status_description: "NO_CONTENT", body: nil} = resp
    end

    test "400 PEEK_BOUNDS outside 1..100" do
      for count <- [0, -1, 101, 1000, "many", nil] do
        resp =
          ManagementRpc.handle(
            %{
              operation: "com.microsoft:peek-message",
              body: %{"from-sequence-number" => 0, "message-count" => count, queue: "q"}
            },
            ctx()
          )

        assert resp.status_code == 400, "count #{inspect(count)} should be rejected"
        assert resp.status_description == "PEEK_BOUNDS"
      end
    end

    test "bounds are inclusive: 1 and 100 both accepted" do
      for count <- [1, 100] do
        resp =
          ManagementRpc.handle(
            %{
              operation: "com.microsoft:peek-message",
              body: %{"from-sequence-number" => 0, "message-count" => count, queue: "q"}
            },
            ctx()
          )

        assert resp.status_code in [200, 204], "count #{count} should be in bounds"
      end
    end

    test "defaults: from-sequence-number 0, message-count 1" do
      resp =
        ManagementRpc.handle(
          %{operation: "com.microsoft:peek-message", body: %{queue: "q"}},
          ctx()
        )

      assert %{status_code: 200, body: %{"messages" => [%{"message" => "m0"}]}} = resp
    end

    test "non-integer from-sequence-number is 400" do
      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:peek-message",
            body: %{"from-sequence-number" => "abc", "message-count" => 1, queue: "q"}
          },
          ctx()
        )

      assert %{status_code: 400, status_description: "PEEK_BOUNDS"} = resp
    end

    @tag :amqp_wire
    test "store error surfaces as 404" do
      resp =
        ManagementRpc.handle(
          %{operation: "com.microsoft:peek-message", body: %{queue: "q"}},
          %{queue_store: fn _q, _opts -> {:error, :no_such_queue} end}
        )

      assert %{status_code: 404, status_description: "NOT_FOUND"} = resp
    end
  end

  describe "unknown and malformed" do
    test "unknown operation is 501 UNSUPPORTED_OPERATION" do
      for op <- ["com.microsoft:receive-by-sequence", "totally-bogus"] do
        resp = ManagementRpc.handle(%{operation: op, body: %{}}, ctx())
        assert resp.status_code == 501
        assert resp.status_description == "UNSUPPORTED_OPERATION"
      end
    end

    test "non-map request is 400" do
      assert %{status_code: 400, status_description: "MALFORMED_REQUEST"} =
               ManagementRpc.handle("not-a-map", %{})
    end

    test "correlation_id nil when absent, echoed when present" do
      absent = ManagementRpc.handle(%{operation: "com.microsoft:renew-lock", body: %{}}, ctx())
      assert absent.correlation_id == nil
    end
  end

  # ===========================================================================
  # com.microsoft:update-disposition (real LockManager + QueueStore)
  # ===========================================================================

  describe "com.microsoft:update-disposition (real collaborators)" do
    setup do
      SmaltTest.Lifecycle.ensure_store_up()

      for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks] do
        if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
      end

      :ok
    end

    test "completed settles via raw 16-byte wire uuid token" do
      queue = "ud-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "m1")
      assert {:ok, %{seq: seq}, lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      raw = Smalt.Amqp.LockManager.token_to_raw(lock.lock_token)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{"lock-tokens" => [{:uuid, raw}], "disposition-status" => "completed"},
            queue: queue
          },
          %{now: @now}
        )

      assert resp.status_code == 200
      assert :error = Smalt.Store.get(:smalt_sb_messages, {queue, seq})
    end

    test "abandoned requeues with delivery_count increment (SDK redelivery parity)" do
      queue = "ud-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "m1")
      assert {:ok, %{seq: seq, delivery_count: dc0}, lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      raw = Smalt.Amqp.LockManager.token_to_raw(lock.lock_token)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{"lock-tokens" => [{:uuid, raw}], "disposition-status" => "abandoned"},
            queue: queue
          },
          %{now: @now}
        )

      assert resp.status_code == 200
      assert {:ok, %{seq: ^seq, delivery_count: dc}, _} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      assert dc > dc0
    end

    test "suspended (dead-letter) with census-exact body keys settles to DLQ" do
      queue = "ud-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "m1")
      assert {:ok, %{seq: seq}, lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      raw = Smalt.Amqp.LockManager.token_to_raw(lock.lock_token)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{
              "lock-tokens" => {:array, [{:uuid, raw}]},
              "disposition-status" => "suspended",
              "deadletter-reason" => "COURT_REJECTED",
              "deadletter-description" => "local-test"
            },
            queue: queue
          },
          %{now: @now}
        )

      assert resp.status_code == 200
    end

    test "410 MESSAGE_LOCK_LOST on unknown token" do
      raw = :crypto.strong_rand_bytes(16)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{"lock-tokens" => [{:uuid, raw}], "disposition-status" => "completed"},
            queue: "ud-none"
          },
          %{now: @now}
        )

      assert resp.status_code == 410
    end
  end

  # ===========================================================================
  # com.microsoft:receive-by-sequence-number (V261014-08 task 08-2)
  # ===========================================================================

  describe "com.microsoft:receive-by-sequence-number (real collaborators)" do
    setup do
      if GenServer.whereis(Smalt.Store) == nil do
        start_supervised!(Smalt.Store)
      end

      for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks] do
        if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
      end

      :ok
    end

    defp deferred_message(queue) do
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "defer-body")
      assert {:ok, %{seq: seq}, _lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      assert :ok = Smalt.Amqp.QueueStore.defer(queue, seq)
      seq
    end

    test "200 re-locks a deferred message and it completes like a live delivery" do
      queue = "rbsn-#{System.unique_integer([:positive])}"
      seq = deferred_message(queue)

      resp =
        ManagementRpc.handle(
          %{operation: "com.microsoft:receive-by-sequence-number", body: %{"queue" => queue, "sequence-numbers" => [seq]}},
          %{now: @now}
        )

      assert %{status_code: 200, body: %{"messages" => [envelope]}} = resp
      assert envelope["sequence-number"] == seq
      assert envelope["message"] == "defer-body"

      # re-locked: a second receive-by-seq for the same seq is no longer deferred
      resp2 =
        ManagementRpc.handle(
          %{operation: "com.microsoft:receive-by-sequence-number", body: %{"queue" => queue, "sequence-numbers" => [seq]}},
          %{now: @now}
        )

      assert resp2.status_code == 410
      assert resp2.status_description == "MESSAGE_NOT_DEFERRED"

      # and it settles like a live delivery
      assert :ok = Smalt.Amqp.QueueStore.complete(queue, seq)
      assert :error = Smalt.Store.get(:smalt_sb_messages, {queue, seq})
    end

    test "410 MESSAGE_NOT_DEFERRED batch-atomic when one sequence is not deferred" do
      queue = "rbsn-#{System.unique_integer([:positive])}"
      seq1 = deferred_message(queue)
      seq2 = deferred_message(queue)
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "live")

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:receive-by-sequence-number",
            body: %{"queue" => queue, "sequence-numbers" => [seq1, seq2, seq2 + 1]}
          },
          %{now: @now}
        )

      assert %{status_code: 410, status_description: "MESSAGE_NOT_DEFERRED"} = resp

      # atomic: neither deferred message was locked by the failed batch
      assert {:ok, %{state: :deferred}} = Smalt.Store.get(:smalt_sb_messages, {queue, seq1})
      assert {:ok, %{state: :deferred}} = Smalt.Store.get(:smalt_sb_messages, {queue, seq2})
    end

    test "400 SEQUENCE_NUMBERS_REQUIRED on blank or malformed sequence list" do
      queue = "rbsn-#{System.unique_integer([:positive])}"

      for body <- [%{"queue" => queue, "sequence-numbers" => []}, %{"queue" => queue, "sequence-numbers" => ["x"]}] do
        resp = ManagementRpc.handle(%{operation: "com.microsoft:receive-by-sequence-number", body: body}, %{now: @now})
        assert %{status_code: 400, status_description: "SEQUENCE_NUMBERS_REQUIRED"} = resp
      end
    end

    test "accepts symbol operation form and AMQP array-of-long body" do
      queue = "rbsn-#{System.unique_integer([:positive])}"
      seq = deferred_message(queue)

      resp =
        ManagementRpc.handle(
          %{
            operation: {:symbol, "com.microsoft:receive-by-sequence-number"},
            body: %{"queue" => queue, "sequence-numbers" => {:array, [seq]}}
          },
          %{now: @now}
        )

      assert resp.status_code == 200
    end
  end

  # ===========================================================================
  # update-disposition "suspended" with dead-letter-properties (V261014-08 08-3)
  # ===========================================================================

  describe "suspended disposition with dead-letter-properties (real collaborators)" do
    setup do
      if GenServer.whereis(Smalt.Store) == nil do
        start_supervised!(Smalt.Store)
      end

      for table <- [:smalt_sb_queues, :smalt_sb_messages, :smalt_sb_locks] do
        if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
      end

      :ok
    end

    test "custom dead-letter-properties surface on DLQ application properties" do
      queue = "dlqp-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "dlq-body")
      assert {:ok, %{seq: seq}, lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      raw = Smalt.Amqp.LockManager.token_to_raw(lock.lock_token)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{
              "lock-tokens" => [{:uuid, raw}],
              "disposition-status" => "suspended",
              "deadletter-reason" => "COURT_REJECTED",
              "deadletter-description" => "local-test",
              "dead-letter-properties" => %{"CourtId" => "c-42", "RetryCount" => 3}
            },
            queue: queue
          },
          %{now: @now}
        )

      assert resp.status_code == 200

      assert {:ok, dlq_msg} = Smalt.Store.get(:smalt_sb_messages, {Smalt.Amqp.QueueStore.deadletter_queue(queue), 1})
      assert dlq_msg.app_props["DeadLetterReason"] == "COURT_REJECTED"
      assert dlq_msg.app_props["DeadLetterErrorDescription"] == "local-test"
      assert dlq_msg.app_props["CourtId"] == "c-42"
      assert dlq_msg.app_props["RetryCount"] == 3
    end

    test "absent dead-letter-properties keeps previous behavior" do
      queue = "dlqp-#{System.unique_integer([:positive])}"
      assert {:ok, _} = Smalt.Amqp.QueueStore.enqueue(queue, "dlq-body")
      assert {:ok, %{seq: seq}, lock} = Smalt.Amqp.QueueStore.dequeue_matching(queue)
      raw = Smalt.Amqp.LockManager.token_to_raw(lock.lock_token)

      resp =
        ManagementRpc.handle(
          %{
            operation: "com.microsoft:update-disposition",
            body: %{
              "lock-tokens" => [{:uuid, raw}],
              "disposition-status" => "suspended",
              "deadletter-reason" => "R"
            },
            queue: queue
          },
          %{now: @now}
        )

      assert resp.status_code == 200

      assert {:ok, dlq_msg} = Smalt.Store.get(:smalt_sb_messages, {Smalt.Amqp.QueueStore.deadletter_queue(queue), 1})
      assert dlq_msg.app_props["DeadLetterReason"] == "R"
      assert dlq_msg.app_props["CourtId"] == nil
    end
  end
end
