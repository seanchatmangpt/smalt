defmodule Smalt.Store.Partition do
  @moduledoc """
  TTV-5 reference architecture, component (2): partition workers.

  16 permanent GenServer workers under the `Smalt.Store` ensemble
  supervisor. The 35 registry tables are striped at the TABLE level:
  table `t` belongs to partition `:erlang.phash2(t, 16)`. All SERIALIZED
  write operations for table `t` (compare_and_swap, compare_and_swap_delete,
  insert_new, next_seq) route via that hash to the owning worker's
  handle_call — the same one-at-a-time guarantee the pre-partition single
  Store GenServer gave table `t`.

  Reads bypass the processes entirely (public tables). put/delete stay
  caller-side journaled direct-ETS.

  Init adopts: a table that already exists (Heir-held from a dead prior
  owner) is RECLAIMED via `Smalt.Store.Heir.reclaim_table/2` — a real
  give-away; a missing table (defensive only) is created heir'd to the Heir.
  """

  use GenServer

  require Logger

  @partitions 16

  def partitions, do: @partitions

  @doc "Partition worker name for ensemble `base`, stripe `i`."
  def name_for(base, i), do: Module.concat(base, :"Partition#{i}")

  @doc "The owning partition for a table (facade routing)."
  def owner_of(table), do: :erlang.phash2(Atom.to_string(table), @partitions)

  @doc "pid of the owning partition worker (ensemble `base`)."
  def whereis_owner(base, table), do: Process.whereis(name_for(base, owner_of(table)))

  def start_link(arg) do
    {base, i} = arg
    name = name_for(base, i)

    case GenServer.start_link(__MODULE__, {base, i}, name: name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, orphan}} ->
        # TTV-5 orphan takeover (see Smalt.Store.Heir): a :kill'd ensemble
        # supervisor can leave a child momentarily registered; the respawned
        # ensemble kills the orphan and starts fresh. (Tables heir'd to the
        # dead lineage are deleted and replay restores them.)
        Process.exit(orphan, :kill)
        GenServer.start_link(__MODULE__, {base, i}, name: name)
    end
  end

  @impl true
  def init({base, i}) do
    heir = Smalt.Store.Heir.name_for(base)
    assigned = Smalt.Store.Heir.tables_for_partition(i)

    Enum.each(assigned, fn table ->
      case :ets.info(table) do
        :undefined ->
          # Cold boot: the OWNING partition creates the table with
          # {:heir, heir_pid, []} (reference contract) — a later partition
          # crash hands the table to the Heir for the respawn to reclaim.
          # BK-82 unblock fix (compile-freeze SLA, disclosed in bk82 receipt):
          # whereis can return nil under boot-order race with the Heir —
          # {:heir, nil, []} is an invalid :ets option (ArgumentError).
          heir_opts =
            case Process.whereis(heir) do
              pid when is_pid(pid) -> [{:heir, pid, []}]
              _ -> []
            end

          :ets.new(table, [
            :ordered_set,
            :public,
            :named_table
          ] ++ heir_opts ++ [
            read_concurrency: true,
            write_concurrency: true
          ])

        _info ->
          :ok = Smalt.Store.Heir.reclaim_table(heir, table, self())
      end
    end)

    Logger.info("Smalt.Store.Partition #{i}: adopted #{length(assigned)} table(s)")
    {:ok, %{index: i, base: base}}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _gift}, state) do
    # Reclaim gifts from the Heir arrive here after init returned.
    {:noreply, state}
  end

  # The four serialized ops; the facade routed the message here via
  # phash2(table, 16), so all ops for table t serialize on this worker.

  @impl true
  def handle_call({:next_seq, table, key, seed_fun}, _from, state) do
    {:reply, bump_seq(table, key, seed_fun), state}
  end

  def handle_call({:cas, table, key, expect, new}, _from, state) do
    look = :ets.lookup(table, key)

    maybe_forensic({:cas, table, key, expect, new, look})

    reply =
      case look do
        [{^key, ^expect}] ->
          :ets.insert(table, {key, new})
          Smalt.Store.journal_mutation(Smalt.Store.journal_evt_put(), table, key, :erlang.term_to_binary(new))
          :ok

        _ ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end

  def handle_call({:insert_new, table, key, value}, _from, state) do
    reply =
      case :ets.lookup(table, key) do
        [] ->
          :ets.insert(table, {key, value})
          Smalt.Store.journal_mutation(Smalt.Store.journal_evt_put(), table, key, :erlang.term_to_binary(value))
          :ok

        _ ->
          {:error, :exists}
      end

    {:reply, reply, state}
  end

  def handle_call({:cas_delete, table, check_key, expect}, _from, state) do
    reply =
      case :ets.lookup(table, check_key) do
        [{^check_key, ^expect}] ->
          :ets.delete(table, check_key)
          Smalt.Store.journal_mutation(Smalt.Store.journal_evt_delete(), table, check_key, <<>>)
          :ok

        _ ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end

  defp bump_seq(table, key, seed_fun) do
    case :ets.lookup(table, key) do
      [{^key, n}] when is_integer(n) ->
        seq = n + 1
        :ets.insert(table, {key, seq})
        Smalt.Store.journal_mutation(Smalt.Store.journal_evt_put(), table, key, :erlang.term_to_binary(seq))
        seq

      _ ->
        seq = seed_fun.() + 1
        :ets.insert(table, {key, seq})
        Smalt.Store.journal_mutation(Smalt.Store.journal_evt_put(), table, key, :erlang.term_to_binary(seq))
        seq
    end
  end

  defp maybe_forensic(entry) do
    if Application.get_env(:smalt, :sentinel_forensic, false) do
      case :ets.info(:smalt_sentinel_forensic) do
        :undefined ->
          :ok

        _ ->
          :ets.insert(
            :smalt_sentinel_forensic,
            {System.unique_integer([:monotonic, :positive]), entry, self()}
          )
      end
    end
  end
end
