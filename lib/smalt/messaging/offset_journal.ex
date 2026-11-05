defmodule Smalt.Messaging.OffsetJournal do
  @moduledoc """
  Durable offset and cursor checkpointing for sovereign cloud peripheral parity (v26.11.4).

  Satisfies ADR-PRD-SMALT-26.11.4 §6:
    - Kafka: OffsetCommitRequest maps to {Group, Topic, Partition} -> Offset
    - Kinesis: Checkpoints stored as {Stream, ShardId} -> SequenceNumber
    - GCP Pub/Sub: Acknowledge calls advance {Project, Subscription} -> AckCursor

  Persistence Backend:
    - Synchronous journal append to `priv/data/offsets.journal` (append-only binary log)
    - Synchronous mirror to DETS table `:smalt_offset_checkpoints_dets`
    - Replay on process boot to restore memory cursors and ETS tables across node crash/restart
  """

  use GenServer
  require Logger

  @ets_table :smalt_offset_checkpoints
  @dets_table :smalt_offset_checkpoints_dets
  @magic 0x4F464653 # "OFFS"

  defstruct [:journal_fd, :journal_path, :dets_file]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Commits an offset for a given dialect and partition tuple synchronously with fsync.
  """
  @spec commit(atom() | String.t(), String.t(), String.t(), integer(), integer(), binary() | nil) :: :ok
  def commit(dialect, group, topic, partition, offset, receipt \\ nil) do
    GenServer.call(__MODULE__, {:commit, to_string(dialect), to_string(group), to_string(topic), partition, offset, receipt}, 15_000)
  end

  @doc """
  Fetches the latest committed offset for a partition.
  """
  @spec fetch(atom() | String.t(), String.t(), String.t(), integer()) :: {:ok, integer()} | :not_found
  def fetch(dialect, group, topic, partition) do
    key = {to_string(dialect), to_string(group), to_string(topic), partition}
    case :ets.lookup(@ets_table, key) do
      [{^key, {_dialect, _group, _topic, _part, offset, _epoch, _receipt}}] ->
        {:ok, offset}

      _ ->
        case :dets.lookup(@dets_table, key) do
          [{^key, {_dialect, _group, _topic, _part, offset, _epoch, _receipt}}] ->
            {:ok, offset}

          _ ->
            :not_found
        end
    end
  end

  @doc """
  Returns all kafka offset records: {{group, topic, partition}, offset}
  Used to rehydrate Smalt.Messaging.Kafka.GroupManager on startup.
  """
  @spec restore_kafka_offsets() :: list({{String.t(), String.t(), integer()}, integer()})
  def restore_kafka_offsets do
    GenServer.call(__MODULE__, :restore_kafka_offsets, 15_000)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir) || Application.get_env(:smalt, :offset_journal_dir) || default_data_dir()
    File.mkdir_p!(data_dir)

    journal_path = Path.join(data_dir, "offsets.journal")
    dets_path = Path.join(data_dir, "offsets.dets")

    # Create in-memory ETS cache
    if :ets.info(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Open or repair DETS table.  # KD-COVERS: KD-190
    # After kill -9 the DETS header can be left
    # truncated/corrupt; repair: true lets DETS auto-repair instead of
    # crashing on first reopen (witnessed kill -9 makes first reopen
    # corrupt-header-prone). Lossless: the journal replay below is
    # authoritative and re-writes every checkpoint after the reopen.
    {:ok, _} =
      :dets.open_file(@dets_table,
        file: String.to_charlist(dets_path),
        type: :set,
        repair: true
      )

    # Open journal for append
    {:ok, fd} = :file.open(String.to_charlist(journal_path), [:append, :raw, :binary])

    state = %__MODULE__{
      journal_fd: fd,
      journal_path: journal_path,
      dets_file: dets_path
    }

    # Replay existing journal on boot
    replayed = replay_journal(journal_path)
    Logger.info("[offset_journal] boot replay restored #{replayed} checkpoint records from #{journal_path}")

    {:ok, state}
  end

  @impl true
  def handle_call({:commit, dialect, group, topic, partition, offset, receipt}, _from, state) do
    epoch = System.system_time(:nanosecond)
    tag = receipt || compute_receipt(dialect, group, topic, partition, offset, epoch)

    key = {dialect, group, topic, partition}
    val = {dialect, group, topic, partition, offset, epoch, tag}

    # 1. Update ETS
    :ets.insert(@ets_table, {key, val})

    # 2. Update DETS
    :dets.insert(@dets_table, {key, val})

    # 3. Append to disk journal with fsync
    frame = encode_frame(dialect, group, topic, partition, offset, epoch, tag)
    :ok = :file.write(state.journal_fd, frame)
    :ok = :file.datasync(state.journal_fd)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:restore_kafka_offsets, _from, state) do
    records =
      :ets.foldl(
        fn {{dialect, group, topic, partition}, {_d, _g, _t, _p, offset, _epoch, _receipt}}, acc ->
          if dialect == "kafka" do
            [{{group, topic, partition}, offset} | acc]
          else
            acc
          end
        end,
        [],
        @ets_table
      )

    {:reply, records, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.journal_fd, do: :file.close(state.journal_fd)
    :dets.close(@dets_table)
    :ok
  end

  # Helpers

  defp default_data_dir do
    try do
      Application.app_dir(:smalt, "priv/data")
    rescue
      _ -> Path.expand("priv/data", File.cwd!())
    end
  end

  defp encode_frame(dialect, group, topic, partition, offset, epoch, receipt) do
    d_bin = :erlang.term_to_binary(dialect)
    g_bin = :erlang.term_to_binary(group)
    t_bin = :erlang.term_to_binary(topic)
    r_bin = if is_binary(receipt) and byte_size(receipt) == 16, do: receipt, else: :crypto.strong_rand_bytes(16)

    payload = <<
      byte_size(d_bin)::16, d_bin::binary,
      byte_size(g_bin)::16, g_bin::binary,
      byte_size(t_bin)::16, t_bin::binary,
      partition::signed-32,
      offset::signed-64,
      epoch::signed-64,
      r_bin::binary-size(16)
    >>

    crc = :erlang.crc32(payload)
    <<@magic::32, byte_size(payload)::32, crc::32, payload::binary>>
  end

  defp replay_journal(path) do
    case File.read(path) do
      {:ok, binary} -> parse_and_load_frames(binary, 0)
      {:error, _} -> 0
    end
  end

  defp parse_and_load_frames(<<@magic::32, len::32, crc::32, payload::binary-size(len), rest::binary>>, count) do
    if :erlang.crc32(payload) == crc do
      case decode_payload(payload) do
        {:ok, dialect, group, topic, partition, offset, epoch, receipt} ->
          key = {dialect, group, topic, partition}
          val = {dialect, group, topic, partition, offset, epoch, receipt}
          :ets.insert(@ets_table, {key, val})
          :dets.insert(@dets_table, {key, val})
          parse_and_load_frames(rest, count + 1)

        :error ->
          parse_and_load_frames(rest, count)
      end
    else
      parse_and_load_frames(rest, count)
    end
  end

  defp parse_and_load_frames(_truncated_or_empty, count), do: count

  defp decode_payload(<<
    d_len::16, d_bin::binary-size(d_len),
    g_len::16, g_bin::binary-size(g_len),
    t_len::16, t_bin::binary-size(t_len),
    partition::signed-32,
    offset::signed-64,
    epoch::signed-64,
    receipt::binary-size(16)
  >>) do
    try do
      dialect = :erlang.binary_to_term(d_bin)
      group = :erlang.binary_to_term(g_bin)
      topic = :erlang.binary_to_term(t_bin)
      {:ok, dialect, group, topic, partition, offset, epoch, receipt}
    rescue
      _ -> :error
    end
  end

  defp decode_payload(_), do: :error

  defp compute_receipt(dialect, group, topic, partition, offset, epoch) do
    content = "#{dialect}:#{group}:#{topic}:#{partition}:#{offset}:#{epoch}"
    # 16-byte BLAKE3 receipt tag (falls back to SHA256[0..15] if blake3 NIF absent)
    # apply/3: Smalt.Security.Blake3 is an optional runtime-loaded module, so
    # the probe must stay dynamic (compile-time remote call warns under WIP).
    case :erlang.function_exported(Smalt.Security.Blake3, :hash16, 1) do
      true -> apply(Smalt.Security.Blake3, :hash16, [content])
      false -> :binary.part(:crypto.hash(:sha256, content), 0, 16)
    end
  end
end
