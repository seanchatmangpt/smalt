defmodule Smalt.Store.DetsMirror do
  @moduledoc """
  Opt-in poll-based :dets persistence mirror beside `Smalt.Store`.

  On a configurable interval the mirror reads each configured ETS table
  (read-only, `:ets.tab2list/1`) and upserts every `{key, value}` row into a
  per-table `:dets` file under `dir`. `restore/0` replays mirrored rows back
  into ETS, skipping keys already present — while the store is hot, ETS is the
  source of truth.

  **Drift window (honest limits)**: this is poll-based, not subscribe-based.
  Writes made within one sync interval before a crash are NOT mirrored and are
  lost on restore (up to `interval` of writes, plus rows deleted from ETS are
  never removed from the mirror — a restored table is a union, not a snapshot).
  Start `Smalt.Store` before the mirror: a mirror tick against a missing table
  is skipped and logged until the table appears.

  Usage:

      {:ok, pid} = Smalt.Store.DetsMirror.start_link(dir: "tmp/dets")
      Smalt.Store.DetsMirror.restore()

  Options:

    * `:dir` — directory for `.dets` files (default `"tmp/dets"`, created on start)
    * `:tables` — ETS tables to mirror (default: the 5 highest-value tables)
    * `:interval` — sync tick in ms (default `5_000`)
  """

  use GenServer
  require Logger

  # W1b projection: the mirror set is the generated registry (persisted rows,
  # lib/smalt/store_tables.ex). Equivalent to the hand-written list it
  # replaced; ledger_meta stays mirrored so a restore that replays
  # transactions does not 404 on enforce-existence meta rows. DO NOT
  # re-introduce a local list — regenerate with `mix smalt.gen`.
  @default_tables Smalt.StoreTables.persisted_tables()

  @default_interval 5_000
  @default_dir "tmp/dets"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    map = Map.new(opts)
    dir = Map.get(map, :dir, @default_dir)
    tables = Map.get(map, :tables, @default_tables)

    # Fail closed in the caller: validate every mirror file up front so a
    # corrupt :dets file raises a clear ArgumentError instead of taking the
    # mirror (or silently repairing) at runtime.
    Enum.each(tables, fn table ->
      path = Path.join(dir, "#{table}.dets")

      case :dets.open_file(make_ref(), file: to_charlist(path), repair: false) do
        {:ok, dets} ->
          :dets.close(dets)

        {:error, reason} ->
          raise ArgumentError,
                "DetsMirror: cannot open mirror file for table #{inspect(table)} " <>
                  "at #{path}: #{inspect(reason)}"
      end
    end)

    GenServer.start_link(__MODULE__, Map.put(map, :name, name), name: name)
  end

  @doc """
  Re-inserts mirrored rows into their ETS tables, skipping keys already
  present (idempotent; ETS wins while hot). Returns `{:ok, counts}` where
  counts maps table atom -> rows restored by this call.
  """
  @spec restore(GenServer.server()) :: {:ok, %{atom() => non_neg_integer()}}
  def restore(server \\ __MODULE__) do
    GenServer.call(server, :restore)
  end

  @doc """
  Forces an immediate sync of all mirrored tables to disk. Returns `:ok`.
  """
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__) do
    GenServer.call(server, :sync)
  end

  @impl true
  def init(opts) do
    dir = Map.get(opts, :dir, @default_dir)
    tables = Map.get(opts, :tables, @default_tables)
    interval = Map.get(opts, :interval, @default_interval)
    File.mkdir_p!(dir)

    case open_all(tables, dir) do
      {:ok, dets} ->
        Process.send_after(self(), :tick, interval)
        {:ok, %{dets: dets, interval: interval}}

      {:error, _} = err ->
        {:stop, err}
    end
  end

  defp open_all(tables, dir) do
    Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, acc} ->
      path = Path.join(dir, "#{table}.dets")

      case :dets.open_file(table, file: to_charlist(path), repair: false) do
        {:ok, dets} ->
          {:cont, {:ok, Map.put(acc, table, dets)}}

        {:error, reason} ->
          {:halt, {:error, {:corrupt_mirror, table, path, reason}}}
      end
    end)
  end

  @impl true
  def handle_info(:tick, state) do
    sync_all(state.dets)
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    sync_all(state.dets)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:restore, _from, state) do
    counts =
      Map.new(state.dets, fn {table, dets} ->
        {table, restore_table(table, dets)}
      end)

    {:reply, {:ok, counts}, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.dets, fn {_table, dets} ->
      :dets.close(dets)
    end)

    :ok
  end

  defp sync_all(dets) do
    Enum.each(dets, fn {table, dets_file} ->
      case :ets.info(table) do
        :undefined ->
          Logger.warning("DetsMirror: ETS table #{inspect(table)} missing, skipping sync")

        _ ->
          rows = :ets.tab2list(table)

          # Bounded-growth fence (SHIM-COURT census: test/store_dets_growth_test.exs):
          # the mirror is a PROJECTION of the live ETS table, not a historical
          # union — keys deleted from ETS are deleted from the mirror on the
          # next sync, so mirror size tracks live size and restore never
          # resurrects deleted rows. A bare :dets.insert upsert-union leaked
          # 100/200 stale rows in the census falsifier.
          live_keys = MapSet.new(rows, fn {key, _val} -> key end)

          stale =
            dets_file
            |> :dets.match_object(:_)
            |> Enum.map(fn {key, _val} -> key end)
            |> Enum.reject(&MapSet.member?(live_keys, &1))

          Enum.each(stale, &:dets.delete(dets_file, &1))
          :dets.insert(dets_file, rows)
          :dets.sync(dets_file)
      end
    end)

    :ok
  end

  defp restore_table(table, dets_file) do
    if :ets.info(table) == :undefined do
      Logger.warning("DetsMirror: ETS table #{inspect(table)} missing, cannot restore")
      0
    else
      dets_file
      |> :dets.match_object(:_)
      |> Enum.reduce(0, fn {key, val}, n ->
        # Idempotent: ETS is source of truth while hot; never clobber a live
        # row. The exists-check AND the insert must run as ONE Store
        # handle_call — a bare :ets.lookup-then-:ets.insert here raced with a
        # concurrent Smalt.Store.insert_new/3 and could clobber the fresh
        # value with a stale mirror value (lens-3 cycle-4 court kills that
        # interleaving; the old non-atomic form failed the court).
        case Smalt.Store.insert_new(table, key, val) do
          :ok -> n + 1
          {:error, :exists} -> n
        end
      end)
    end
  end
end
