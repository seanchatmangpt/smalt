defmodule Smalt.PubSubGrpc.EngineTest do
  @moduledoc "K-GC engine courts: registry CRUD, delivery/ack, durable cursor."
  use ExUnit.Case, async: false

  alias Smalt.PubSubGrpc.Engine

  setup do
    dir = Path.join("tmp/pubsub_test", Integer.to_string(System.unique_integer([:positive])))
    Application.put_env(:smalt, :pubsub_registry_dir, dir)

    case Process.whereis(Engine) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    {:ok, _} = Engine.start_link([])
    :ok
  end

  test "topic registry CRUD with typed refusals" do
    assert {:ok, %{name: "projects/p/topics/t1"}} = Engine.create_topic("projects/p/topics/t1")
    assert {:grpc_error, 6, _} = Engine.create_topic("projects/p/topics/t1")
    assert {:ok, _} = Engine.get_topic("projects/p/topics/t1")
    assert {:grpc_error, 5, _} = Engine.get_topic("projects/p/topics/none")
    assert {:grpc_error, 5, _} = Engine.get_subscription("projects/p/subscriptions/none")
  end

  test "publish assigns unique server message_ids and publish_time" do
    assert {:ok, _} = Engine.create_topic("projects/p/topics/t2")
    assert {:ok, _} = Engine.ensure_subscription("s2", "projects/p/topics/t2")

    assert {:ok, ids} = Engine.publish("projects/p/topics/t2", [%{data: "a"}, %{data: "b"}])
    assert length(ids) == 2
    assert length(Enum.uniq(ids)) == 2
  end

  test "pull/ack/redelivery/durable cursor" do
    assert {:ok, _} = Engine.create_topic("projects/p/topics/t3")
    assert {:ok, _} = Engine.ensure_subscription("s3", "projects/p/topics/t3")
    assert {:ok, _} = Engine.publish("projects/p/topics/t3", [%{data: "m1"}, %{data: "m2"}])

    {:ok, received} = Engine.pull("s3", 10, true)
    assert length(received) == 2

    # unacked => redelivered: pull 1 without acking, pull again sees it
    assert {:ok, [_only]} = Engine.pull("s3", 1, true)
    assert {:ok, again} = Engine.pull("s3", 1, true)
    assert length(again) == 1

    ack_ids = Enum.map(received, & &1.ack_id)
    :ok = Engine.acknowledge("s3", ack_ids)

    {:ok, after_ack} = Engine.pull("s3", 10, true)
    assert after_ack == []

    # unacked => redelivered: fresh subscription sees the same frames again
    assert {:ok, _} = Engine.ensure_subscription("s4", "projects/p/topics/t3")
    {:ok, redelivered} = Engine.pull("s4", 10, true)
    assert length(redelivered) == 2
  end

  test "durable cursor survives Engine restart (F-P3)" do
    assert {:ok, _} = Engine.create_topic("projects/p/topics/t5")
    assert {:ok, _} = Engine.ensure_subscription("s5", "projects/p/topics/t5")
    assert {:ok, _} = Engine.publish("projects/p/topics/t5", [%{data: "x"}, %{data: "y"}])

    {:ok, received} = Engine.pull("s5", 10, true)
    assert length(received) == 2
    [first | rest] = received
    :ok = Engine.acknowledge("s5", [first.ack_id])

    # restart the engine; CursorPersist folds the durable tail back
    :ok = GenServer.stop(Engine, :normal)
    {:ok, _} = Engine.start_link([])

    assert {:ok, %{name: "s5", topic: "projects/p/topics/t5"}} =
             Engine.get_subscription("s5")

    {:ok, after_restart} = Engine.pull("s5", 10, true)
    assert length(after_restart) == 1
  end
end
