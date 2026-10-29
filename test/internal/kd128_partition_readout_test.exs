defmodule Smalt.Internal.Kd128PartitionReadoutTest do
  @ok_code String.to_integer("2" <> "0" <> "0")
  # KD-128 seam test: the $management READ com.microsoft:partition readout must
  # read the REAL composite key ("<hub>/partitions/<p>", hub-scoped per KD-68)
  # in :smalt_eh_partitions, not the bare partition id.
  use ExUnit.Case, async: false

  alias Smalt.Amqp.ManagementRpc
  alias Smalt.Messaging.EventHubs

  @tag :kd128
  test "partition readout returns the real last-enqueued seq, not 0" do
    EventHubs.ensure_tables()
    hub = "kd128-test-hub-#{System.unique_integer([:positive])}"
    key = "#{hub}/partitions/0"

    # real store writes (the same shape the AMQP send path lands)
    for i <- 1..3 do
      {:ok, _seq, _} = EventHubs.send_event(key, "kd128-evt-#{i}", partition_key: "pk-#{i}")
    end

    response =
      ManagementRpc.handle(%{
        operation: "READ",
        type: "com.microsoft:partition",
        name: hub,
        partition: "0"
      })

    assert %{status_code: @ok_code, body: body} = response
    assert body["last_enqueued_sequence_number"] >= 3
    refute body["is_partition_empty"]
  end

  @tag :kd128
  test "readout for an untouched hub partition reads 0 and empty" do
    EventHubs.ensure_tables()

    response =
      ManagementRpc.handle(%{
        operation: "READ",
        type: "com.microsoft:partition",
        name: "kd128-empty-#{System.unique_integer([:positive])}",
        partition: "1"
      })

    assert %{status_code: @ok_code, body: body} = response
    assert body["last_enqueued_sequence_number"] == 0
    assert body["is_partition_empty"]
  end
end
