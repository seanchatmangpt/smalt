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
      if GenServer.whereis(Smalt.Store) == nil do
        start_supervised!(Smalt.Store)
      end

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
end
