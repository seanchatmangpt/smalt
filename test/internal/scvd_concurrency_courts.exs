# SCVD-T7 concurrency courts (writer lane, v26.10.20 wave).
#
# Chicago discipline: real concurrent tasks against the real in-process
# data-plane faces (Cosmos/BlobStorage ETS + QueueStore GenServer). No mocks,
# no sleeps — concurrency is Task.async_stream with a hard timeout so a hang
# surfaces as a typed exit instead of a stuck suite. The ramp claims under
# court:
#   (a) 64 concurrent Cosmos doc create+read on unique ids
#   (b) 32 concurrent blob PUT/GET byte-equal
#   (c) 32 concurrent SB send/receive round-trips with per-message receipts
#   (d) typed refusal court: concurrent oversized/invalid payloads
defmodule Smalt.Test.Internal.ScvdConcurrencyCourtsTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.QueueStore
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.PartitionKey

  @pk_hdr %{PartitionKey.header_name() => "[1]"}

  setup do
    # Real store, real named tables. If the app already booted them this is a
    # no-op ({:error, {:already_started, _}}).
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    QueueStore.server()

    :ok
  end

  defp up(field), do: fn _acc, res -> {field, res} end

  # -- (a) 64 concurrent Cosmos doc create+read ---------------------------------

  @tag :scvd
  test "(a) 64 concurrent cosmos doc create+read, all 200/201, ids unique" do
    db = "scvd-a-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "scvd-a"

    {:ok, 201, _, _} = Cosmos.create_db(db)

    {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    results =
      1..64
      |> Task.async_stream(
        fn i ->
          id = "doc-#{i}-#{System.unique_integer([:positive])}"

          case Cosmos.create_doc(db, coll, %{"id" => id, "pk" => 1, "v" => i}, @pk_hdr) do
            {:ok, 201, _, created} ->
              case Cosmos.get_doc(db, coll, id, @pk_hdr) do
                {:ok, 200, _, read} ->
                  {:ok, created["id"], read["id"], read["v"]}

                other ->
                  {:read_fail, id, other}
              end

            other ->
              {:create_fail, id, other}
          end
        end,
        max_concurrency: 64,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert length(results) == 64

    Enum.each(results, fn res ->
      assert {:ok, id, id, v} = res
      assert is_integer(v)
    end)

    ids = Enum.map(results, fn {:ok, id, _, _} -> id end)
    assert length(Enum.uniq(ids)) == 64

    Cosmos.drop_container(db, coll)
    Cosmos.drop_db(db)
  end

  # -- (b) 32 concurrent blob PUT/GET byte-equal --------------------------------

  @tag :scvd
  test "(b) 32 concurrent blob PUT/GET byte-equal" do
    account = "scvd-b"
    container = "scvd-b"

    assert {:ok, _} = BlobStorage.create_container(account, container)

    payload_base = :crypto.strong_rand_bytes(64 * 1024)

    results =
      1..32
      |> Task.async_stream(
        fn i ->
          name = "blob-#{i}-#{System.unique_integer([:positive])}"
          content = payload_base <> <<i::64>> <> :crypto.strong_rand_bytes(1024)

          case BlobStorage.put_blob(account, container, name, content) do
            {:ok, put_blob} ->
              case BlobStorage.get_blob(account, container, name) do
                {:ok, got} ->
                  if got["content"] == content,
                    do: {:ok, name},
                    else: {:byte_mismatch, name}

                other ->
                  {:get_fail, name, other}
              end

            other ->
              {:put_fail, name, other}
          end
        end,
        max_concurrency: 32,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    assert length(results) == 32

    Enum.each(results, fn res ->
      assert {:ok, _name} = res
    end)

    assert length(Enum.uniq(Enum.map(results, fn {:ok, n} -> n end))) == 32

    BlobStorage.delete_container(account, container)
  end

  # -- (c) 32 concurrent SB send/receive round-trips ----------------------------

  @tag :scvd
  test "(c) 32 concurrent SB send/receive round-trips with per-message receipts" do
    queue = "scvd-c-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, _} = QueueStore.ensure_queue(queue)

    bodies =
      for i <- 1..32, do: "scvd-msg-#{i}-#{System.unique_integer([:positive])}"

    results =
      bodies
      |> Task.async_stream(
        fn body ->
          with {:ok, _seq_or_fanout} <- QueueStore.enqueue(queue, body),
               {:ok, msg, lock} <- QueueStore.dequeue_matching(queue),
               :ok <- QueueStore.complete(queue, msg.seq, lock_token: lock.lock_token) do
            {:ok, body, msg.body}
          else
            other -> {:fail, body, other}
          end
        end,
        max_concurrency: 32,
        timeout: 15_000
      )
    |> Enum.map(fn {:ok, res} -> res end)

    assert length(results) == 32

    # Under concurrent claim a task may settle another task's message — the
    # invariants are: every task completed a full send->claim->settle round
    # trip, every received body is exactly one of the sent bodies, no body
    # delivered twice, and the queue drained to empty.
    Enum.each(results, fn res ->
      assert {:ok, _sent_by_task, received} = res
      assert is_binary(received)
    end)

    sent_set = MapSet.new(bodies)
    received = Enum.map(results, fn {:ok, _s, r} -> r end)
    got_set = MapSet.new(received)
    assert MapSet.equal?(sent_set, got_set)
    assert length(received) == length(Enum.uniq(received))

    # Queue fully drained after settlement.
    assert {:ok, []} = QueueStore.peek(queue)
  end

  # -- (d) typed refusal court ---------------------------------------------------

  @tag :scvd
  test "(d) concurrent oversized/invalid payloads answer typed refusals, no hangs" do
    db = "scvd-d-" <> Integer.to_string(System.unique_integer([:positive]))
    coll = "scvd-d"

    {:ok, 201, _, _} = Cosmos.create_db(db)

    {:ok, 201, _, _} =
             Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})

    assert {:ok, _} = BlobStorage.create_container("scvd-d", "scvd-d")
    assert {:ok, _} = QueueStore.ensure_queue("scvd-d-q")

    big_doc_body = %{
      "id" => "toobig",
      "pk" => 1,
      "pad" => String.duplicate("x", 2 * 1024 * 1024 + 1)
    }

    big_blob = String.duplicate("y", 1_048_577)

    refusals =
      1..24
      |> Task.async_stream(
        fn i ->
          case rem(i, 4) do
            0 ->
              # Cosmos oversized doc body -> typed 413 RequestEntityTooLarge
              case Cosmos.create_doc(db, coll, big_doc_body, @pk_hdr) do
                {:ok, 413, _, %{"code" => "RequestEntityTooLarge"}} -> :typed
                other -> {:fail, :cosmos_toobig, other}
              end

            1 ->
              # Blob oversized PUT -> typed :too_large
              case BlobStorage.put_blob("scvd-d", "scvd-d", "big-#{i}", big_blob) do
                {:error, :too_large, msg} when is_binary(msg) -> :typed
                other -> {:fail, :blob_toobig, other}
              end

            2 ->
              # Blob invalid name (control char) -> typed 400 InvalidResourceName
              case BlobStorage.put_blob("scvd-d", "scvd-d", "bad\nname-#{i}", "x") do
                {:error, 400, "InvalidResourceName", msg} when is_binary(msg) -> :typed
                other -> {:fail, :blob_badname, other}
              end

            _ ->
              # SB oversized enqueue (body > 4 MiB) -> typed :too_large
              case QueueStore.enqueue("scvd-d-q", String.duplicate("q", 4 * 1024 * 1024 + 1)) do
                {:error, :too_large} -> :typed
                other -> {:fail, :sb_toobig, other}
              end
          end
        end,
        max_concurrency: 24,
        timeout: 15_000
      )
      |> Enum.map(fn
        {:ok, res} -> res
        {:exit, reason} -> {:exit, reason}
      end)

    assert length(refusals) == 24
    assert Enum.all?(refusals, &(&1 == :typed))
    assert {:ok, []} = QueueStore.peek("scvd-d-q")

    Cosmos.drop_container(db, coll)
    Cosmos.drop_db(db)
    BlobStorage.delete_container("scvd-d", "scvd-d")
  end
end
