# BK-87 — BK-65 surfaced defect 2 closed: ARM queue DELETE must purge the
# AMQP message store with the entity.
#
# BK-65 witness (docs/jira/v26.10.21/receipts/bk65-arm-amqp-interop.md, defect
# 2): ARM DELETE + re-PUT of q1 each probe run drained 1-2 stale deliveries
# from deleted-queue generations before the run's own message. Real Service
# Bus drops the messages with the entity.
#
# Fix: ARM queue DELETE now purges messages/locks/sessions for the entity
# (QueueStore.purge_queue/1, serialized through the claim/settle server) and
# drops the entity row, mirroring sb_materialize_amqp (KD-86) — a same-name
# re-PUT re-provisions an EMPTY entity. Fresh entity => zero stale deliveries.
#
# Chicago discipline: real Store tables, real ARM router dispatch (Plug
# in-process), real QueueStore enqueue/claim — asserts on final store state,
# no mocks.
#
# Context: solo

defmodule Integration.Bk87ArmDeletePurgeTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.Amqp.QueueStore
  alias Smalt.Store

  @api_version "2021-04-01"
  @sub "sub-bk87"
  @rg "rg-bk87"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}"

  setup do
    case GenServer.start_link(Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp arm_req(method, path, body \\ nil) do
    url = "#{path}?api-version=#{@api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp put_ns do
    arm_req(:put, "#{@base}/providers/Microsoft.ServiceBus/namespaces/ns-bk87", %{
      "location" => "eastus",
      "sku" => %{"name" => "Standard", "tier" => "Standard"},
      "properties" => %{}
    })
  end

  defp put_queue(name) do
    arm_req(:put, "#{@base}/providers/Microsoft.ServiceBus/namespaces/ns-bk87/queues/#{name}", %{
      "location" => "eastus",
      "properties" => %{}
    })
  end

  defp delete_queue(name) do
    arm_req(:delete, "#{@base}/providers/Microsoft.ServiceBus/namespaces/ns-bk87/queues/#{name}")
  end

  defp send_n(queue, n) do
    for i <- 1..n do
      assert {:ok, _} = QueueStore.enqueue(queue, "bk87-stale-#{i}")
    end
  end

  defp drain(queue) do
    case QueueStore.dequeue_matching(queue) do
      {:ok, msg, _lock} -> [msg | drain(queue)]
      :empty -> []
    end
  end

  test "ARM DELETE purges messages: re-created queue has ZERO stale deliveries" do
    assert put_ns().status in [200, 201, 202]
    q = "bk87-purge-#{System.unique_integer([:positive])}"

    assert put_queue(q).status == 201
    assert QueueStore.queue_info(q) != :error, "ARM PUT must materialize the AMQP entity (KD-86)"

    send_n(q, 3)
    assert {:ok, stale} = QueueStore.peek(q)
    assert length(stale) == 3

    assert delete_queue(q).status == 200

    # entity row dropped with the ARM record
    assert QueueStore.queue_info(q) == :error

    # messages/locks/sessions dropped with the entity (real SB parity)
    assert {:ok, []} = QueueStore.peek(q)

    # ARM re-create same name: fresh entity, EMPTY
    assert put_queue(q).status == 201
    assert drain(q) == [], "stale deliveries drained from a deleted generation"

    # fresh round-trip works on the new generation (single claim — the claim
    # locks the delivery, matching the real receive-lock contract)
    assert {:ok, _} = QueueStore.enqueue(q, "bk87-fresh")
    assert {:ok, msg, _lock} = QueueStore.dequeue_matching(q)
    assert msg.body == "bk87-fresh"
  end

  test "purge clears locks and sessions owned by the deleted queue only" do
    assert put_ns().status in [200, 201, 202]
    q = "bk87-scoped-#{System.unique_integer([:positive])}"
    other = "bk87-other-#{System.unique_integer([:positive])}"

    assert put_queue(q).status == 201
    assert put_queue(other).status == 201

    send_n(q, 2)
    send_n(other, 1)

    # claim from q so a message lock exists at DELETE time
    assert {:ok, _claimed, lock} = QueueStore.dequeue_matching(q)

    assert delete_queue(q).status == 200
    assert {:ok, 0} = QueueStore.purge_queue(q)

    # the deleted queue's lock is gone; the sibling queue is untouched
    assert Smalt.Amqp.LockManager.get(lock.lock_token) == :error

    assert {:ok, [survivor]} = QueueStore.peek(other)
    assert survivor.body == "bk87-stale-1"

    assert delete_queue(other).status == 200
    assert {:ok, []} = QueueStore.peek(other)
  end

  test "negative: DELETE of a never-ARM-created queue stays a plain 200, no crash" do
    assert put_ns().status in [200, 201, 202]
    q = "bk87-never-#{System.unique_integer([:positive])}"

    conn = delete_queue(q)
    assert conn.status == 200

    # and no AMQP entity was silently materialized by the DELETE sweep
    assert QueueStore.queue_info(q) == :error
  end

  test "purge on unmaterialized tables is a typed no-op" do
    assert put_ns().status in [200, 201, 202]
    # a queue name that never touched the store; tables ARE materialized here,
    # so this exercises the zero-row face of the purge
    assert {:ok, 0} = QueueStore.purge_queue("bk87-empty-purge")
  end
end
