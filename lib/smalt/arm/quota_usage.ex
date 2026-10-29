defmodule Smalt.Arm.QuotaUsage do
  @moduledoc """
  ARM quota/usage faces (wave-6 lane w6bh, v26.10.20).

  `GET /subscriptions/{sub}/providers/{ns}/locations/{loc}/usages` parity:
  per-location usage rollups computed from smalt's REAL resource store
  (`:smalt_resources` — the same rows the ARM router writes), for the
  resource families smalt's registry actually admits. No invented
  namespaces: every family maps to an admitted
  `Microsoft.Compute/...`-style type and counts real records of that exact
  type in the requested location.

  Limits are the standard Azure published per-region defaults, documented:

  - Compute: virtualMachines 100, disks 100, diskEncryptionSets 100
    (Azure default Regional vCPU / managed-disk family quotas per region).
  - Network: virtualNetworks 1000, networkSecurityGroups 5000,
    networkInterfaces 35_000 (smalt's documented local stand-in for the
    real published 350_000 regional NIC quota — family documented without
    a huge wire number), privateEndpoints 1000.
  - Storage: storageAccounts 250 per region (Azure published default).

  Admitted locations = `Smalt.ArmGateway.ProviderMatrix.default_locations/0`
  (what smalt's ARM declares); unknown location →
  `{:error, :unknown_location}` (wire face 400 `InvalidLocation`).

  Router patch is ~3 lines (staged, ROUTER HOLD respected):
  `GET .../providers/Microsoft.Compute/locations/:loc/usages` etc. →
  `*_usages_wire/1` outputs.
  """

  @families [
    {"Microsoft.Compute", "virtualMachines", 100, "Virtual Machines"},
    {"Microsoft.Compute", "disks", 100, "Disks"},
    {"Microsoft.Compute", "diskEncryptionSets", 100, "Disk Encryption Sets"},
    {"Microsoft.Network", "virtualNetworks", 1_000, "Virtual Networks"},
    {"Microsoft.Network", "networkSecurityGroups", 5_000, "Network Security Groups"},
    {"Microsoft.Network", "networkInterfaces", 35_000, "Network Interfaces"},
    {"Microsoft.Network", "privateEndpoints", 1_000, "Private Endpoints"},
    {"Microsoft.Storage", "storageAccounts", 250, "Storage Accounts"}
  ]

  @spec families() :: [{String.t(), String.t(), non_neg_integer(), String.t()}]
  def families, do: @families

  @doc """
  Usage rollup for one namespace in one location.
  Returns `{:ok, [usage_entry()]}` or `{:error, :unknown_location}`.
  """
  @spec usage(String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :unknown_location}
  def usage(ns, location) when is_binary(ns) and is_binary(location) do
    if location_admitted?(location) do
      fams = Enum.filter(@families, fn {pns, _leaf, _lim, _l10n} -> pns == ns end)

      if fams == [] do
        {:error, :unknown_namespace}
      else
        {:ok, Enum.map(fams, &entry(&1, location))}
      end
    else
      {:error, :unknown_location}
    end
  end

  @doc "Storage-account rollup (`Microsoft.Storage` namespace usage face)."
  @spec storage_usage(String.t()) :: {:ok, [map()]} | {:error, :unknown_location}
  def storage_usage(location), do: usage("Microsoft.Storage", location)

  defp entry({pns, leaf, limit, localized}, location) do
    %{
      "currentValue" => count_family(pns, leaf, location),
      "limit" => limit,
      "name" => %{"value" => leaf, "localizedValue" => localized}
    }
  end

  defp count_family(pns, leaf, location) do
    full_type = pns <> "/" <> leaf
    loc = String.downcase(location)

    Smalt.Store.list_all(:smalt_resources)
    |> Enum.count(fn rec ->
      is_map(rec) and Map.get(rec, "type") == full_type and
        rec |> Map.get("location", "") |> String.downcase() == loc
    end)
  end

  defp location_admitted?(location) do
    String.downcase(location) in Enum.map(Smalt.ArmGateway.ProviderMatrix.default_locations(), &String.downcase/1)
  end
end
