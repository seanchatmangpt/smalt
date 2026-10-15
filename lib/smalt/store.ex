defmodule Smalt.Store do
  @moduledoc """
  In-memory ETS backed storage for ARM resources, Cosmos docs, Key Vault items,
  immutable Blob storage, Confidential Ledger Merkle transactions, and event topics.

  All tables are `:ordered_set` with lowercased full ARM id strings as keys, so
  `list_prefix/2` scans are deterministic and TF-stable.
  """
  use GenServer

  @tables [
    :smalt_subscriptions,
    :smalt_resource_groups,
    :smalt_resources,
    :smalt_operations,
    :smalt_cosmos_docs,
    :smalt_cosmos_lsn,
    :smalt_cosmos_pk_meta,
    :smalt_vault_keys,
    :smalt_blobs,
    :smalt_blob_containers,
    :smalt_blob_policy,
    :smalt_ledger_transactions,
    :smalt_ledger_meta,
    :smalt_event_messages,
    :smalt_sb_queues,
    :smalt_sb_messages,
    :smalt_sb_locks,
    :smalt_sb_sessions,
    :smalt_sb_tokens,
    :smalt_eh_partitions,
    :smalt_eh_checkpoints,
    :smalt_sentinel_streams,
    :smalt_sentinel_rows,
    :smalt_purview_entities,
    :smalt_purview_edges,
    :smalt_resource_graph_tokens,
    :smalt_attestation_baseline
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Enum.each(@tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [
          :ordered_set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])
      end
    end)

    # Seed default subscription
    default_sub = "00000000-0000-0000-0000-000000000000"

    :ets.insert(
      :smalt_subscriptions,
      {default_sub,
       %{
         "id" => "/subscriptions/#{default_sub}",
         "subscriptionId" => default_sub,
         "displayName" => "Sovereign Smalt Subscription",
         "state" => "Enabled"
       }}
    )

    {:ok, %{}}
  end

  @doc """
  Atomic insert-only: the exists-check AND the insert run as ONE
  `handle_call` inside the Store GenServer. Returns `:ok` or
  `{:error, :exists}` — the create-on-existing-id silent overwrite (measured
  201-with-overwrite; real Cosmos 409 Conflict) is structurally impossible.
  Unknown table raises in the caller, same fail-closed contract as CAS.
  """
  def insert_new(table, key, value) do
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.insert_new/3: unknown table #{inspect(table)}"
    end

    GenServer.call(__MODULE__, {:insert_new, table, key, value})
  end

  def put(table, key, value) do
    :ets.insert(table, {key, value})
    :ok
  end

  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :error
    end
  end

  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc """
  Lists all values in `table` in key order (deterministic, TF-stable).
  Entries deleted mid-walk are skipped (churn-safe).
  """
  def list(table) do
    table
    |> keys()
    |> Enum.flat_map(fn key ->
      case :ets.lookup(table, key) do
        [{^key, val}] -> [val]
        _ -> []
      end
    end)
  end

  @doc """
  Bounded `:ordered_set` scan: returns all values whose keys sort between
  `prefix` (inclusive) and `prefix <> <<0xFF>>` (exclusive of the bound itself).
  Entries deleted mid-walk are skipped (churn-safe).
  """
  def list_prefix(table, prefix) when is_binary(prefix) do
    table
    |> prefix_keys(prefix)
    |> Enum.flat_map(fn key ->
      case :ets.lookup(table, key) do
        [{^key, val}] -> [val]
        _ -> []
      end
    end)
  end

  @doc """
  Returns the sorted keys of `table` (full walk for keys/1, bounded for prefix_keys/2).
  """
  @spec keys(atom) :: [term]
  def keys(table) do
    prefix_keys(table, "")
  end

  @doc false
  def prefix_keys(table, prefix) when is_binary(prefix) do
    # Walk from the table start and filter. Erlang term order puts ALL tuples
    # below every binary, so a prev(prefix) seek skips tuple-keyed rows;
    # table sizes here are small and a full ordered walk is deterministic.
    upper = prefix <> <<0xFF>>

    table
    |> ordered_walk(:ets.first(table), [])
    |> Enum.reverse()
    |> Enum.filter(fn key -> key >= prefix and key < upper end)
  end

  defp ordered_walk(_table, :"$end_of_table", acc), do: acc

  defp ordered_walk(table, key, acc) do
    ordered_walk(table, :ets.next(table, key), [key | acc])
  end

  def clear do
    Enum.each(@tables, fn table ->
      if :ets.info(table) != :undefined do
        :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  @doc """
  Serialized compare-and-swap: lookup+insert runs inside the Store GenServer
  so exactly one concurrent caller wins. Returns :ok | {:error, :conflict}.
  """
  def compare_and_swap(table, key, expect, new) do
    # Fail closed in the CALLER: an unknown table must raise here, not inside
    # handle_call — an :ets.lookup on a missing table would crash the shared
    # Store GenServer (named ETS tables die with it; a restart loses data).
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.compare_and_swap/4: unknown table #{inspect(table)}"
    end

    GenServer.call(__MODULE__, {:cas, table, key, expect, new})
  end

  @doc """
  Atomic compare-and-DELETE: the etag check AND the delete run as ONE
  `handle_call` inside the Store GenServer, so N concurrent conditional
  deletes with the same etag yield exactly one `:ok` and N-1
  `{:error, :conflict}` — the read-check-delete TOCTOU that let two racing
  conditional deletes both return 204 is structurally impossible, matching
  the guarantee `compare_and_swap/4` gives the replace path.
  """
  def compare_and_swap_delete(table, key, expect) do
    # Same fail-closed contract as compare_and_swap/4.
    if :ets.info(table) == :undefined do
      raise ArgumentError, "Smalt.Store.compare_and_swap_delete/3: unknown table #{inspect(table)}"
    end

    GenServer.call(__MODULE__, {:cas_delete, table, key, expect})
  end

  @doc """
  Atomic init-and-increment counter (ETS update_counter with default 0).
  Returns the new value.
  """
  def update_counter(table, key, incr \\ 1) do
    :ets.update_counter(table, key, incr, {key, 0})
  end

  def current_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  @impl true
  def handle_call({:cas, table, key, expect, new}, _from, state) do
    reply =
      case :ets.lookup(table, key) do
        [{^key, ^expect}] ->
          :ets.insert(table, {key, new})
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
          :ok

        _ ->
          {:error, :exists}
      end

    {:reply, reply, state}
  end

  def handle_call({:cas_delete, table, check_key, expect}, _from, state) do    reply =
      :ets.lookup(table, check_key)
      |> case do
        [{^check_key, ^expect}] ->
          :ets.delete(table, check_key)
          :ok

        _ ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end
end
