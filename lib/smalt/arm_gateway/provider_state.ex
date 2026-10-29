# ARM provider completeness lane (AZURE-FIDELITY lane 1): persistent state
# for the ARM gateway surfaces that real ARM keeps stateful and this emulator
# previously answered statelessly:
#
#   * provider registration lifecycle (register/unregister per subscription)
#   * resource lifecycle timestamps backing the documented
#     `$expand=createdTime,changedTime` list semantics
#
# Shadow-ETS pattern (owner-managed, never swept) mirroring the router's
# `:smalt_arm_rate` table: named, public, heir to :init so the table outlives
# its creator request task, lazy-create with an ArgumentError rescue to keep
# the create race fail-safe.
defmodule Smalt.ArmGateway.ProviderState do
  @moduledoc """
  Stateful backing for ARM provider registration lifecycle and resource
  lifecycle timestamps (createdTime/changedTime for `$expand` list queries).
  Keys are exact: `{sub_id, ns}` tuples for registration state; downcased
  resource ids for lifecycle timestamps.
  """

  @table :smalt_arm_provider_state

  @spec table :: atom()
  def table, do: @table

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :named_table,
          :set,
          :public,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  # -- Provider registration lifecycle -------------------------------------------

  @doc """
  Stored registration state for {sub_id, ns}, or `default` when the
  subscription never registered/unregistered the namespace (real ARM's
  default posture stays whatever the ProviderMatrix advertises).
  """
  @spec registration_state(String.t(), String.t(), String.t()) :: String.t()
  def registration_state(sub_id, ns, default) do
    ensure_table()

    case :ets.lookup(@table, {:reg, sub_id, String.downcase(ns)}) do
      [{_k, state}] when is_binary(state) -> state
      _ -> default
    end
  end

  @doc "Persist the registration transition (register -> Registered, unregister -> Unregistering)."
  @spec set_registration(String.t(), String.t(), String.t()) :: :ok
  def set_registration(sub_id, ns, state) when is_binary(state) do
    ensure_table()
    :ets.insert(@table, {{:reg, sub_id, String.downcase(ns)}, state})
    :ok
  end

  @doc "Clear a registration row (test seam)."
  @spec clear_registration(String.t(), String.t()) :: :ok
  def clear_registration(sub_id, ns) do
    ensure_table()
    :ets.delete(@table, {:reg, sub_id, String.downcase(ns)})
    :ok
  end

  # -- Resource lifecycle timestamps ($expand=createdTime,changedTime) -----------

  @doc """
  Record a write: createdTime is set on FIRST write only; changedTime on
  every write. `resource_id` is stored under its downcased form.
  """
  @spec touch_lifecycle(String.t()) :: :ok
  def touch_lifecycle(resource_id) when is_binary(resource_id) do
    ensure_table()

    key = {:lifecycle, String.downcase(resource_id)}
    now = now_iso8601()

    created =
      case :ets.lookup(@table, key) do
        [{_k, %{"createdTime" => t}}] when is_binary(t) -> t
        _ -> now
      end

    :ets.insert(@table, {key, %{"createdTime" => created, "changedTime" => now}})
    :ok
  end

  @doc "Lifecycle timestamps for a resource id, or an empty map when never written."
  @spec lifecycle(String.t()) :: %{}
  def lifecycle(resource_id) when is_binary(resource_id) do
    ensure_table()

    case :ets.lookup(@table, {:lifecycle, String.downcase(resource_id)}) do
      [{_k, times}] when is_map(times) -> times
      _ -> %{}
    end
  end

  @doc "Drop a lifecycle row (DELETE cascade + test seam)."
  @spec drop_lifecycle(String.t()) :: :ok
  def drop_lifecycle(resource_id) when is_binary(resource_id) do
    ensure_table()
    :ets.delete(@table, {:lifecycle, String.downcase(resource_id)})
    :ok
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
