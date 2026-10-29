defmodule PopcornDemo.AzureCost.Profile do
  @moduledoc """
  Workload profile validation/normalization for `PopcornDemo.AzureCost`.
  Missing workload keys default to 0; unknown keys are rejected loudly.
  """

  @keys ~w(cosmos_reads cosmos_writes cosmos_ru_budget blob_tx blob_tx_writes blob_gb sb_ops kv_ops eh_ingress_gb)a

  def keys, do: @keys

  @doc "Reject non-map or unknown-key profiles with a typed error."
  def validate(p) when is_map(p) do
    unknown = Map.keys(p) -- (@keys ++ [:hours])

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_profile_keys, unknown}}
    end
  end

  def validate(_), do: {:error, :invalid_profile}

  @doc "Fill missing workload keys with 0 (hours has its own default)."
  def normalize(p) do
    Enum.into(@keys, %{}, fn k -> {k, Map.get(p, k, 0) * 1.0} end)
  end
end
