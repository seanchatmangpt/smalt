defmodule SmaltTest.Store do
  @moduledoc """
  Canonical resilient shared-Store setup (v26.10.18). One implementation of
  the i21/i22 hardening: the window between `Lifecycle.ensure_store_up()`
  and `Store.clear/0` races an async sibling's shared-tree teardown; the
  named ETS tables die mid-clear (dead-table ArgumentError). Built ON
  AssertEventually so the tree has exactly one bounded-retry primitive.
  """

  import SmaltTest.AssertEventually, only: [eventually: 2]

  @dead_table_msg "table identifier does not refer to an existing ETS table"

  @doc "Clear the shared Store, retrying only the dead-table ArgumentError."
  @spec resilient_clear(keyword) :: :ok
  def resilient_clear(opts \\ []) do
    eventually(
      fn ->
        SmaltTest.Lifecycle.ensure_store_up()
        Smalt.Store.clear()

        case Keyword.get(opts, :post_seed) do
          nil ->
            {:ok, :cleared}

          # seed runs INSIDE the retry window — c1_arm's rescue-scope law
          seed ->
            seed.()
            {:ok, :seeded}
        end
      end,
      observable: "shared Store clear(+seed)",
      retry_on: {ArgumentError, @dead_table_msg}
    )

    :ok
  end

  @doc """
  Canonical store setup for a suite: resilient_clear + optional seed.
  Replaces the bare `ensure_store_up(); Store.clear()` setups that produced
  FLAKE_LEDGER F2-F5/F10.
  """
  @spec resilient_setup(keyword) :: :ok
  def resilient_setup(opts \\ []) do
    :ok = resilient_clear(opts)
    :ok
  end

  @doc """
  i22 double-read law (shacl_fuzz snapshot mechanism, generalized): retry
  until two consecutive reads agree — a torn read under concurrent mutation
  is discarded, only quiescent observations are returned. Bounded by
  AssertEventually's deadline; rescues the dead-table ArgumentError and
  GenServer exits via the same retry_on machinery (wrapped as ordinary
  retries inside `read_fun`).
  """
  @spec quiescent_read((-> term), keyword) :: term
  def quiescent_read(read_fun, opts \\ []) do
    eventually(
      fn ->
        a = read_fun.()
        b = read_fun.()

        if a == b do
          {:ok, b}
        else
          {:retry, {:torn, a, b}}
        end
      end,
      Keyword.merge([observable: "quiescent read"], opts)
    )
  end
end
