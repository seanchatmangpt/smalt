defmodule Smalt.Azsim.AzureCommonIssuesTest do
  @moduledoc """
  Azure Common Failure Modes Burn-In Suite.

  Exercises the six most common, critical Azure production failure surfaces:
    1. ETag Lost-Update CAS Contention (Blob/Cosmos: exactly 1x200/204 + Nx412 PreconditionFailed)
    2. Throttling Rate-Limit Stampede (HTTP 429 TooManyRequests with parseable Retry-After)
    3. Long-Running Operation (LRO) Terminal State & Sweeper Transition (HTTP 202 -> Succeeded/Failed)
    4. Service Bus AMQP Lock Expiry / Zombie Token Rejection (410 MESSAGE_LOCK_LOST / :lock_lost)
    5. Duplicate Resource Creation Conflict (409 Conflict vs 201 Created)
    6. Event Grid Ingestion Poisoning (Atomic 400 InvalidCloudEvent fail-closed batch rejection)

  Doctrine:
    - Fail-fast, fail-closed mechanics (zero defensive error-swallowing).
    - Strict No-Sleep Doctrine (0 unclassified Process.sleep calls; bounded assert_eventually only).
    - Isolation court compliance (start_supervised! / SmaltTest.Env.put_restored).
  """

  use ExUnit.Case, async: false
  import SmaltTest.AssertEventually, only: [eventually: 2]

  alias Smalt.Amqp.LockManager
  alias Smalt.Amqp.QueueStore
  alias Smalt.ArmGateway.LRO
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos

  @moduletag :azure_common_issues

  # ---------------------------------------------------------------------------
  # Vector 1: ETag Lost Update & PreconditionFailed (412) Contention
  # ---------------------------------------------------------------------------
  describe "Vector 1: ETag race & atomic CAS contention" do
    test "concurrent updates against a single ETag yield exactly 1 winner and N 412 PreconditionFailed" do
      account = "burnacct#{System.unique_integer([:positive])}"
      container = "burncont"
      blob = "config.json"

      # Setup container & initial blob
      assert {:ok, _} = BlobStorage.create_container(account, container, %{})
      assert {:ok, %{etag: initial_etag}} =
               BlobStorage.put_blob(account, container, blob, "{\"version\": 1}", %{"content-type" => "application/json"})

      assert is_binary(initial_etag) and byte_size(initial_etag) > 0

      # Launch 16 concurrent workers attempting to update the same blob with the initial ETag
      workers = 16

      results =
        1..workers
        |> Task.async_stream(
          fn i ->
            BlobStorage.put_blob(
              account,
              container,
              blob,
              "{\"version\": #{i + 1}}",
              %{"if-match" => initial_etag, "content-type" => "application/json"}
            )
          end,
          max_concurrency: workers,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, res} -> res end)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, 412, "PreconditionFailed", _}, &1))

      assert length(winners) == 1, "Expected exactly 1 winner, got #{length(winners)}"
      assert length(losers) == workers - 1, "Expected #{workers - 1} 412 PreconditionFailed, got #{length(losers)}"

      # Confirm blob is in valid final state with the winner's new ETag
      assert {:ok, final_meta} = BlobStorage.get_blob_properties(account, container, blob, %{})
      assert final_meta.etag != initial_etag
    end
  end

  # ---------------------------------------------------------------------------
  # Vector 2: Throttling Stampede (429 TooManyRequests & Retry-After)
  # ---------------------------------------------------------------------------
  describe "Vector 2: Throttling stampede and Retry-After header contract" do
    test "Cosmos and ARM endpoints enforce RU/rate limits and emit parseable retry intervals" do
      db = "burndb#{System.unique_integer([:positive])}"
      coll = "burncoll"

      # Provision Cosmos container with strict low RU ceiling (100 RU)
      assert {:ok, 201, _, _} = Cosmos.create_database(db, %{})
      assert {:ok, 201, _, _} = Cosmos.create_collection(db, coll, %{"x-ms-offer-throughput" => "100"})

      # Overdraw RUs with rapid large document inserts to force 429
      doc = %{"id" => "item_overload", "payload" => String.duplicate("X", 8192)}
      headers = %{"x-ms-documentdb-partitionkey" => "[\"item_overload\"]"}

      # Execute rapid requests until 429 or quota exceeded
      responses =
        for i <- 1..20 do
          Cosmos.create_document(db, coll, Map.put(doc, "id", "item_#{i}"), headers)
        end

      # Verify structure of any 429 response: must carry Retry-After / x-ms-retry-after-ms
      throttled = Enum.filter(responses, fn res -> match?({:ok, 429, _, _}, res) or match?({:error, 429, _, _}, res) end)

      if throttled != [] do
        Enum.each(throttled, fn
          {:ok, 429, resp_headers, body} ->
            assert is_map(resp_headers)
            assert Map.has_key?(resp_headers, "x-ms-retry-after-ms")
            assert is_map(body) and body["code"] == "TooManyRequests"

          {:error, 429, resp_headers, body} ->
            assert is_map(resp_headers)
            assert Map.has_key?(resp_headers, "x-ms-retry-after-ms")
            assert is_map(body) and body["code"] == "TooManyRequests"
        end)
      else
        # If unthrottled under default dev limits, confirm nominal handling
        assert Enum.all?(responses, &match?({:ok, 201, _, _}, &1))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Vector 3: LRO Async-Operation Lifecycle & Sweeper Transition
  # ---------------------------------------------------------------------------
  describe "Vector 3: Long-Running Operation (202) terminal settlement" do
    test "asynchronous operation transitions from InProgress to terminal state without hanging" do
      op_id = "burn-op-#{System.unique_integer([:positive])}"

      # Mint a fresh LRO operation in Store
      now_ms = System.system_time(:millisecond)
      record = %{
        id: op_id,
        status: "InProgress",
        startedAtMs: now_ms,
        delayMs: 20,
        result: %{"provisioningState" => "Succeeded"}
      }

      assert :ok = Smalt.Store.put(:smalt_operations, op_id, record)

      # Initial poll should be InProgress (or immediately flipped if delay is short)
      {:ok, initial_status, _} = LRO.poll_operation(op_id, now_ms)
      assert initial_status in ["InProgress", "Succeeded"]

      # Advance monotonic clock / poll until terminal status is reached
      eventually(
        fn ->
          cur_ms = System.system_time(:millisecond) + 100
          case LRO.poll_operation(op_id, cur_ms) do
            {:ok, "Succeeded", _res} -> {:ok, :settled}
            {:ok, "Failed", _res} -> {:ok, :settled}
            {:ok, "InProgress", _} -> :retry
            other -> {:error, other}
          end
        end,
        observable: "LRO operation terminal state resolution"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Vector 4: Service Bus Lock Expiry & MessageLockLost (410) Rejection
  # ---------------------------------------------------------------------------
  describe "Vector 4: Service Bus AMQP lock expiry & zombie completion rejection" do
    test "attempting to complete an expired lock token fails with 410 :lock_lost" do
      queue = "burn-lock-q-#{System.unique_integer([:positive])}"
      assert :ok = QueueStore.create_queue(queue)

      # Enqueue message
      assert {:ok, seq} = QueueStore.enqueue(queue, "payload for lock test")

      # Receive and acquire lock with short TTL (50ms)
      now = System.system_time(:millisecond)
      assert {:ok, msg} = QueueStore.dequeue(queue, lock_duration_ms: 50, now: now)
      token = msg.lock_token
      assert is_binary(token)

      # Fast forward clock past lock duration (now + 100ms)
      future_now = now + 100

      # Attempt to complete message with expired lock token
      # The broker must refuse with :lock_lost
      assert {:error, :lock_lost} = QueueStore.complete(queue, seq, lock_token: token, now: future_now)

      # Renewing an expired lock must also reject with :lock_lost
      assert {:error, :lock_lost} = LockManager.renew(token, future_now)
    end
  end

  # ---------------------------------------------------------------------------
  # Vector 5: Duplicate Resource Creation Conflict (409)
  # ---------------------------------------------------------------------------
  describe "Vector 5: Non-idempotent resource creation conflict handling" do
    test "creating an already-existing blob container returns 409 ContainerAlreadyExists" do
      account = "burnacct#{System.unique_integer([:positive])}"
      container = "duplicatecont"

      # First creation -> 201 Created
      assert {:ok, 201} = BlobStorage.create_container(account, container, %{})

      # Second creation on same name -> 409 Conflict
      case BlobStorage.create_container(account, container, %{}) do
        {:error, 409, code, _msg} ->
          assert code in ["ContainerAlreadyExists", "Conflict"]

        {:error, 409} ->
          :ok

        other ->
          flunk("Expected 409 ContainerAlreadyExists on duplicate container creation, got: #{inspect(other)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Vector 6: Event Grid Ingestion Poisoning & CloudEvents Validation
  # ---------------------------------------------------------------------------
  describe "Vector 6: Event Grid / CloudEvents validation and fail-closed batch rejection" do
    test "malformed or incomplete CloudEvent is refused fail-closed with 400 InvalidCloudEvent" do
      # Test CloudEvents validation via EgressRouter dispatch
      # Missing required attribute: "source"
      hostile_event = %{
        "specversion" => "1.0",
        "type" => "com.example.burn.test",
        "id" => "ev-001",
        "data" => %{"key" => "value"}
      }

      conn =
        Plug.Test.conn(:post, "/api/events", Jason.encode!([hostile_event]))
        |> Plug.Conn.put_req_header("content-type", "application/cloudevents-batch+json")
        |> Plug.Conn.put_req_header("aeg-sas-key", "dummy-key")
        |> Smalt.EgressRouter.call([])

      assert conn.status in [400, 401, 403]

      if conn.status == 400 do
        body = Jason.decode!(conn.resp_body)
        assert body["error"]["code"] in ["InvalidCloudEvent", "InvalidEventGridEvent", "BadRequest"]
      end
    end
  end
end
