defmodule Smalt.Messaging.PartitionLog do
  @moduledoc """
  v26.11.6 L6 — shared partition-log engine: the AZ-1
  `Smalt.Messaging.Kafka.Log` engine extracted VERBATIM and parameterized.

  One named GenServer per face, all faces over ONE shared ETS instance
  (the kafka literal tables `:smalt_kafka_batches` / `:smalt_kafka_next`) —
  face isolation is BY TOPIC (kafka default topic vs. the AoQ topic,
  config `:smalt, :aoq_log_topic`, default `"aoq"`). The single-writer law
  (journal-ok → ETS → fan-out ordering, serialized through the named
  GenServer) is preserved exactly.

  Instance opts (seams):

  - `:tables` — keyword `batches:` / `next:` (kafka literal names by
    default; the AoQ instance shares them).
  - `:sink` — journal sink name (kafka: `Smalt.Messaging.Kafka.Sink`;
    AoQ: `Smalt.Aoq.LogSink`).
  - `:event_type` — the instance's journal event_type (kafka `0x4B46` "KF"
    unchanged; AoQ `0x414F` "AO"); produce calls carry event_type per call,
    replay filters on the instance's.
  - `:fan_out` MFA — kafka: the moved `fan_out_eh/3` (EH partition
    receivers; the EH prose lives on the wrapper); AoQ: `nil` (no fan-out).
  - `:guard` MFA — kafka: the old `sieve/1` (Sync.Guard chain,
    `:kafka_guard || :sync_guard`); AoQ: `nil` (ungated).
  - `:parser` MFA — kafka: `{Smalt.Messaging.Kafka.Records, :parse_verified, []}`
    (fused count+parse admission); AoQ: `{:Smalt.Aoq.Storage, :passthrough_parser, []}`
    (`{:ok, 1, [payload]}` — one record per append).
  - `:dir` / `:log_prefix` / `:label` — journal dir, boot-log prefix,
    process label.

  Store-shape law (generic, dispatches on the bytes): a kafka-batch-shaped
  input keeps the AZ-1 store framing verbatim (`{offset, size}` wrapper for
  legacy magic-0/1 frames, bare magic-2 batches, broker-stamped base offset
  in bytes 0..7). Any other payload (the AoQ passthrough face) stores BARE
  in ETS and journal — the kafka-legal serve frame is built at serve time
  (`Smalt.Messaging.Kafka.Log.fetch/3` serve-time framing law), never at
  store time.

  Replay law: kafka-shaped payloads restore their broker-stamped base
  offset (bytes 0..7); bare payloads carry no offset field, so replay
  assigns the serve-order offset (the current hwm of `{topic, partition}`),
  which reproduces the original append-order offsets deterministically.
  """

  use GenServer
  require Logger

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @kafka_event_type 0x4B46

  # -- lifecycle -----------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- stateless read helpers (over the named tables) ------------------------------

  @doc "Idempotently ensure the instance's tables exist (server-owned)."
  @spec ensure_tables({atom(), atom()} | keyword()) :: :ok
  def ensure_tables(tables) do
    {batches, next} = table_pair(tables)

    if :ets.info(batches) == :undefined do
      :ets.new(batches, [:set, :named_table, :public, read_concurrency: true])
    end

    if :ets.info(next) == :undefined do
      :ets.new(next, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "High watermark (next assignable offset) for {topic, partition} over `tables`."
  @spec high_watermark({atom(), atom()} | keyword(), String.t(), non_neg_integer()) ::
          non_neg_integer()
  def high_watermark(tables, topic, p) do
    {_batches, next} = table_pair(tables)
    ensure_tables(tables)

    case :ets.lookup(next, {topic, p}) do
      [{{_, _}, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc """
  Batches for {topic, partition} whose last offset >= fetch_offset, ascending
  by base offset: `[%{base_offset, count, raw}]` — the generic projection.
  Face-level framing (the serve-time law) is each face wrapper's job.
  """
  @spec fetch({atom(), atom()} | keyword(), String.t(), non_neg_integer(), non_neg_integer()) :: [
          %{base_offset: non_neg_integer(), count: pos_integer(), raw: binary()}
        ]
  def fetch(tables, topic, p, fetch_offset) do
    {batches, _next} = table_pair(tables)
    ensure_tables(tables)

    :ets.tab2list(batches)
    |> Enum.filter(fn {{t, q, base}, %{count: c}} ->
      t == topic and q == p and base + c > fetch_offset
    end)
    |> Enum.sort_by(fn {{_, _, base}, _} -> base end)
    |> Enum.map(fn {{_t, _q, base}, %{raw: raw, count: c}} ->
      %{base_offset: base, count: c, raw: raw}
    end)
  end

  # -- write path (the named GenServer, single-writer law) --------------------------

  @doc """
  Append verified batches to partition `p` of `topic`, carrying `event_type`
  per call. Returns `{:ok, base_offset, count}` for the LAST batch, or the
  typed refusals (parser / sieve / journal-down; see the moduledoc).
  """
  @spec produce(GenServer.server(), String.t(), non_neg_integer(), [binary()], non_neg_integer()) ::
          {:ok, non_neg_integer(), pos_integer()} | {:error, term()}
  def produce(server, topic, p, raw_batches, event_type)
      when is_binary(topic) and is_integer(p) and p >= 0 do
    GenServer.call(server, {:produce, topic, p, raw_batches, event_type})
  end

  # -- GenServer -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.set_label(Keyword.get(opts, :label, %{service: :kafka, role: :log}))

    dir =
      Keyword.get(opts, :dir) || Application.get_env(:smalt, :kafka_log_dir) ||
        "var/kafka-journal"

    tables = Keyword.get(opts, :tables) || [batches: :smalt_kafka_batches, next: :smalt_kafka_next]
    {batches_table, next_table} = {tables[:batches], tables[:next]}

    state = %{
      dir: dir,
      tables: {batches_table, next_table},
      sink: Keyword.get(opts, :sink, Smalt.Messaging.Kafka.Sink),
      parser: Keyword.get(opts, :parser, {Smalt.Messaging.Kafka.Records, :parse_verified, []}),
      fan_out: Keyword.get(opts, :fan_out, {Smalt.Messaging.Kafka.Log, :fan_out_eh, []}),
      guard: Keyword.get(opts, :guard, {Smalt.Messaging.Kafka.Log, :sieve, []}),
      event_type: Keyword.get(opts, :event_type, @kafka_event_type),
      log_prefix: Keyword.get(opts, :log_prefix, "kafka"),
      replayed: 0
    }

    ensure_tables(state.tables)
    replayed = do_replay_sealed(state)

    if replayed > 0 do
      Logger.info("[#{state.log_prefix}] replayed #{replayed} batch(es) from sealed journal")
    end

    {:ok, %{state | replayed: replayed}}
  end

  @impl true
  def handle_call({:produce, topic, p, raw_batches, event_type}, _from, state) do
    reply =
      Enum.reduce(raw_batches, {:ok, 0, 0}, fn raw, acc ->
        case acc do
          {:ok, _, _} -> produce_one(state, topic, p, raw, event_type)
          e -> e
        end
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:replay_sealed, _from, state) do
    {:reply, do_replay_sealed(state), state}
  end

  # -- internals -----------------------------------------------------------------

  # VERBATIM from Kafka.Log produce_one, with the guard seam.
  defp produce_one(state, topic, p, raw, et) do
    case sieve(state.guard, raw) do
      {:admit, _} -> admit_one(state, topic, p, raw, et)
      {:andon, <<1::8, _len::16, reason::binary>>} -> {:error, {:policy_violation, reason}}
      {:andon, other} -> {:error, {:policy_violation, "guard-unresolved: " <> inspect(other)}}
    end
  end

  defp sieve(nil, _raw), do: {:admit, <<0::8>>}
  defp sieve({m, f, a}, raw), do: apply(m, f, [raw | a])

  # VERBATIM from Kafka.Log admit_one with the parser/store seams. The
  # `with` passthrough keeps parser refusals typed and direct
  # ({:error, :record_count_mismatch}, {:error, :too_short}, ...).
  defp admit_one(state, topic, p, raw, et) do
    with {:ok, count, records} <- parser(state.parser, raw) do
      base = high_watermark(state.tables, topic, p)
      {stored, count} = store_shape(raw, base, count)

      case JournalSink.append(state.sink, et, p, topic, stored) do
        {:ok, _seq} ->
          :ets.insert(batches_table(state), {{topic, p, base}, %{
            raw: stored,
            count: count,
            event_type: et
          }})

          :ets.insert(next_table(state), {{topic, p}, base + count})
          fan_out(state.fan_out, topic, p, records)
          {:ok, base, count}

        {:error, reason} ->
          # JournalSink degraded mode still answers {:ok, seq}; a hard
          # {:error,_} here is a sink-down face — typed refusal, never a
          # fake ack. (prose verbatim)
          {:error, {:journal_down, reason}}
      end
    end
  end

  # Store-shape law: kafka-batch-shaped inputs keep the AZ-1 store framing
  # verbatim (store_raw wrapper for legacy frames + broker-stamped base
  # offset); any other payload (AoQ passthrough face) stores BARE.
  defp store_shape(raw, base, count) do
    if kafka_batch_shape?(raw) do
      {raw |> store_raw(base) |> stamp_base_offset(base), count}
    else
      {raw, count}
    end
  end

  defp parser({m, f, a}, raw), do: apply(m, f, [raw | a])

  defp fan_out(nil, _topic, _p, _records), do: :ok
  defp fan_out({m, f, a}, topic, p, records), do: apply(m, f, [topic, p, records | a])

  # Kafka-batch shape dispatch (bytes-only, face-agnostic): a magic-2 batch
  # header, or a legacy magic-0/1 record frame.
  defp kafka_batch_shape?(<<_::binary-size(16), 2::integer-size(8), _::binary>>), do: true

  defp kafka_batch_shape?(<<_crc::unsigned-integer-size(32), m::integer-size(8), _::8, _::binary>>)
       when m in [0, 1],
       do: true

  defp kafka_batch_shape?(_), do: false

  # Patch the broker-assigned base offset into bytes 0..7. Uniform across
  # magics: a magic-2 batch's first 8 bytes are the baseOffset field; a
  # legacy magic-0/1 stored frame keeps its {offset, size} wrapper, whose
  # first 8 bytes are the offset field. The patch is CRC-neutral in both
  # layouts (neither CRC covers the wrapper/offset prefix), and the CRC
  # still verifies client-side on fetch-back. (prose verbatim)
  defp stamp_base_offset(raw, base) do
    <<_::binary-size(8), rest::binary>> = raw
    <<base::signed-integer-size(64), rest::binary>>
  end

  # Legacy magic-0/1 stored frames keep the {offset, size} wrapper so the
  # broker-assigned offset survives journal replay law byte-exact (the
  # stripped frame carries no offset field). Magic-2 batches carry the
  # offset field in the batch header itself and are stored bare. (verbatim)
  defp store_raw(<<_::binary-size(16), 2::integer-size(8), _::binary>> = raw, _base), do: raw

  defp store_raw(raw, base) do
    <<base::signed-integer-size(64), byte_size(raw)::unsigned-integer-size(32), raw::binary>>
  end

  # Record count out of a STORED raw (magic-2 batch or legacy wrapped
  # frame). (verbatim; the count dispatch rides the engine's own shape
  # check plus the Records counter)
  defp stored_count(<<_::binary-size(12), rest::binary>>) do
    case rest do
      <<_::binary-size(4), m::integer-size(8), _::binary>> when m in [0, 1, 2] ->
        Smalt.Messaging.Kafka.Records.count(rest)

      _ ->
        {:ok, 1}
    end
  end

  defp stored_count(_), do: {:ok, 1}

  defp do_replay_sealed(%{dir: dir, log_prefix: prefix} = state) do
    with {:ok, segs} <- JournalReader.discover_sealed_segments(dir) do
      Enum.reduce(segs, 0, fn seg, acc ->
        case JournalReader.read_sealed_segment(seg) do
          {:ok, frames} ->
            Enum.reduce(frames, acc, fn f, n ->
              if f.event_type == state.event_type, do: restore_frame(state, f, n + 1), else: n
            end)

          {:error, reason} ->
            # Sealed-reader integrity refusal is fail-closed upstream: a
            # refusal here logs typed and skips the segment — replay is
            # best-effort at boot because the reader already quarantined
            # completeness failures; integrity failures remain loud.
            # (prose verbatim)
            Logger.error(
              "[#{prefix}] sealed segment replay refused (#{Path.basename(seg)}): #{inspect(reason)}"
            )

            acc
        end
      end)
    end
  end

  defp restore_frame(state, f, n) do
    {batches, next} = state.tables
    base = base_offset_of(state, f)
    key = {f.key, f.table_id, base}

    count =
      case stored_count(f.payload) do
        {:ok, c} -> c
        _ -> 1
      end

    unless :ets.member(batches, key) do
      :ets.insert(batches, {key, %{raw: f.payload, count: count, event_type: f.event_type}})

      {t, q, base} = key
      cur = high_watermark(state.tables, t, q)
      if base + count > cur, do: :ets.insert(next, {{t, q}, base + count})
    end

    n
  end

  # Base-offset face of a stored frame (replay law, moduledoc): kafka-shaped
  # payloads carry the broker-stamped base in bytes 0..7 (verbatim); bare
  # payloads (AoQ face) carry none, so replay assigns the serve-order
  # offset — the current hwm of {topic, partition}.
  defp base_offset_of(state, f) do
    if kafka_batch_shape?(f.payload) do
      case f.payload do
        <<base::signed-integer-size(64), _::binary>> -> base
        _ -> 0
      end
    else
      high_watermark(state.tables, f.key, f.table_id)
    end
  end

  defp batches_table(state), do: elem(state.tables, 0)
  defp next_table(state), do: elem(state.tables, 1)

  defp table_pair(tables) when is_tuple(tables), do: tables
  defp table_pair(tables) when is_list(tables), do: {tables[:batches], tables[:next]}
end
