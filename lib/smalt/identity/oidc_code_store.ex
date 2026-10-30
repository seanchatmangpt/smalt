defmodule Smalt.Identity.OidcCodeStore do
  @moduledoc """
  Lazy shadow ETS store for issued-but-unredeemed authorization codes
  (T05 scope: /authorize lands in a later lane; codes are seeded directly
  through `insert/2` — court-visible, honest standing).

  The table is created lazily under a :global trans lock and uses
  `heir: :init` so codes survive the death of the creating process.
  Single-use is atomic via `:ets.take`.
  """

  @table :smalt_oidc_codes

  @doc """
  Seeds an authorization code. `attrs` carries `client_id`, `redirect_uri`,
  optional `code_challenge` / `code_challenge_method` ("S256" or "plain"),
  `sub`, `tenant`, `nonce`.
  """
  @spec insert(String.t(), map()) :: :ok
  def insert(code, attrs) when is_binary(code) and byte_size(code) > 0 do
    ensure_table()
    now = System.system_time(:second)

    record =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"code" => code, "inserted_at" => now, "used" => false})

    :ets.insert(@table, {code, record})
    :ok
  end

  @doc """
  Atomically consumes a code (take-and-delete, single-use).
  Returns `{:ok, record}` or `{:error, :unknown_code}`.
  """
  @spec take(String.t()) :: {:ok, map()} | {:error, :unknown_code}
  def take(code) when is_binary(code) do
    ensure_table()

    case :ets.take(@table, code) do
      [{^code, record}] -> {:ok, record}
      [] -> {:error, :unknown_code}
    end
  end

  @doc """
  Non-destructive peek (courts and diagnostics; never consumes).
  """
  @spec peek(String.t()) :: {:ok, map()} | {:error, :unknown_code}
  def peek(code) when is_binary(code) do
    ensure_table()

    case :ets.lookup(@table, code) do
      [{^code, record}] -> {:ok, record}
      [] -> {:error, :unknown_code}
    end
  end

  @doc "Number of stored codes."
  @spec count() :: non_neg_integer()
  def count do
    ensure_table()
    :ets.info(@table, :size)
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      create_table()
    end
  end

  defp create_table do
    :global.trans({{__MODULE__, :table_lock}, node()}, fn ->
      if :ets.whereis(@table) == :undefined do
        # `{:heir, :init, nil}` (atom shorthand) is refused by erts-17.1
        # option validation ("invalid options"); the same semantics — heir
        # to the init process — hold by handing the real pid.
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), nil}
        ])
      end
    end)

    :ok
  end
end
