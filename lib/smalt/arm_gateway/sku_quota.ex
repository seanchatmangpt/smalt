defmodule Smalt.ArmGateway.SkuQuota do
  @moduledoc """
  SKU / quota / region truth for the ARM gateway (create-blade validation
  surface, AZURE-FIDELITY lane 7).

  Three faces, all real-substrate (no mocks):

  - **ResourceSkus list** (`GET /subscriptions/{s}/providers/Microsoft.Compute/skus`)
    — documented ResourceSku shape (`resourceType`, `locations`,
    `restrictions`, `family`); restriction rows use the real
    `type`/`values`/`reasonCode` form, `NotAvailableForSubscription`.
  - **Regional quota usage** (`GET /subscriptions/{s}/providers/{ns}/locations/{loc}/usages`)
    for `Microsoft.Compute` and `Microsoft.Network` — documented usage shape
    (`currentValue`/`limit`/`unit`/`name.value`/`name.localizedValue`).
    `currentValue` is DERIVED from real stored resources
    (`Smalt.Store`) at read time, so seeded consumption (real resource PUTs)
    moves it — never a hand-typed counter.
  - **PUT-time enforcement** — `check_put/1` is exported for the generic
    resource PUT path (and for lanes 1/2's PUT surfaces): a virtualMachines
    PUT whose vmSize is unavailable in the record's location is refused
    before persistence; the router answers the documented
    `SKUNotAvailableAvailability` 409 envelope.

  The catalog is deterministic seed truth, not hand-typed per-resource
  state; availability law: a SKU is available in `loc` iff `loc` is in the
  row's `locations` and not named in any restriction `values`.
  """

  alias Smalt.Store

  # ---------------------------------------------------------------------------
  # Deterministic seed catalog (virtualMachines)
  # ---------------------------------------------------------------------------

  # Availability law seed: Standard_D* v5 skus ship everywhere; Standard_NC6
  # is region-gated OUT of `local` by a NotAvailableForSubscription
  # restriction (the create blade greys the sku out in `local`).
  @compute_skus [
    %{
      "resourceType" => "virtualMachines",
      "name" => "Standard_D2s_v5",
      "family" => "standardDSv5Family",
      "tier" => "Standard",
      "size" => "DSv5-Series",
      "locations" => ["eastus", "westus2", "local"],
      "restrictions" => []
    },
    %{
      "resourceType" => "virtualMachines",
      "name" => "Standard_D4s_v5",
      "family" => "standardDSv5Family",
      "tier" => "Standard",
      "size" => "DSv5-Series",
      "locations" => ["eastus", "westus2", "local"],
      "restrictions" => []
    },
    %{
      "resourceType" => "virtualMachines",
      "name" => "Standard_NC6",
      "family" => "standardNCSeries",
      "tier" => "Standard",
      "size" => "NC-Series",
      "locations" => ["eastus", "westus2"],
      "restrictions" => [
        %{
          "type" => "Location",
          "values" => ["local"],
          "reasonCode" => "NotAvailableForSubscription"
        }
      ]
    }
  ]

  @sku_by_name @compute_skus
               |> Enum.map(&{&1["name"], &1})
               |> Map.new()

  # Quota rows per provider namespace. Limits are deterministic seed truth;
  # currentValue is always derived from the Store at read time.
  @compute_quota [
    {"standardDSv5Family", "Standard DSv5 Family vCPUs", 100, "Standard_D"},
    {"standardNCSeries", "Standard NC Series vCPUs", 4, "Standard_NC"}
  ]

  @network_quota [
    {"virtualNetworks", "Virtual Networks", 100, "Microsoft.Network/virtualNetworks"},
    {"networkSecurityGroups", "Network Security Groups", 100,
     "Microsoft.Network/networkSecurityGroups"}
  ]

  @typedoc "A ResourceSku row (documented ARM shape)."
  @type resource_sku :: map()

  @typedoc "check_put/1 verdict."
  @type put_verdict :: :ok | {:refuse, sku :: String.t() | nil, location :: String.t()}

  @doc """
  ResourceSkus listing for `sub_id`, optionally filtered by
  `$filter=location eq '<loc>'` (the documented create-blade filter).
  `{"value" => [sku, ...]}` — deterministic order (by sku name).
  """
  @spec list_skus(String.t(), String.t() | nil) :: map()
  def list_skus(_sub_id, filter \\ nil) do
    rows =
      @compute_skus
      |> Enum.sort_by(& &1["name"])
      |> then(&filter_skus(&1, filter))

    %{"value" => rows}
  end

  defp filter_skus(rows, filter) when is_binary(filter) do
    case parse_location_filter(filter) do
      {:ok, loc} -> Enum.filter(rows, &(loc in &1["locations"]))
      :error -> rows
    end
  end

  defp filter_skus(rows, _), do: rows

  # Only the documented `location eq 'x'` filter form is understood; any
  # other filter text is ignored (permissive passthrough, list unfiltered).
  defp parse_location_filter(filter) do
    case Regex.run(~r/location\s+eq\s+'([^']+)'/i, filter) do
      [_, loc] -> {:ok, loc}
      _ -> :error
    end
  end

  @doc """
  Regional quota usage rows for `namespace` (`"Microsoft.Compute"` or
  `"Microsoft.Network"`) in `location`, subscription `sub_id`.
  `{"value" => [usage, ...]}` with `currentValue` derived from real stored
  resources.
  """
  @spec usage(String.t(), String.t(), String.t()) :: map()
  def usage("Microsoft.Compute", location, sub_id) do
    vms =
      sub_id
      |> stored_resources("Microsoft.Compute/virtualMachines", location)
      |> Enum.map(&vm_size_of/1)

    rows =
      for {name, localized, limit, prefix} <- @compute_quota do
        current = Enum.count(vms, &(is_binary(&1) and String.starts_with?(&1, prefix)))

        usage_row(name, localized, current, limit)
        |> Map.put("unit", "Count")
      end

    %{"value" => rows}
  end

  def usage("Microsoft.Network", location, sub_id) do
    rows =
      for {name, localized, limit, type} <- @network_quota do
        current =
          sub_id
          |> stored_resources(type, location)
          |> length()

        usage_row(name, localized, current, limit)
        |> Map.put("unit", "Count")
      end

    %{"value" => rows}
  end

  def usage(_ns, _location, _sub_id), do: %{"value" => []}

  defp usage_row(name, localized, current, limit) do
    %{
      "name" => %{"value" => name, "localizedValue" => localized},
      "currentValue" => current,
      "limit" => limit
    }
  end

  @doc "true iff sku `name` is available in `location` per the catalog + restrictions."
  @spec available?(String.t(), String.t()) :: boolean()
  def available?(name, location) when is_binary(name) do
    case Map.get(@sku_by_name, name) do
      nil -> true
      row -> location in row["locations"] and not restricted?(row, location)
    end
  end

  def available?(_name, _location), do: true

  defp restricted?(row, location) do
    Enum.any?(row["restrictions"] || [], fn r ->
      location in (r["values"] || [])
    end)
  end

  @doc """
  PUT-time enforcement hook (exported for the router and for lanes 1/2's
  PUT surfaces). virtualMachines records only: a vmSize unavailable in the
  record's location yields `{:refuse, sku, location}`; everything else
  (other types, unknown/absent sku names) passes `:ok`.

  `raw_body` (the un-merged PUT payload) is consulted as a sku fallback
  because the built record lifts defaults into `properties` but the
  VirtualMachineShape declares `vmSize` at the TOP LEVEL of the body —
  the record does not carry it verbatim.
  """
  @spec check_put(map(), map() | nil) :: put_verdict()
  def check_put(%{"type" => "Microsoft.Compute/virtualMachines"} = record, raw_body) do
    sku = vm_size_of(record) || (is_map(raw_body) && raw_body["vmSize"]) || nil
    location = Map.get(record, "location", "eastus")

    if available?(sku, location) do
      :ok
    else
      {:refuse, sku, location}
    end
  end

  def check_put(_record, _raw_body), do: :ok

  @doc """
  Persist-time annotation (router chain): lift the body's TOP-LEVEL `vmSize`
  (VirtualMachineShape declares it bare) into
  `properties.hardwareProfile.vmSize` — the real ARM stored shape — when the
  record does not already carry it. Pure; no-op for non-VM records and when
  vmSize is present under `properties` already.
  """
  @spec ensure_hardware_profile(map(), map() | nil) :: map()
  def ensure_hardware_profile(%{"type" => "Microsoft.Compute/virtualMachines"} = record, body)
      when is_map(body) do
    case vm_size_of(record) do
      nil ->
        case body["vmSize"] do
          size when is_binary(size) and size != "" ->
            props = Map.get(record, "properties", %{})

            hardware =
              props
              |> Map.get("hardwareProfile", %{})
              |> Map.put_new("vmSize", size)

            Map.put(record, "properties", Map.put(props, "hardwareProfile", hardware))

          _ ->
            record
        end

      _present ->
        record
    end
  end

  def ensure_hardware_profile(record, _body), do: record

  # vmSize is tolerant across body shapes: bare top-level (the VirtualMachineShape
  # paths are top-level), properties.vmSize, or the real ARM nesting
  # properties.hardwareProfile.vmSize.
  defp vm_size_of(record) do
    record["vmSize"] ||
      get_in(record, ["properties", "vmSize"]) ||
      get_in(record, ["properties", "hardwareProfile", "vmSize"])
  end

  # ---------------------------------------------------------------------------
  # Store-derived consumption
  # ---------------------------------------------------------------------------

  defp stored_resources(sub_id, type, location) do
    :smalt_resources
    |> Store.list_prefix("/subscriptions/#{String.downcase(sub_id)}/")
    |> Enum.filter(fn
      %{"type" => ^type, "location" => loc} -> loc == location
      _ -> false
    end)
  end
end
