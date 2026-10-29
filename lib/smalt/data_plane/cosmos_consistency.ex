defmodule Smalt.DataPlane.CosmosConsistency do
  @moduledoc """
  Cosmos DB database-account consistency face (wave-6 lane w6bj).

  Account-level `defaultConsistency` (Strong | BoundedStaleness | Session |
  ConsistentPrefix | Eventual), per-request `x-ms-consistency-level`
  override admission, and session-token header helpers riding the existing
  LSN counters (`:smalt_cosmos_lsn` — reused, not duplicated).

  Admission law (real-Cosmos parity): a Strong account forces Strong on
  every request; under any weaker default, any override is admitted.
  """

  @table :smalt_cosmos_consistency
  @lsn_table :smalt_cosmos_lsn
  @key :account

  @levels [:strong, :bounded_staleness, :session, :consistent_prefix, :eventual]

  def wire(:strong), do: "Strong"
  def wire(:bounded_staleness), do: "BoundedStaleness"
  def wire(:session), do: "Session"
  def wire(:consistent_prefix), do: "ConsistentPrefix"
  def wire(:eventual), do: "Eventual"

  defp level_atom(level) do
    case Enum.find(@levels, fn a -> wire(a) == level end) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  @doc "Set the account default. :ok | {:error, 400, code, message}."
  def set_default(level) when is_atom(level) do
    if level in @levels, do: do_set(level), else: {:error, 400, "BadRequest", msg(level)}
  end

  def set_default(level) when is_binary(level) do
    case level_atom(level) do
      {:ok, atom} -> do_set(atom)
      :error -> {:error, 400, "BadRequest", msg(level)}
    end
  end

  defp do_set(level) do
    ensure_table()
    :ets.insert(@table, {@key, level})
    :ok
  end

  @doc "Current account default (atom). Real-Cosmos default when unset: :session."
  def default() do
    ensure_table()
    case :ets.lookup(@table, @key) do
      [] -> :session
      [{@key, level}] -> level
    end
  end

  @doc """
  Admission check for a per-request x-ms-consistency-level override.
  Law: a Strong account forces Strong; under any weaker default any
  override is admitted. :ok | {:error, 400, code, message}.
  """
  def check_override(nil), do: :ok

  def check_override(header_value) when is_binary(header_value) do
    default_level = default()

    cond do
      default_level == :strong ->
        case level_atom(header_value) do
          {:ok, :strong} -> :ok
          _ ->
            {:error, 400, "BadRequest",
             "The requested consistency level is not compatible with the " <>
               "Strong account default consistency level."}
        end

      true ->
        :ok
    end
  end

  @doc "Admission check from a request header map (tolerates nil map)."
  def check_override_headers(headers) when is_map(headers) do
    check_override(headers["x-ms-consistency-level"] || headers[:"x-ms-consistency-level"])
  end

  def check_override_headers(_), do: :ok

  @doc """
  Session-token headers from the real LSN counter (`:smalt_cosmos_lsn`,
  shared with Cosmos' own session work — reused, not duplicated).
  """
  def session_token_headers(db, coll) when is_binary(db) and is_binary(coll) do
    lsn = lsn(db, coll)
    %{"x-ms-session-token" => "1##{lsn}", "x-ms-lsn" => Integer.to_string(lsn)}
  end

  @doc "Advance and return the collection LSN (write-path hook)."
  def advance_lsn(db, coll) when is_binary(db) and is_binary(coll) do
    if store_ready?() do
      Smalt.Store.update_counter(@lsn_table, "#{db}/#{coll}")
    else
      0
    end
  end

  @doc "Current LSN without advancing."
  def current_lsn(db, coll) when is_binary(db) and is_binary(coll) do
    if store_ready?() do
      Smalt.Store.current_counter(@lsn_table, "#{db}/#{coll}")
    else
      0
    end
  end

  defp lsn(db, coll), do: current_lsn(db, coll)

  defp store_ready? do
    match?({:ok, _pid}, Smalt.Store.start_link([])) or Process.whereis(Smalt.Store) != nil
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        {:read_concurrency, true},
        {:heir, Process.whereis(:init), []}
      ])
    end

    :ok
  end

  defp msg(level), do: "The requested consistency level '#{to_string(level)}' is not supported."
end
