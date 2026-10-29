defmodule Smalt.Sync.Store do
  @moduledoc """
  ATH-1 committed-frame table: a namespaced GENERIC ETS table
  (`:smalt_sync_frames`, `:ordered_set`, keys are opaque 16-byte binaries
  `<<client_id::64, seq::64>>`) with the same CAS law as `Smalt.Store`:
  the last-seq check AND the insert run as ONE serialized `handle_call` in
  this GenServer, so two racing batches cannot both admit the same seq.

  Per-client meta row (8-byte key `<<client_id::64>>`) carries
  `{:sync_meta, last_seq, chain}` — the seq baseline plus the running
  sha256-chain state (`Smalt.Sync.Receipt.chain()`).

  Journaling: when `:smalt, :journal_sink_dir` is configured, every commit
  appends via the existing `Smalt.Storage.JournalSink` under the sync
  event code `0x0A03` (disjoint from Store's 0x0A01/0x0A02 and the
  OcelEmitter codes; replay filters by event type). Fail-safe log-drop law
  identical to `Smalt.Store.journal_mutation/3`: a sink failure never
  crashes the data plane.

  Documented deviation: `Smalt.Store` only admits tables from the
  ggen-projected `Smalt.StoreTables` registry (hand-editing the generated
  registry is banned), so the sync table is namespaced under the sync
  subsystem with Store-identical CAS/journal semantics rather than living
  inside the Store GenServer itself.
  """

  use GenServer

  require Logger

  @table :smalt_sync_frames
  @journal_evt_sync 0x0A03

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ensures the singleton is up (idempotent; safe from any process). UNLINKED
  start on purpose: the first caller is a short-lived Bandit request process
  — a start_link there would kill the store (and its ETS) when that process
  exits. Documented deviation: not in the supervision tree (the tree is
  shared-lane contention); a crash loses the table and the next ensure/0
  restarts it empty.
  """
  def ensure do
    case GenServer.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> other
        end

      _pid ->
        :ok
    end
  end

  @doc "The ETS table name."
  def table, do: @table

  @doc "Row count — the courts' zero-mutation assertion face."
  def row_count do
    ensure()

    case :ets.info(@table) do
      :undefined -> 0
      info -> Keyword.get(info, :size, 0)
    end
  end

  @doc """
  Serialized CAS commit for one admitted frame: refuses `seq <= last_seq`
  for the client (typed `{:error, :seq_regression}`), else inserts
  `<<client_id::64, seq::64>> -> wire_bytes` and advances the meta row
  (last_seq + running sha256-chain). Returns
  `{:ok, %{seq:, last_seq:, chain:}}`.

  E8-T7 guard tightening: `client_id`/`seq` must be non-negative integers
  and `frame_wire` a binary — a negative seq would build `<<seq::64>>`
  ArgumentError-side (crashing the CAS GenServer) and a non-binary wire
  would raise inside `:crypto.hash`; both refuse typed instead.
  """
  def commit(client_id, seq, frame_wire)
      when is_integer(client_id) and client_id >= 0 and is_integer(seq) and seq >= 0 and
             is_binary(frame_wire) do
    ensure()
    GenServer.call(__MODULE__, {:commit, client_id, seq, frame_wire}, 5_000)
  end

  @doc """
  Per-client head: `{:ok, last_seq, chain}` — `last_seq` 0 and
  `Smalt.Sync.Receipt.empty_chain()` when the client has no commits.
  """
  def baseline(client_id) do
    ensure()

    case :ets.lookup(@table, <<client_id::64>>) do
      [{_, {:sync_meta, last_seq, chain}}] -> {:ok, last_seq, chain}
      [] -> {:ok, 0, Smalt.Sync.Receipt.empty_chain()}
    end
  end

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.info(@table) == :undefined do
      # SPOF-B / A-4: heir 3-tuple (shadow-table law, EhThrottle idiom) — a
      # crash/exit of the owner (or its unlinked starter's process class) no
      # longer silently wipes the sync frame table; it transfers to :init and
      # the next ensure/0 re-adopts it with the data intact.
      heir = Process.whereis(:init) || self()

      :ets.new(@table, [
        :ordered_set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true,
        heir: heir
      ])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:commit, client_id, seq, frame_wire}, _from, state) do
    {last_seq, chain} =
      case :ets.lookup(@table, <<client_id::64>>) do
        [{_, {:sync_meta, ls, ch}}] -> {ls, ch}
        [] -> {0, Smalt.Sync.Receipt.empty_chain()}
      end

    if seq <= last_seq do
      {:reply, {:error, :seq_regression}, state}
    else
      key = <<client_id::64, seq::64>>
      :ets.insert(@table, {key, frame_wire})

      new_chain = Smalt.Sync.Receipt.absorb(chain, frame_wire)
      :ets.insert(@table, {<<client_id::64>>, {:sync_meta, seq, new_chain}})

      journal(key, frame_wire)
      {:reply, {:ok, %{seq: seq, last_seq: seq, chain: new_chain}}, state}
    end
  end

  defp journal(key, frame_wire) do
    case Application.get_env(:smalt, :journal_sink_dir) do
      nil ->
        :ok

      _dir ->
        try do
          {:ok, _seq} =
            Smalt.Storage.JournalSink.append(
              Smalt.Storage.JournalSink,
              @journal_evt_sync,
              0,
              key,
              frame_wire
            )

          :ok
        rescue
          e -> log_drop("journal append dropped: " <> Exception.message(e))
        catch
          :exit, _ -> log_drop("journal append dropped (sink down)")
        end
    end
  end

  defp log_drop(msg) do
    Logger.warning("Smalt.Sync.Store: " <> msg)
    :ok
  end
end
