defmodule Smalt.Messaging.Kafka.Log do
  @moduledoc """
  AZ-1 — Kafka partition log engine.

  Each Kafka topic partition maps to a segmented journal (the `.wal` face:
  `Smalt.Storage.JournalSink` append-only `seg-*.journal` frames; sealed
  segments carry the `.seal` + `.meta.json` gates) plus the EH partition
  receivers (`Smalt.Messaging.EventHubs.send_event/3` on
  `"<topic>/partitions/<n>"` — the AMQP 5673 consumer side reads these
  back). `Smalt.Storage.JournalReader` replays sealed segments byte-exact
  on boot.

  Storage:
  - `:smalt_kafka_batches` (set) — key `{topic, partition, base_offset}` →
    `%{raw: batch_bytes, count: n, records: [...]}`. The raw bytes are
    re-served byte-exact by Fetch (sealed AND active: both live here, the
    journal is the durable layer beneath).
  - `:smalt_kafka_next` (set) — key `{topic, partition}` → next assignable
    offset (the log end offset / high watermark).

  Serialization: offset assignment and journal append are serialized through
  this named GenServer (single-writer discipline, same shape as
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
  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @event_type 0x4B46
  # journal table_id = kafka partition number (u16), journal key = topic

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
  already has stored batches.
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
  def ensure_tables do
    if :ets.info(:smalt_kafka_batches) == :undefined do
      :ets.new(:smalt_kafka_batches, [:set, :named_table, :public, read_concurrency: true])
    end

    if :ets.info(:smalt_kafka_next) == :undefined do
      :ets.new(:smalt_kafka_next, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "High watermark (next assignable offset) for {topic, partition}."
  @spec high_watermark(String.t(), non_neg_integer()) :: non_neg_integer()
  def high_watermark(topic, partition) do
    ensure_tables()

    case :ets.lookup(:smalt_kafka_next, {topic, partition}) do
      [{{_, _}, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc """
  EXPL-4 F4: true iff {topic, partition} is a served partition — the index
  is inside the configured `partition_count/0` range AND the topic is known
  (the default topic, or one with stored batches). Reads of unknown
  {topic, partition} answer `Wire.error_code(:unknown_topic_or_partition)`
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
          | {:error, {:policy_violation, String.t()} | {:journal_down, term()}}
  def produce(topic, p, raw_batches) when is_binary(topic) and is_integer(p) and p >= 0 do
    ensure_tables()
    GenServer.call(__MODULE__, {:produce, topic, p, raw_batches})
  end

  @doc """
  Batches for {topic, partition} whose last offset >= fetch_offset,
  ascending by base offset: `[%{base_offset, count, raw}]`.
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
    |> Enum.map(fn {{_t, _q, base}, %{raw: raw, count: c}} ->
      # EXPL-4 (KAFKA-EXP4): project to the documented %{base_offset, count,
      # raw} shape — the raw ETS tuples leaked through here and the conn
      # Fetch leg's take_batches (which pattern-matches the map) could never
      # re-serve a batch.
      %{base_offset: base, count: c, raw: raw}
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

  # -- GenServer -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.set_label(%{service: :kafka, role: :log})

    dir =
      Keyword.get(opts, :dir) || Application.get_env(:smalt, :kafka_log_dir) ||
        "var/kafka-journal"

    ensure_tables()
    replayed = do_replay_sealed(dir)

    if replayed > 0 do
      Logger.info("[kafka] replayed #{replayed} batch(es) from sealed journal under #{dir}")
    end

    {:ok, %{dir: dir, replayed: replayed}}
  end

  @impl true
  def handle_call({:produce, topic, p, raw_batches}, _from, state) do
    reply =
      Enum.reduce(raw_batches, {:ok, 0, 0}, fn raw, acc ->
        case acc do
          {:ok, _, _} -> produce_one(topic, p, raw)
          e -> e
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:replay_sealed, _from, state) do
    {:reply, do_replay_sealed(state.dir), state}
  end

  # -- internals -----------------------------------------------------------------

  defp produce_one(topic, p, raw) do
    case sieve(raw) do
      {:admit, _} -> admit_one(topic, p, raw)
      {:andon, <<1::8, _len::16, reason::binary>>} -> {:error, {:policy_violation, reason}}
      {:andon, other} -> {:error, {:policy_violation, "guard-unresolved: " <> inspect(other)}}
    end
  end

  defp admit_one(topic, p, raw) do
    with {:ok, count} <- Records.count(raw),
         # EXPL-4 F3: never store/fan out on a count mismatch — a CRC-valid
         # batch with a malformed tail is refused (typed), not partially
         # admitted (header count 2, one record fanned out — the witnessed
         # silent-drop face). The parse cost is one pass; the store leg and
         # the EH fan-out leg below both ride the verified record list.
         {:ok, records} <- Records.parse_records(raw) do
      base = high_watermark(topic, p)
      stored = raw |> store_raw(base) |> stamp_base_offset(base)

      case JournalSink.append(sink(), @event_type, p, topic, stored) do
        {:ok, _seq} ->
          :ets.insert(:smalt_kafka_batches, {{topic, p, base}, %{raw: stored, count: count}})
          :ets.insert(:smalt_kafka_next, {{topic, p}, base + count})
          fan_out_eh(topic, p, records)
          {:ok, base, count}

        {:error, reason} ->
          # JournalSink degraded mode still answers {:ok, seq}; a hard
          # {:error,_} here is a sink-down face — typed refusal, never a
          # fake ack.
          {:error, {:journal_down, reason}}
      end
    end
  end

  defp sink, do: Smalt.Messaging.Kafka.Sink

  defp sieve(raw),
    do:
      Smalt.Sync.Guard.run_guard(
        raw,
        Application.get_env(:smalt, :kafka_guard) || Application.get_env(:smalt, :sync_guard)
      )

  # Patch the broker-assigned base offset into bytes 0..7. Uniform across
  # magics: a magic-2 batch's first 8 bytes are the baseOffset field; a
  # legacy magic-0/1 stored frame keeps its {offset, size} wrapper, whose
  # first 8 bytes are the offset field. The patch is CRC-neutral in both
  # layouts (neither CRC covers the wrapper/offset prefix), and the CRC
  # still verifies client-side on fetch-back.
  defp stamp_base_offset(raw, base) do
    <<_::binary-size(8), rest::binary>> = raw
    <<base::signed-integer-size(64), rest::binary>>
  end

  # Legacy magic-0/1 stored frames keep the {offset, size} wrapper so the
  # broker-assigned offset survives journal replay byte-exact (the stripped
  # frame carries no offset field). Magic-2 batches carry the offset field
  # in the batch header itself and are stored bare.
  defp store_raw(<<_::binary-size(16), 2::integer-size(8), _::binary>> = raw, _base), do: raw

  defp store_raw(raw, base) do
    <<base::signed-integer-size(64), byte_size(raw)::unsigned-integer-size(32), raw::binary>>
  end

  # Record count out of a STORED raw (magic-2 batch or legacy wrapped frame).
  defp stored_count(<<_::binary-size(12), rest::binary>>) do
    case rest do
      <<_::binary-size(4), m::integer-size(8), _::binary>> when m in [0, 1, 2] ->
        Records.count(rest)

      _ ->
        {:ok, 1}
    end
  end

  # EH fan-out: the Kafka partition's records land in the EH store under
  # "<topic>/partitions/<p>" — the landed EH partition receivers (AMQP 5673
  # listener links) are the consumer side of this face. Journal is the
  # source of truth: a fan-out failure degrades only the AMQP leg, never
  # the Kafka append (typed log, never silent, never a crash).
  # EXPL-4 F3: fan-out rides the SAME verified record list admit_one parsed
  # (parse_records cross-checks recordsCount) — the unreachable-warning
  # finding is closed: tail-drop now refuses at admit, so fan_out_eh can
  # no longer silently under-deliver.
  defp fan_out_eh(topic, p, records) do
    Enum.each(records, fn rec ->
      partition_key = "#{topic}/partitions/#{p}"

      case EventHubs.send_event(partition_key, rec.value, partition_key: partition_key) do
        {:ok, _seq, _event} -> :ok

        {:error, {:throttled, _}} ->
          Logger.warning("[kafka] EH fan-out throttled for #{topic}/#{p}")
      end
    end)
  end

  defp do_replay_sealed(dir) do
    with {:ok, segs} <- JournalReader.discover_sealed_segments(dir) do
      Enum.reduce(segs, 0, fn seg, acc ->
        case JournalReader.read_sealed_segment(seg) do
          {:ok, frames} ->
            Enum.reduce(frames, acc, fn f, n ->
              if f.event_type == @event_type, do: restore_frame(f, n + 1), else: n
            end)

          {:error, reason} ->
            # Sealed-reader integrity refusal is fail-closed upstream: a
            # refusal here logs typed and skips the segment — replay is
            # best-effort at boot because the reader already quarantined
            # completeness failures; integrity failures remain loud.
            Logger.error(
              "[kafka] sealed segment replay refused (#{Path.basename(seg)}): #{inspect(reason)}"
            )

            acc
        end
      end)
    end
  end

  defp restore_frame(f, n) do
    key = {f.key, f.table_id, base_offset_of(f.payload)}
    count =
      case stored_count(f.payload) do
        {:ok, n} -> n
        _ -> 1
      end

    unless :ets.member(:smalt_kafka_batches, key) do
      :ets.insert(:smalt_kafka_batches, {key, %{raw: f.payload, count: count}})

      {t, q, base} = key
      cur = high_watermark(t, q)
      if base + count > cur, do: :ets.insert(:smalt_kafka_next, {{t, q}, base + count})
    end

    n
  end

  defp base_offset_of(<<base::signed-integer-size(64), _::binary>>), do: base
  defp base_offset_of(_), do: 0
end
