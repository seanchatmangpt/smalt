defmodule Smalt.Messaging.EventStream do
  @moduledoc """
  Event Grid & Event Hubs emulator (`Microsoft.EventGrid/topics`, `Microsoft.EventHub/namespaces`).
  Accepts CloudEvents 1.0 JSON payloads and partitions them in-memory.

  Messages are stored under the key `topic <> "/" <> id` in the
  `:smalt_event_messages` table, so `Smalt.Store.list_prefix/2` scans return
  only the requested topic's events. Each stored message carries a monotonically
  increasing `"seq"` field so `list_events/1` returns insertion order regardless
  of id ordering.
  """
  alias Smalt.Store

  @table :smalt_event_messages
  @counter_table :smalt_event_stream_seq

  # ---------------------------------------------------------------------------
  # Publish
  # ---------------------------------------------------------------------------

  @doc """
  Publishes a single CloudEvents 1.0 event to `topic`.

  Validates required CloudEvents 1.0 context attributes: `specversion` must be
  `"1.0"`, `id` must be non-empty (a UUID is generated and stamped when absent,
  before storing), `source` and `type` must be present and non-empty.

  Returns `{:ok, id}` on success, `{:error, :invalid_cloudevent}` otherwise.
  """
  @spec publish(String.t() | atom, map) :: {:ok, String.t()} | {:error, :invalid_cloudevent}
  def publish(topic, event) when is_map(event) do
    with true <- is_binary(event["specversion"]) and event["specversion"] == "1.0",
         true <- present?(event["source"]),
         true <- present?(event["type"]) do
      id = event_id(event)
      seq = next_seq()

      event
      |> Map.put("id", id)
      |> Map.put("topic", to_string(topic))
      |> Map.put("seq", seq)
      |> then(&Store.put(@table, "#{topic}/#{id}", &1))

      {:ok, id}
    else
      false -> {:error, :invalid_cloudevent}
    end
  end

  def publish(_topic, _event), do: {:error, :invalid_cloudevent}

  @doc """
  Publishes a list of CloudEvents 1.0 events to `topic`.

  Stops at the first invalid event, returning `{:error, :invalid_cloudevent}`;
  events before it remain stored. Returns `{:ok, [id]}` when all are stored.
  """
  @spec publish_many(String.t() | atom, [map]) :: {:ok, [String.t()]} | {:error, :invalid_cloudevent}
  def publish_many(topic, events) when is_list(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, ids} ->
      case publish(topic, event) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  @doc """
  Backward-compatible ingest used by `Smalt.EgressRouter`
  (`POST /topics/:topic/events`): accepts a single map or a list.

  Returns `:ok` when all events are valid, `{:error, :invalid_cloudevent}` when
  any event fails CloudEvents 1.0 validation.
  """
  @spec publish_events(String.t() | atom, map | [map]) :: :ok | {:error, :invalid_cloudevent}
  def publish_events(topic, events) when is_list(events) do
    case publish_many(topic, events) do
      {:ok, _ids} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def publish_events(topic, event) when is_map(event) do
    case publish(topic, event) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # List
  # ---------------------------------------------------------------------------

  @doc """
  Lists the events of `topic` only, in insertion order (by stored `seq`).
  """
  @spec list_events(String.t() | atom) :: [map]
  def list_events(topic) do
    @table
    |> Store.list_prefix(to_string(topic) <> "/")
    |> Enum.sort_by(fn ev -> Map.get(ev, "seq", 0) end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp present?(value), do: is_binary(value) and value != ""

  defp event_id(event) do
    case event["id"] do
      id when is_binary(id) and id != "" -> id
      _ -> uuid4()
    end
  end

  defp uuid4 do
    <<a::32, b::16, c_lo::12, _::4, d_lo::14, _::2, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c_lo::12, 2::2, d_lo::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<h1::binary-size(8), h2::binary-size(4), h3::binary-size(4), h4::binary-size(4),
        h5::binary-size(12)>> = hex

      Enum.join([h1, h2, h3, h4, h5], "-")
    end)
  end

  defp next_seq do
    ensure_counter_table()
    :ets.update_counter(@counter_table, :seq, {2, 1}, {:seq, 0})
  end

  defp ensure_counter_table do
    if :ets.info(@counter_table) == :undefined do
      :ets.new(@counter_table, [:named_table, :public, :set, write_concurrency: true])
    end

    :ok
  end
end
