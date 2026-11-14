defmodule Smalt.Gcp.PubSubEngineTest do
  # GS2 Chicago court: real PubSub GenServer over the real QueueStorage
  # substrate. No mocks, no sleeps: ack-deadline expiry is driven through the
  # "now_ms" clock input and asserted on observable pull results.
  use ExUnit.Case, async: false

  alias Smalt.Gcp.PubSub

  @p "projects/gs2-proj"

  setup do
    :ok = PubSub.reset()
    on_exit(fn -> PubSub.reset() end)
    {:ok, base: System.os_time(:millisecond) + 1_000}
  end

  defp b64(s), do: Base.encode64(s)
  defp topic(id), do: "#{@p}/topics/#{id}"
  defp sub(id), do: "#{@p}/subscriptions/#{id}"

  defp setup_pair(t, s, extra \\ %{}) do
    {:ok, _} = PubSub.create_topic(topic(t))
    {:ok, _} = PubSub.create_subscription(sub(s), Map.merge(%{"topic" => topic(t)}, extra))
  end

  defp pull_all(s, n, now) do
    {:ok, %{"receivedMessages" => r}} = PubSub.pull(sub(s), %{"maxMessages" => n}, %{"now_ms" => now})
    r
  end

  defp datas(recs), do: Enum.map(recs, &(&1["message"]["data"] |> Base.decode64!()))

  test "publish/pull/ack removes the message; unknown topic is typed 404" do
    setup_pair("t-basic", "s-basic")
    {:ok, %{"messageIds" => [_, _]}} = PubSub.publish(topic("t-basic"), [%{"data" => b64("a")}, %{"data" => b64("b")}])
    t = System.os_time(:millisecond) + 1_000
    recs = pull_all("s-basic", 10, t)
    assert datas(recs) == ["a", "b"]
    assert {:ok, _} = PubSub.acknowledge(sub("s-basic"), Enum.map(recs, & &1["ackId"]), %{"now_ms" => t})
    assert pull_all("s-basic", 10, t + 60_000) == []
    assert {:error, 404, "NOT_FOUND", _} = PubSub.publish(topic("nope-topic"), [%{"data" => b64("x")}])
  end

  test "unacked message redelivers after the ack deadline; modifyAckDeadline extends the lease" do
    setup_pair("t-dl", "s-dl")
    {:ok, _} = PubSub.publish(topic("t-dl"), [%{"data" => b64("m")}])
    t = System.os_time(:millisecond) + 1_000
    [r] = pull_all("s-dl", 1, t)
    assert pull_all("s-dl", 1, t + 5_000) == []
    assert {:ok, _} = PubSub.modify_ack_deadline(sub("s-dl"), [r["ackId"]], 100, %{"now_ms" => t + 5_000})
    assert pull_all("s-dl", 1, t + 50_000) == []
    assert [r2] = pull_all("s-dl", 1, t + 120_000)
    assert r2["message"]["messageId"] == r["message"]["messageId"]
    assert r2["ackId"] != r["ackId"]
  end

  test "modifyAckDeadline 0 is a nack: immediate redelivery" do
    setup_pair("t-nack", "s-nack")
    {:ok, _} = PubSub.publish(topic("t-nack"), [%{"data" => b64("m")}])
    t = System.os_time(:millisecond) + 1_000
    [r] = pull_all("s-nack", 1, t)
    {:ok, _} = PubSub.modify_ack_deadline(sub("s-nack"), [r["ackId"]], 0, %{"now_ms" => t})
    assert [_] = pull_all("s-nack", 1, t + 1)
  end

  test "ordering keys: one in-flight per key, FIFO within key, other keys unblocked" do
    setup_pair("t-ord", "s-ord", %{"enableMessageOrdering" => true})

    {:ok, _} =
      PubSub.publish(topic("t-ord"), [
        %{"data" => b64("k1-1"), "orderingKey" => "k1"},
        %{"data" => b64("k1-2"), "orderingKey" => "k1"},
        %{"data" => b64("k2-1"), "orderingKey" => "k2"}
      ])

    t = System.os_time(:millisecond) + 1_000
    first = pull_all("s-ord", 10, t)
    assert datas(first) == ["k1-1", "k2-1"]
    ids = for r <- first, r["message"]["orderingKey"] == "k1", do: r["ackId"]
    assert pull_all("s-ord", 10, t + 1) == []
    {:ok, _} = PubSub.acknowledge(sub("s-ord"), ids, %{"now_ms" => t + 2})
    assert datas(pull_all("s-ord", 10, t + 3)) == ["k1-2"]
  end

  test "dead-letter: forwarded to the DLT subscription after maxDeliveryAttempts" do
    {:ok, _} = PubSub.create_topic(topic("t-dead"))
    {:ok, _} = PubSub.create_subscription(sub("s-dead-sink"), %{"topic" => topic("t-dead")})
    setup_pair("t-src", "s-src", %{"deadLetterPolicy" => %{"deadLetterTopic" => topic("t-dead"), "maxDeliveryAttempts" => 5}})
    {:ok, _} = PubSub.publish(topic("t-src"), [%{"data" => b64("poison"), "attributes" => %{"k" => "v"}}])
    t = System.os_time(:millisecond) + 1_000

    attempts =
      for i <- 0..4 do
        [r] = pull_all("s-src", 1, t + i * 20_000)
        r["deliveryAttempt"]
      end

    assert attempts == [1, 2, 3, 4, 5]
    assert pull_all("s-src", 1, t + 200_000) == []
    assert [d] = pull_all("s-dead-sink", 1, t + 200_000)
    assert d["message"]["data"] == b64("poison")
    assert d["message"]["attributes"]["CloudPubSubDeadLetterSourceSubscription"] == sub("s-src")
  end

  test "snapshot + seek replays acked messages; seek to time replays by publish time" do
    setup_pair("t-snap", "s-snap")
    {:ok, _} = PubSub.publish(topic("t-snap"), [%{"data" => b64("one")}, %{"data" => b64("two")}])
    {:ok, snap} = PubSub.create_snapshot("#{@p}/snapshots/snap1", %{"subscription" => sub("s-snap")})
    assert snap["topic"] == topic("t-snap")
    t = System.os_time(:millisecond) + 1_000
    recs = pull_all("s-snap", 10, t)
    {:ok, _} = PubSub.acknowledge(sub("s-snap"), Enum.map(recs, & &1["ackId"]), %{"now_ms" => t})
    assert pull_all("s-snap", 10, t + 1) == []
    {:ok, _} = PubSub.seek(sub("s-snap"), %{"snapshot" => "#{@p}/snapshots/snap1"})
    assert datas(pull_all("s-snap", 10, t + 2)) == ["one", "two"]
    assert {:ok, %{"snapshots" => [_]}} = PubSub.list_snapshots("gs2-proj")
    assert {:ok, _} = PubSub.delete_snapshot("#{@p}/snapshots/snap1")
    assert {:error, 404, "NOT_FOUND", _} = PubSub.get_snapshot("#{@p}/snapshots/snap1")

    {:ok, _} = PubSub.seek(sub("s-snap"), %{"time" => "1970-01-01T00:00:00Z"})
    assert datas(pull_all("s-snap", 10, t + 3)) == ["one", "two"]
  end

  test "fan-out to every subscription; boundary refusals are typed" do
    {:ok, _} = PubSub.create_topic(topic("t-fan"))
    {:ok, _} = PubSub.create_subscription(sub("s-fan1"), %{"topic" => topic("t-fan")})
    {:ok, _} = PubSub.create_subscription(sub("s-fan2"), %{"topic" => topic("t-fan")})
    {:ok, _} = PubSub.publish(topic("t-fan"), [%{"data" => b64("x")}])
    t = System.os_time(:millisecond) + 1_000
    assert datas(pull_all("s-fan1", 5, t)) == ["x"]
    assert datas(pull_all("s-fan2", 5, t)) == ["x"]
    assert {:error, 409, "ALREADY_EXISTS", _} = PubSub.create_topic(topic("t-fan"))
    assert {:error, 400, "INVALID_ARGUMENT", _} = PubSub.publish(topic("t-fan"), [%{"data" => "!!notb64"}])
    assert {:error, 400, "INVALID_ARGUMENT", _} = PubSub.create_topic("bad")
    assert {:error, 404, "NOT_FOUND", _} = PubSub.create_subscription(sub("s-orphan"), %{"topic" => topic("absent")})
    assert {:ok, _} = PubSub.delete_subscription(sub("s-fan1"))
    assert {:error, 404, "NOT_FOUND", _} = PubSub.get_subscription(sub("s-fan1"))
  end
end
