defmodule Smalt.FinOps.Calculator do
  @moduledoc """
  Avoided-spend tariff calculator. Pure, deterministic, no I/O.

  Honest port of the console finops precedent
  `workspace/lib/finops/calculator.ts` (Agent 14 finops lane): the
  `RETAIL_TARIFFS` table and the per-resource formula
  `count * (usd_per_hour * hours + usd_per_unit)` are transcribed 1:1 from
  the TypeScript source (hourly fees prorated at 730 h/mo). The TypeScript
  `computeAvoidedSpend` has no region dimension; the `region/1` multiplier
  table below is an Elixir-side extension (default `:eastus`, multiplier
  1.0). Where the TS contract throws `FinopsError('UNKNOWN_RESOURCE_TYPE')`,
  this port returns the typed `{:error, :unknown_resource}`.
  """

  @hours_per_month 730
  @ms_per_hour 3_600_000

  @type resource_type ::
          :resource_group
          | :storage_account
          | :key_vault
          | :cosmos_serverless
          | :eventhub_standard
          | :servicebus_standard

  @type region :: :eastus | :westus2 | :northeurope | :southeastasia

  @typedoc "Tariff per resource unit: hourly-metered USD + once-per-cycle unit USD."
  @type tariff :: %{usd_per_hour: float(), usd_per_unit: float(), note: String.t()}

  @retail_tariffs %{
    resource_group: %{
      usd_per_hour: 0.0,
      usd_per_unit: 0.0,
      note: "Azure RG is free — management-plane construct only"
    },
    storage_account: %{
      usd_per_hour: 0.02 / @hours_per_month,
      usd_per_unit: 0.05,
      note: "$0.02/mo account fee (prorated /730) + $0.05/GB (1 GB per unit)"
    },
    key_vault: %{
      usd_per_hour: 0.0,
      usd_per_unit: 0.03,
      note: "$0.03 per secret-version (standard tier)"
    },
    cosmos_serverless: %{
      usd_per_hour: 0.25 / @hours_per_month,
      usd_per_unit: 0.25,
      note: "$0.25 per M RU-s (negligible at 1 unit) + $0.25/GB (1 GB per unit)"
    },
    eventhub_standard: %{
      usd_per_hour: 0.03,
      usd_per_unit: 0.0,
      note: "$0.03/hour standard tier; ingress events under included quota"
    },
    servicebus_standard: %{
      usd_per_hour: 0.05,
      usd_per_unit: 0.0,
      note: "$0.05/hour per messaging unit; ops under included base quota"
    }
  }

  # Elixir-side extension (see moduledoc): published-Azure-approximate
  # regional price multipliers relative to the East US baseline.
  @region_multipliers %{
    eastus: 1.0,
    westus2: 1.08,
    northeurope: 1.10,
    southeastasia: 1.16
  }

  @spec retail_tariffs :: %{resource_type() => tariff()}
  def retail_tariffs, do: @retail_tariffs

  @spec region_multiplier(region()) :: float()
  def region_multiplier(region) when is_map_key(@region_multipliers, region),
    do: Map.fetch!(@region_multipliers, region)

  @doc """
  Avoided tariff for `quantity` units of `resource_type` in `region`
  (default `:eastus`), metered over `hours` (default 1.0).

  Returns integer cents (rounded), or `{:error, :unknown_resource}` /
  `{:error, :unknown_region}` matching the TS typed-error contract.
  """
  @spec avoided_tariff_cents(resource_type() | atom(), number(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :unknown_resource | :unknown_region}
  def avoided_tariff_cents(resource_type, quantity, opts \\ []) when is_number(quantity) do
    region = Keyword.get(opts, :region, :eastus)
    hours = Keyword.get(opts, :hours, 1.0)

    cond do
      not is_map_key(@retail_tariffs, resource_type) ->
        {:error, :unknown_resource}

      not is_map_key(@region_multipliers, region) ->
        {:error, :unknown_region}

      true ->
        tariff = Map.fetch!(@retail_tariffs, resource_type)
        usd = quantity * (tariff.usd_per_hour * hours + tariff.usd_per_unit)
        cents = usd * region_multiplier(region) * 100
        {:ok, Kernel.round(cents)}
    end
  end

  @doc """
  convenience: `avoided_tariff_cents/3` raising on unknown inputs,
  mirroring the TS `throw FinopsError` behaviour.
  """
  @spec avoided_tariff_cents!(resource_type() | atom(), number(), keyword()) ::
          non_neg_integer()
  def avoided_tariff_cents!(resource_type, quantity, opts \\ []) do
    case avoided_tariff_cents(resource_type, quantity, opts) do
      {:ok, cents} ->
        cents

      {:error, reason} ->
        raise ArgumentError,
              "finops: #{reason} (#{inspect(resource_type)}/#{inspect(opts[:region])})"
    end
  end

  @doc """
  Manifest form of the TS `computeAvoidedSpend` per-cycle term:
  `Σ count * (usd_per_hour * avoided_hours + usd_per_unit)` over
  `resources: [{type, count}]`, scaled by `durations_ms` like the TS source
  (`avoidedHours = durations_ms / 3_600_000`) and `cycles`.
  Returns integer total cents, or `{:error, :unknown_resource}`.
  """
  @spec avoided_spend_cents([%{type: atom(), count: number()}], keyword()) ::
          {:ok, non_neg_integer()} | {:error, :unknown_resource}
  def avoided_spend_cents(resources, opts \\ []) when is_list(resources) do
    cycles = Keyword.get(opts, :cycles, 1)
    hours = Keyword.get(opts, :durations_ms, 0) / @ms_per_hour

    types = Enum.map(resources, & &1.type)

    if Enum.any?(types, &(!is_map_key(@retail_tariffs, &1))) do
      {:error, :unknown_resource}
    else
      total_usd =
        Enum.reduce(resources, 0.0, fn r, acc ->
          t = Map.fetch!(@retail_tariffs, r.type)
          acc + r.count * (t.usd_per_hour * hours + t.usd_per_unit)
        end)

      {:ok, Kernel.round(total_usd * cycles * 100)}
    end
  end
end
