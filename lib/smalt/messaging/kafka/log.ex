defmodule Smalt.Messaging.Kafka.Log do
  @moduledoc """
  AZ-1 — Kafka partition log face: the thin wrapper over the shared
  `Smalt.Messaging.PartitionLog` engine (v26.11.6 L6 extraction).

  Each Kafka topic partition maps to a segmented journal (the `.wal` face:
  `Smalt.Storage.JournalSink` append-only `seg-*.journal` frames; sealed
  segments carry the `.seal` + `.meta.json` gates) plus the EH partition
  receivers (`Smalt.Messaging.EventHubs.send_event/3` on
  `"<topic>/partitions/<n>"` — the AMQP 5673 consumer side reads these
  back). `Smalt.Storage.JournalReader` replays sealed segments byte-exact
  on boot.

  Storage (shared ETS instance, face isolation BY TOPIC):
  - `:smalt_kafka_batches` (set) — key `{topic, partition, base_offset}` →
    `%{raw: batch_bytes, count: n, event_type: 0x4B46}`. The raw bytes are
    re-served byte-exact by Fetch (sealed AND active: both live here, the
    journal is the durable layer beneath). Entries stored by other faces
    (AoQ, event_type `0x414F`) carry their bare payload here too — face
    isolation is by topic, never by table.
  - `:smalt_kafka_next` (set) — key `{topic, partition}` → next assignable
    offset (the log end offset / high watermark).

  Serialization: offset assignment and journal append are serialized through
  the named GenServer (single-writer discipline, same shape as
  `Smalt.Messaging.EventHubs.Server`).

  The sieve (GL-2): every produce batch rides `Smalt.Sync.Guard.run_guard/2`
  — the SAME seam sync frames ride (`Application.get_env(:smalt, :sync_guard)`),
  overridable per-surface via `:smalt, :kafka_guard`. `{:andon, _}` → typed
  POLICY_VIOLATION produce face, nothing stored, nothing journaled.
  """

  use GenServer
  require Logger

  alias Smalt.Messaging.EventHubs
  alias Smalt.Messaging.Kafka.Records
  alias Smalt.Messaging.PartitionLog

  @event_type 0x4B46
  # journal table_id = kafka partition number (u16), journal key = topic

  @tables [batches: :smalt_kafka_batches, next: :smalt_kafka_next]

  @doc "Journal event_type stamped on Kafka batch frames (\"KF\")."
  def event_type, do: @event_type

  @doc "Default topic (config :smalt, :kafka_topic)."
  @spec default_topic() :: String.t()
  def default_topic, do: Application.get_env(:smalt, :kafka_topic, "kafka")

  @doc "Partition count per topic (config :smalt, :kafka_partitions, default 2)."
  @spec partition_count() :: pos_integer()
  def partition_count, do: Application.get_env(:smalt, :kafka_partitions, 2)

  @doc """
  Topics this face serves: the default topic always, plus any topic that
  already has stored batches (any face — isolation is by topic).
  """
  @spec list_topics() :: [String.t()]
  def list_topics do
    ensure_tables()

    ([default_topic()] ++
       (:ets.tab2list(:smalt_kafka_batches)
        |> Enum.map(fn {{t, _p, _b}, _} -> t end)))
    |> Enum.uniq()
  end

  @doc "Idempotently ensure the log tables exist (server-owned)."
  @spec ensure_tables() :: :ok
  def ensure_tables, do: PartitionLog.ensure_tables(@tables)

  @doc "High watermark (next assignable offset) for {topic, partition}."
  @spec high_watermark(String.t(), non_neg_integer()) :: non_neg_integer()
  def high_watermark(topic, partition), do: PartitionLog.high_watermark(@tables, topic, partition)

  @doc """
  EXPL-4 F4: true iff {topic, partition} is a served partition — the index
  is inside the configured `partition_count/0` range AND the topic is known
  (the default topic, or one with stored batches on any face). Reads of
  unknown {topic, partition} answer `Wire.error_code(:unknown_topic_or_partition)`
  (error 3) at the conn layer, never an empty success.
  """
  @spec partition_known?(String.t(), integer()) :: boolean()
  def partition_known?(topic, p) when is_binary(topic) and is_integer(p) and p >= 0 do
    p < partition_count() and topic in list_topics()
  end

  def partition_known?(_, _), do: false

  @doc """
  Append verified batches to partition `p` of `topic` (serialized). Returns
  `{:ok, base_offset, count}` for the LAST batch, or
  `{:error, {:policy_violation, reason}}` when the sieve refuses (nothing
  stored), or `{:error, {:journal_down, reason}}` when the sink refuses.
  """
  @spec produce(String.t(), non_neg_integer(), [binary()]) ::
          {:ok, non_neg_integer(), pos_integer()}
          | {:error, {:policy_violation, String.t()} | {:journal_down, term()} | term()}
  def produce(topic, p, raw_batches) when is_binary(topic) and is_integer(p) and p >= 0 do
    PartitionLog.produce(__MODULE__, topic, p, raw_batches, @event_type)
  end

  @doc """
  Batches for {topic, partition} whose last offset >= fetch_offset,
  ascending by base offset: `[%{base_offset, count, raw}]`.

  Serve-time framing law: entries stored by THIS face (event_type `0x4B46`)
  are served byte-exact (kafka store framing — the raw IS a legal kafka
  batch). Entries stored by a non-kafka face on the shared tables (AoQ
  passthrough, bare payload) are framed AT SERVE TIME into the minimal
  legal legacy message-set v0 record — never at store time, and the stored
  bytes stay bare.
  """
  @spec fetch(String.t(), non_neg_integer(), non_neg_integer()) :: [
          %{base_offset: non_neg_integer(), count: pos_integer(), raw: binary()}
        ]
  def fetch(topic, p, fetch_offset) do
    ensure_tables()

    :ets.tab2list(:smalt_kafka_batches)
    |> Enum.filter(fn {{t, q, base}, %{count: c}} ->
      t == topic and q == p and base + c > fetch_offset
    end)
    |> Enum.sort_by(fn {{_, _, base}, _} -> base end)
    |> Enum.map(fn {{_t, _q, base}, entry} ->
      # EXPL-4 (KAFKA-EXP4): project to the documented %{base_offset, count,
      # raw} shape — the raw ETS tuples leaked through here and the conn
      # Fetch leg's take_batches (which pattern-matches the map) could never
      # re-serve a batch.
      count = Map.get(entry, :count, 1)
      raw = Map.get(entry, :raw, <<>>)

      if Map.get(entry, :event_type, @event_type) == @event_type do
        %{base_offset: base, count: count, raw: raw}
      else
        # Cross-face serve (serve-time framing law): minimal legal legacy
        # frame built HERE, at serve time — conn.ex serve_batch's legacy
        # clause serves it verbatim and kafka-python parses the record back
        # byte-exact. Down-conversion is never triggered (the frame is
        # already magic-0).
        %{base_offset: base, count: count, raw: serve_frame(base, raw)}
      end
    end)
  end

  @doc """
  Replay SEALED journal segments into the log. Byte-exact: the journaled
  payload IS the batch bytes (with the broker-stamped base offset), so
  replay restores the exact produced surface. Returns the number of
  batches restored.
  """
  @spec replay_sealed() :: non_neg_integer()
  def replay_sealed do
    ensure_tables()
    GenServer.call(__MODULE__, :replay_sealed)
  end

  # -- instance wiring -------------------------------------------------------------

  def start_link(opts \\ []) do
    PartitionLog.start_link(
      opts
      |> Keyword.put_new(:name, __MODULE__)
      |> Keyword.put_new(:label, %{service: :kafka, role: :log})
      |> Keyword.put_new(:sink, Smalt.Messaging.Kafka.Sink)
      |> Keyword.put_new(:parser, {Records, :parse_verified, []})
      |> Keyword.put_new(:fan_out, {__MODULE__, :fan_out_eh, []})
      |> Keyword.put_new(:guard, {__MODULE__, :sieve, []})
      |> Keyword.put_new(:event_type, @event_type)
      |> Keyword.put_new(:log_prefix, "kafka")
    )
  end

  # -- kafka-face seams (public for the engine's MFAs; prose verbatim) --------------

  # EH fan-out: the Kafka partition's records land in the EH store under
  # "<topic>/partitions/<p>" — the landed EH partition receivers (AMQP 5673
  # listener links) are the consumer side of this face. Journal is the
  # source of truth: a fan-out failure degrades only the AMQP leg, never
  # the Kafka append (typed log, never silent, never a crash).
  # EXPL-4 F3: fan-out rides the SAME verified record list admit_one parsed
  # (parse_records cross-checks recordsCount) — the unreachable-warning
  # finding is closed: tail-drop now refuses at admit, so fan_out_eh can
  # no longer silently under-deliver.
  @doc false
  def fan_out_eh(topic, p, records) do
    Enum.each(records, fn rec ->
      partition_key = "#{topic}/partitions/#{p}"

      case EventHubs.send_event(partition_key, rec.value, partition_key: partition_key) do
        {:ok, _seq, _event} -> :ok

        {:error, {:throttled, _}} ->
          Logger.warning("[kafka] EH fan-out throttled for #{topic}/#{p}")
      end
    end)
  end

  @doc false
  def sieve(raw) do
    Smalt.Sync.Guard.run_guard(
      raw,
      Application.get_env(:smalt, :kafka_guard) || Application.get_env(:smalt, :sync_guard)
    )
  end

  # -- serve-time framing (cross-face law) -------------------------------------------

  # Minimal legal legacy message-set v0 record: crc u32 | magic 0 |
  # attributes 0 | keyLen i32 (-1 = null key) | valueLen i32 | value.
  # IEEE CRC32 over everything after the CRC field — the same face
  # Records.verify_batch/1 checks on the legacy produce side. The only
  # offset face on this wire format is the {offset i64, size i32} wrapper,
  # so the broker-assigned base offset lands in the wrapper.
  defp serve_frame(offset, payload) do
    body = <<0::8>> <> <<-1::signed-32>> <> <<byte_size(payload)::signed-32, payload::binary>>
    frame = <<:erlang.crc32(<<0::8, body::binary>>)::unsigned-32, 0::8, body::binary>>

    <<
      offset::signed-integer-size(64),
      byte_size(frame)::unsigned-integer-size(32),
      frame::binary
    >>
  end
end
