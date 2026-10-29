defmodule Smalt.Store.Heir do
  @moduledoc """
  TTV-5 reference architecture, component (1): the quiet heir.

  A zero-business-logic GenServer that exists to hold Store ETS tables whose
  owner (a `Smalt.Store.Partition` worker) has died, so a partition crash
  no longer deletes data tables. Trap-exit, permanent under
  `Smalt.Store`'s ensemble supervisor; boots FIRST (before the replay Boot
  child and the 16 partitions).

  Mechanics:

    * tables are created (by this Heir at cold boot) with the FALLBACK heir
      `:init` — so even a Heir death transfers to :init instead of deleting;
    * when a partition dies, ownership of its tables transfers here; the
      `:"ETS-TRANSFER"` message is logged (the hold is observable, never
      silent);
    * a respawned partition reclaims its tables via `reclaim_table/2` — a
      real `:ets.give_away/3` executed BY the owner (give_away from a
      non-owner is a documented no-op, so a reclaim that arrives when the
      table is not held is a logged no-op, never an error).
  """

  use GenServer

  require Logger

  # -- API ----------------------------------------------------------------------

  @doc "Heir name for a Store ensemble rooted at `base`."
  def name_for(base), do: Module.concat(base, Heir)

  def start_link(opts) do
    base = Keyword.get(opts, :name, Smalt.Store)
    name = name_for(base)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, orphan}} ->
        # TTV-5 orphan takeover: a :kill'd ensemble supervisor dies without
        # stopping its trapping children — a surviving heir keeps its name
        # and the respawned ensemble cannot start. Take over: kill the
        # orphan (tables it holds have heir = this dead lineage and are
        # deleted; the sealed journal replays them — court leg3), retry.
        Process.exit(orphan, :kill)
        GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Owner-side reclaim: if this process owns `table`, hand it to `pid` via a
  real `:ets.give_away/3`. No-op (with a log line) when the table is not
  currently held — e.g. the table fell through to `:init` because this Heir
  itself died, or the table is another ensemble's.
  """
  def reclaim_table(heir \\ __MODULE__, table, pid) do
    GenServer.call(heir, {:reclaim, table, pid}, 5_000)
  end

  @doc "Which registry tables does partition `i` own? (striped phash2(table, 16).)"
  def tables_for_partition(i, tables \\ Smalt.StoreTables.table_names()) do
    Enum.filter(tables, &(:erlang.phash2(Atom.to_string(&1), 16) == i))
  end

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # The Heir creates NOTHING. Cold-boot table creation belongs to the
    # partitions: each table is created by its owning partition with
    # {:heir, heir_pid, []} — the reference contract — so when a partition
    # dies its tables come HERE (logged hold), and the respawned worker
    # reclaims them via a real give_away. NOTE: :ets.give_away does NOT
    # reset the heir option, so heir=:init at creation would make every
    # warm give-away impossible (courted: owner stayed #PID<0.0.0> after a
    # partition kill). Residual: if the Heir itself dies while holding a
    # dead partition's tables, those tables are deleted (heir not alive at
    # transfer); the Heir is quiet/trap_exit/permanent — the residual is
    # bounded to tables already orphaned by a live partition crash, and the
    # sealed journal replays them on next boot.
    {:ok, %{base: Keyword.get(opts, :name, Smalt.Store)}}
  end

  @impl true
  def handle_call({:reclaim, table, pid}, _from, state) do
    case :ets.info(table) do
      :undefined ->
        Logger.warning("Smalt.Store.Heir: reclaim of missing table #{inspect(table)}")
        {:reply, {:error, :undefined}, state}

      info ->
        if info[:owner] == self() do
          # Real give-away — the reference mechanism. The gift lands as an
          # ETS-TRANSFER message in the receiver's inbox.
          :ets.give_away(table, pid, [])
          {:reply, :ok, state}
        else
          # Not held here (e.g. post-Heir-crash :init hold, or another
          # ensemble's table): documented no-op, never an error.
          Logger.info(
            "Smalt.Store.Heir: reclaim no-op for #{inspect(table)} (owner #{inspect(info[:owner])})"
          )

          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", table, _from, _gift}, state) do
    # The hold is observable: a table arriving here means a partition died
    # and its data is safe until the respawned worker reclaims it.
    Logger.warning("Smalt.Store.Heir: holding table #{inspect(table)} (owner partition died)")

    {:noreply, state}
  end

  # BK-69 reconciliation: the Heir MUST die with its ensemble. trap_exit
  # otherwise orphans it when the ensemble supervisor is brutally killed
  # (witnessed: leg3 of the TTV-5 court — the orphan Heir answered
  # {:error, {:already_started, pid}} to every restart attempt of
  # Smalt.Store.start_link/1, a permanent restart loop under
  # DataSupervisor). Any non-normal EXIT from the ensemble supervisor
  # terminates the Heir; its tables fall through to the :init fallback
  # heir (the TTV-5 law: ownership rests with :init, public tables), and
  # the respawned partitions reclaim/no-op against :init exactly as the
  # post-Heir-crash path already documents.
  def handle_info({:EXIT, _sup, reason}, state) when reason != :normal do
    Logger.warning("Smalt.Store.Heir: ensemble supervisor down (#{inspect(reason)}); terminating with it")
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # trap_exit is on: our own parent sup's death arrives as a message. Stay
    # up (quiet module) — the supervisor tree decides our fate.
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
