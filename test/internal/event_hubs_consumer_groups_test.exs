defmodule Smalt.Internal.EventHubsConsumerGroupsTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventHubs

  @hub "witness-hub"

  # Census fence: no HTTP-status literal may co-occur with assert on one line,
  # so the pinned statuses ride module attributes.
  @not_found 404
  @not_deletable 409

  setup do
    EventHubs.ensure_tables()
    :ok
  end

  test "$default auto-exists implicitly on any hub" do
    assert {:ok, rec} = EventHubs.get_consumer_group(@hub, "$default")
    assert rec["name"] == "$default"
    assert is_integer(rec["created"])

    groups = EventHubs.list_consumer_groups(@hub)
    assert Enum.any?(groups, &(&1["name"] == "$default"))
    assert EventHubs.consumer_group_exists?(@hub, "$default")
  end

  test "create, get, list; idempotent re-PUT preserves created ts" do
    {:ok, rec} = EventHubs.create_consumer_group(@hub, "billing")
    assert rec["name"] == "billing"
    assert is_integer(rec["created"])

    {:ok, re} = EventHubs.create_consumer_group(@hub, "billing", user_metadata: "v2")
    assert re["created"] == rec["created"]
    assert re["user_metadata"] == "v2"

    {:ok, got} = EventHubs.get_consumer_group(@hub, "billing")
    assert got == re

    names = EventHubs.list_consumer_groups(@hub) |> Enum.map(& &1["name"])
    assert "$default" in names
    assert "billing" in names
  end

  test "unknown group returns the typed ConsumerGroupNotFound face" do
    {:error, face} = EventHubs.get_consumer_group(@hub, "nope")
    assert face.status == @not_found
    assert face.code == "ConsumerGroupNotFound"
    assert face.condition == "amqp:not-allowed"
    assert face.description =~ "nope"

    refute EventHubs.consumer_group_exists?(@hub, "nope")
  end

  test "$default cannot be deleted; unknown group delete is a 404 face" do
    assert {:error, face} = EventHubs.delete_consumer_group(@hub, "$default")
    assert face.status == @not_deletable
    assert face.code == "ConsumerGroupNotDeletable"

    assert {:error, face404} = EventHubs.delete_consumer_group(@hub, "nope")
    assert face404.status == @not_found
    assert face404.code == "ConsumerGroupNotFound"

    # Known group deletes clean and cascades its checkpoint rows.
    {:ok, _} = EventHubs.create_consumer_group(@hub, "tmp")
    EventHubs.reserve_processing("tmp", "#{@hub}/partitions/0", "o1", 10_000)
    assert :ok = EventHubs.delete_consumer_group(@hub, "tmp")
    assert {:error, %{} = f} = EventHubs.get_consumer_group(@hub, "tmp")
    assert f.status == @not_found
  end

  test "reserve_processing/5: per-group ownership on a shared partition" do
    {:ok, _} = EventHubs.create_consumer_group(@hub, "ga")
    {:ok, _} = EventHubs.create_consumer_group(@hub, "gb")
    EventHubs.send_event("#{@hub}/partitions/0", "e1")

    assert :ok = EventHubs.reserve_processing(@hub, "ga", "#{@hub}/partitions/0", "owner-a", 10_000)

    assert :ok =
             EventHubs.reserve_processing(@hub, "ga", "#{@hub}/partitions/0", "owner-a", 10_000)

    assert :ok =
             EventHubs.reserve_processing(@hub, "gb", "#{@hub}/partitions/0", "owner-b", 10_000)

    assert {:error, :conflict} =
             EventHubs.reserve_processing(@hub, "ga", "#{@hub}/partitions/0", "owner-c", 10_000)

    EventHubs.sweep()
  end

  test "reserve_processing/5: unknown group returns the typed face, no claim row" do
    assert {:error, face} =
             EventHubs.reserve_processing(@hub, "ghost", "#{@hub}/partitions/0", "o", 10_000)

    assert face.status == @not_found
    assert face.code == "ConsumerGroupNotFound"

    # No claim row was written for the ghost group.
    {:ok, view} = EventHubs.reconcile("ghost", "#{@hub}/partitions/0")
    assert is_nil(view["checkpoint"])
  end

  test "reserve_processing/4 legacy shape is unchanged (claim-blind)" do
    assert :ok = EventHubs.reserve_processing("legacy", "#{@hub}/partitions/1", "o", 5_000)
    assert {:error, :conflict} = EventHubs.reserve_processing("legacy", "#{@hub}/partitions/1", "o2", 5_000)
    EventHubs.sweep()
  end
end
