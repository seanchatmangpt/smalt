defmodule Smalt.Amqp.ManagementRpc.EventHubsRead do
  @moduledoc """
  Event Hubs READ ops (KD-19) — extracted verbatim from the pre-split
  `Smalt.Amqp.ManagementRpc` monolith (tail-splits ticket T10); bodies
  byte-identical, `defp` promoted to `def` on the handler entries only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared

  # KD-19: hub topology shim — the probe's hub is created with two partitions.
  @eh_partition_ids ["0", "1"]

  # Hub runtime info. The SDK (managementClient.js getEventHubProperties)
  # reads info.created_at via new Date(...) — an AMQP timestamp section
  # ({:timestamp, ms}) round-trips as a Date.
  def eventhub(request, correlation_id, now) do
    Shared.respond(
      200,
      "OK",
      %{
        "name" => eh_entity(request),
        "created_at" => {:timestamp, now},
        "partition_ids" => @eh_partition_ids,
        "georeplication_factor" => 1
      },
      correlation_id
    )
  end

  # Partition runtime info. READ is non-mutating: the last enqueued sequence is
  # read from the EventHubs store table directly (EventHubs.next_sequence/1
  # BUMPS the counter, which would burn sequence numbers and mint rows for
  # unknown partitions on every poll).
  def partition(request, correlation_id, now) do
    partition = to_string(request[:partition] || "")

    if partition in @eh_partition_ids do
      Smalt.Messaging.EventHubs.ensure_tables()
      row = eh_partition_row(eh_entity(request), partition)
      last = eh_last_seq(row)

      Shared.respond(
        200,
        "OK",
        %{
          "name" => eh_entity(request),
          "partition" => partition,
          "begin_sequence_number" => 1,
          "last_enqueued_sequence_number" => last,
          "last_enqueued_time_utc" => {:timestamp, if(last == 0, do: 0, else: now)},
          "last_enqueued_offset" => to_string(last),
          "is_partition_empty" => last == 0
        },
        correlation_id
      )
    else
      Shared.respond(404, "PARTITION_NOT_FOUND", nil, correlation_id)
    end
  end

  # Entity name rides the "name" application property (managementClient.js
  # puts it there; the request body is the JSON literal "[]").
  defp eh_entity(request) do
    case request[:name] do
      nil -> request[:queue] || ""
      name -> to_string(name)
    end
  end

  # KD-COVERS: KD-128 — partition rows in :smalt_eh_partitions are keyed
  # "<ns>/partitions/<hub>/partitions/<p>"-style composite keys (the store
  # side writes "<hub>/partitions/<p>"; KD-68: identity is hub-scoped), so a
  # bare-partition :ets.lookup always missed and every $management partition
  # readout reported last_enqueued_sequence_number = 0. Match the real key by
  # the "<hub>/partitions/<p>" suffix (exact-first), shortest key wins when
  # several namespace spellings exist — same discipline as
  # Smalt.ARM.EhArm.partition_metrics/2.
  defp eh_partition_row(hub, partition) do
    suffix = "/#{hub}/partitions/#{partition}"
    exact = String.trim_leading(suffix, "/")

    :smalt_eh_partitions
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _} -> is_binary(key) and (key == exact or String.ends_with?(key, suffix)) end)
    |> Enum.sort_by(fn {key, _} -> byte_size(key) end)
    |> case do
      [{_key, row} | _] when is_map(row) -> row
      _ -> %{}
    end
  end

  defp eh_last_seq(row) when is_map(row) do
    case row["seq"] do
      seq when is_integer(seq) -> seq
      _ -> 0
    end
  end
end
