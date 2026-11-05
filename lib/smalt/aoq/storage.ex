defmodule Smalt.Aoq.Storage do
  @moduledoc """
  v26.11.6 L6 — AoQ durable log face over the shared
  `Smalt.Messaging.PartitionLog` engine (same ETS instance as the kafka
  face — the kafka literal tables — face isolation BY TOPIC: the AoQ topic,
  config `:smalt, :aoq_log_topic`, default `"aoq"`).

  Journal face: `Smalt.Aoq.LogSink` (segmented journal under
  config `:smalt, :aoq_log_dir`), event_type `0x414F` ("AO"), journal
  table_id = the frame-type byte (the partition face), journal key = the
  AoQ topic.

  Store law: the payload is stored BARE (ETS and journal) — never wrapped
  at store time. The kafka-legal legacy serve frame is built at serve time
  on the kafka face (`Smalt.Messaging.Kafka.Log.fetch/3`); the AoQ face
  serves the bare payload byte-exact.

  Offset face: the frame-type byte is the partition; each append assigns
  the next offset in that partition (one record per append via the
  passthrough parser).
  """

  alias Smalt.Messaging.PartitionLog

  @topic_default "aoq"
  @event_type 0x414F
  @server Smalt.Aoq.Storage.Server
  @tables [batches: :smalt_kafka_batches, next: :smalt_kafka_next]

  @doc "AoQ log topic (config :smalt, :aoq_log_topic, default \"aoq\")."
  @spec topic() :: String.t()
  def topic, do: Application.get_env(:smalt, :aoq_log_topic, @topic_default)

  @doc "Journal event_type stamped on AoQ log frames (\"AO\")."
  @spec event_type() :: 0x414F
  def event_type, do: @event_type

  @doc """
  Parser MFA target for the AoQ PartitionLog instance: the passthrough —
  one record per append, `{:ok, 1, [payload]}`, no kafka parsing.
  """
  @spec passthrough_parser(binary()) :: {:ok, pos_integer(), [binary()]}
  def passthrough_parser(payload) when is_binary(payload), do: {:ok, 1, [payload]}

  @doc """
  Append `payload` under frame-type byte `frame_type` (the partition face,
  0..255). Serialized through the named single-writer GenServer
  (journal-ok → ETS ordering). Returns `{:ok, offset}` (the assigned
  offset; count is always 1 per append), `{:error, {:journal_down, reason}}`
  when the sink refuses. Payload must be at least 1 byte (the AoQ framing
  law: no empty bodies).
  """
  @spec append(non_neg_integer(), binary()) ::
          {:ok, non_neg_integer()} | {:error, :bad_frame_type | :empty_payload | {:journal_down, term()}}
  def append(frame_type, payload)
      when is_integer(frame_type) and frame_type >= 0 and frame_type <= 255 and
             is_binary(payload) and byte_size(payload) >= 1 do
    case PartitionLog.produce(@server, topic(), frame_type, [payload], @event_type) do
      {:ok, base, 1} -> {:ok, base}
      {:error, _} = err -> err
    end
  end

  def append(_frame_type, <<>>), do: {:error, :empty_payload}

  def append(frame_type, _) when is_integer(frame_type), do: {:error, :bad_frame_type}

  @doc """
  High-watermark offsets per frame-type partition of the AoQ topic:
  `{:ok, %{frame_type => hwm}}`, or `{:error, :unknown_partition}` typed
  refusal for any other topic (face isolation is by topic).
  """
  @spec offsets(String.t()) ::
          {:ok, %{non_neg_integer() => non_neg_integer()}} | {:error, :unknown_partition}
  def offsets(topic) do
    if topic == topic() do
      batches = @tables[:batches]
      _ = PartitionLog.ensure_tables(@tables)

      offsets =
        :ets.tab2list(batches)
        |> Enum.filter(fn {{t, _p, _base}, _} -> t == topic() end)
        |> Enum.map(fn {{_t, p, base}, %{count: c}} -> {p, base + c} end)
        |> Enum.reduce(%{}, fn {p, end_off}, acc ->
          Map.update(acc, p, end_off, fn cur -> max(cur, end_off) end)
        end)

      {:ok, offsets}
    else
      {:error, :unknown_partition}
    end
  end

  @doc """
  Fetch the AoQ face: every stored entry with offset >= `offset` across the
  topic's frame-type partitions, ascending —
  `{:ok, [%{offset, frame_type, payload}]}`, payload byte-exact (bare,
  serve-order law).

  Typed refusals:
  - `{:error, {:offset_overflow, hwm}}` — `offset` is past every partition's
    high watermark (`hwm` = the highest).
  - `{:error, :unknown_partition}` — any topic other than the AoQ topic.
  """
  @spec fetch(String.t(), non_neg_integer()) ::
          {:ok, [%{offset: non_neg_integer(), frame_type: non_neg_integer(), payload: binary()}]}
          | {:error, {:offset_overflow, non_neg_integer()} | :unknown_partition}
  def fetch(topic, offset) when is_binary(topic) and is_integer(offset) and offset >= 0 do
    if topic == topic() do
      batches = @tables[:batches]
      _ = PartitionLog.ensure_tables(@tables)

      entries =
        :ets.tab2list(batches)
        |> Enum.filter(fn {{t, _p, base}, _} -> t == topic() and base >= offset end)
        |> Enum.sort_by(fn {{_t, _p, base}, _} -> base end)
        |> Enum.map(fn {{_t, p, base}, %{raw: raw}} ->
          %{offset: base, frame_type: p, payload: raw}
        end)

      max_hwm =
        offsets(topic())
        |> elem(1)
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      if offset > max_hwm do
        {:error, {:offset_overflow, max_hwm}}
      else
        {:ok, entries}
      end
    else
      {:error, :unknown_partition}
    end
  end

  def fetch(_, _), do: {:error, :unknown_partition}
end
