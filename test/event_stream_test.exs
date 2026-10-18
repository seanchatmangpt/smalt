defmodule Smalt.Messaging.EventStreamTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventStream

  setup do
    # Canonical resilient shared-Store setup (v26.10.18): ensures the Store is
    # up and retries only the dead-table clear race (FLAKE_LEDGER F2-F5/F10).
    SmaltTest.Store.resilient_setup()
    :ok
  end

  defp valid_event(id \\ "evt-1", overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => id,
        "source" => "/smalt/test",
        "type" => "smalt.test.event"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Cross-topic isolation
  # ---------------------------------------------------------------------------

  test "list_events/1 returns only the requested topic's events" do
    {:ok, _} = EventStream.publish("orders", valid_event("a-1"))
    {:ok, _} = EventStream.publish("payments", valid_event("p-1"))

    orders = EventStream.list_events("orders")
    payments = EventStream.list_events("payments")

    assert [%{"id" => "a-1"}] = orders
    assert [%{"id" => "p-1"}] = payments
  end

  test "prefix is topic-scoped, not a raw substring match" do
    {:ok, _} = EventStream.publish("orders", valid_event("x"))
    {:ok, _} = EventStream.publish("orders-extra", valid_event("y"))

    assert [%{"id" => "x"}] = EventStream.list_events("orders")
    assert [%{"id" => "y"}] = EventStream.list_events("orders-extra")
  end

  # ---------------------------------------------------------------------------
  # Generated ids
  # ---------------------------------------------------------------------------

  test "publish/2 generates a UUID id when absent and returns it" do
    {:ok, id} = EventStream.publish("t", Map.delete(valid_event(), "id"))

    assert is_binary(id)
    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert [%{"id" => ^id, "topic" => "t"}] = EventStream.list_events("t")
  end

  test "publish/2 keeps a caller-supplied non-empty id" do
    assert {:ok, "my-id"} = EventStream.publish("t", valid_event("my-id"))
    assert [%{"id" => "my-id"}] = EventStream.list_events("t")
  end

  # ---------------------------------------------------------------------------
  # CloudEvents 1.0 validation matrix
  # ---------------------------------------------------------------------------

  test "rejects missing/invalid specversion" do
    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", valid_event("e", %{"specversion" => "0.3"}))

    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", Map.delete(valid_event(), "specversion"))

    assert EventStream.list_events("t") == []
  end

  test "rejects missing or empty type (matrix)" do
    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", Map.delete(valid_event(), "type"))

    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", valid_event("e", %{"type" => ""}))

    assert EventStream.list_events("t") == []
  end

  test "rejects missing or empty source" do
    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", Map.delete(valid_event(), "source"))

    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", valid_event("e", %{"source" => ""}))

    assert {:error, :invalid_cloudevent} =
             EventStream.publish("t", valid_event("e", %{"source" => 42}))

    assert EventStream.list_events("t") == []
  end

  test "rejects non-map payloads" do
    assert {:error, :invalid_cloudevent} = EventStream.publish("t", "not-a-map")
    assert {:error, :invalid_cloudevent} = EventStream.publish("t", nil)
  end

  # ---------------------------------------------------------------------------
  # publish_many/2
  # ---------------------------------------------------------------------------

  test "publish_many/2 stores all valid events and returns their ids in order" do
    events = [valid_event("m-1"), valid_event("m-2"), valid_event("m-3")]

    assert {:ok, ["m-1", "m-2", "m-3"]} = EventStream.publish_many("bulk", events)

    assert [%{"id" => "m-1"}, %{"id" => "m-2"}, %{"id" => "m-3"}] =
             EventStream.list_events("bulk")
  end

  test "publish_many/2 fails atomically-ish at the first invalid event" do
    events = [valid_event("ok-1"), valid_event("ok-2", %{"type" => ""}), valid_event("ok-3")]

    assert {:error, :invalid_cloudevent} = EventStream.publish_many("bulk", events)
    ids = Enum.map(EventStream.list_events("bulk"), & &1["id"])
    assert ids == ["ok-1"]
  end

  # ---------------------------------------------------------------------------
  # Insertion order
  # ---------------------------------------------------------------------------

  test "list_events/1 returns events in insertion order regardless of id ordering" do
    ids = ["zzz", "aaa", "mmm", "bbb"]

    Enum.each(ids, fn id ->
      {:ok, ^id} = EventStream.publish("ord", valid_event(id))
    end)

    listed = EventStream.list_events("ord")
    assert Enum.map(listed, & &1["id"]) == ids
  end

  # ---------------------------------------------------------------------------
  # Backward-compatible route-handler shape (egress router)
  # ---------------------------------------------------------------------------

  test "publish_events/2 with a list returns :ok and stores events" do
    assert :ok = EventStream.publish_events("rt", [valid_event("r-1"), valid_event("r-2")])
    assert Enum.map(EventStream.list_events("rt"), & &1["id"]) == ["r-1", "r-2"]
  end

  test "publish_events/2 with a single map returns :ok" do
    assert :ok = EventStream.publish_events("rt", valid_event("r-3"))
    assert [%{"id" => "r-3"}] = EventStream.list_events("rt")
  end

  test "publish_events/2 returns error tuple on invalid event" do
    assert {:error, :invalid_cloudevent} =
             EventStream.publish_events("rt", [valid_event("bad", %{"specversion" => "9.9"})])
  end

  # Fail-closed fence: non-list/non-map payloads take the catch-all clause
  # instead of raising FunctionClauseError at the router seam.
  test "publish_events/2 fail-closed on non-list/non-map payload" do
    assert {:error, :invalid_cloudevent} = EventStream.publish_events("rt", "bogus")
    assert {:error, :invalid_cloudevent} = EventStream.publish_events("rt", 42)
    assert {:error, :invalid_cloudevent} = EventStream.publish_events("rt", nil)
  end

  # ---------------------------------------------------------------------------
  # Id dedup (default LWW vs enforced)
  # ---------------------------------------------------------------------------

  test "default: same-id republish overwrites (LWW) and list shows v2" do
    {:ok, "dup-1"} = EventStream.publish("dd", valid_event("dup-1", %{"source" => "/smalt/v1"}))
    {:ok, "dup-1"} = EventStream.publish("dd", valid_event("dup-1", %{"source" => "/smalt/v2"}))

    events = EventStream.list_events("dd")
    assert [%{"id" => "dup-1", "source" => "/smalt/v2"}] = events
  end

  test "enforced: :event_stream_dedup_ids refuses duplicate id and keeps first write" do
    # Canonical Application-env scoping (SmaltTest.Env.with): prev saved, restore
    # in an exception-safe after — put when prev was non-nil, delete when unset.
    SmaltTest.Env.with([event_stream_dedup_ids: true], fn ->
      {:ok, "dup-2"} =
        EventStream.publish("dd2", valid_event("dup-2", %{"source" => "/smalt/v1"}))

      assert {:error, :duplicate_id} =
               EventStream.publish("dd2", valid_event("dup-2", %{"source" => "/smalt/v2"}))

      events = EventStream.list_events("dd2")
      assert [%{"id" => "dup-2", "source" => "/smalt/v1"}] = events
    end)
  end

  test "stored events carry the topic field" do
    {:ok, _} = EventStream.publish("stamped", valid_event("s-1"))
    assert [%{"topic" => "stamped"}] = EventStream.list_events("stamped")
  end
end
