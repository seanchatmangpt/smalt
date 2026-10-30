defmodule Smalt.Policy.Store do

  @moduledoc """
  ETS lifecycle for the policy/RBAC shadow tables — the lazy-table law.

  Two ETS tables (same fail-closed conventions as Smalt.Store):

  - `:smalt_policy` — policy definitions, set definitions, assignments,
    exemptions, locks, remediations, and receipt rows (nc:/exr:/rem:/rs:)
    in one :set table.
  - `:smalt_rbac` — role assignments (`ra:<lower id>`).
  """

  # ===========================================================================
  # ETS lifecycle (lazy, named, public — same pattern as the router's rate
  # table; the Store GenServer does not own these tables)
  # ===========================================================================

  @doc false
  def ensure_tables do
    for table <- [:smalt_policy, :smalt_rbac] do
      if :ets.info(table) == :undefined do
        try do
          :ets.new(table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true},
            # Shadow-table law (PW lane, wire witness 2026-10-19): these tables
            # are NOT in Store's boot list (StoreTables.shadow_tables), so the
            # first creator can be a Bandit request task — without an heir the
            # table DIES with that request process and every later request sees
            # a fresh store (witnessed: PUT 201 then GET 404 on the same beam).
            # Heir to :init (permanent, node-local) makes the table outlive its
            # creator; ensure_tables' ArgumentError rescue keeps the create race
            # fail-safe when several requests race the first insert.
            {:heir, Process.whereis(:init), []}
          ])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    :ok
  end

  @doc "Test seam: drop every policy/RBAC row (called from test setup)."
  def reset_for_test do
    ensure_tables()

    for table <- [:smalt_policy, :smalt_rbac] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end
  # ===========================================================================

  @doc """
  Expiry clock, overridable in tests via
  `Application.put_env(:smalt, :policy_now_ms, ms)`.
  """
  def now_ms do
    Application.get_env(:smalt, :policy_now_ms) ||
      DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  end
end
