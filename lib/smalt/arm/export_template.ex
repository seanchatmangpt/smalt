defmodule Smalt.Arm.ExportTemplate do
  @moduledoc """
  ARM "Export template" parity face (wave-6 lane w6bb).

  Enumerates a resource group's REAL resources from `:smalt_resources`
  (registry-admitted types only) and emits an ARM template:
      %{
        "$schema" => "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
        "contentVersion" => "1.0.0.0",
        "parameters" => %{},
        "variables" => %{},
        "resources" => [
          %{
            "type" => full type string,
            "apiVersion" => registry latest api-version,
            "name" => resource name,
            "location" => stored location,
            "properties" => stored properties verbatim,
            "tags" => stored tags (omitted when null/empty)
          }
        ],
        "outputs" => %{}
      }

  Options: `:skip_resource_types` (list of type strings to exclude).
  Parameterization is intentionally NOT performed (documented boundary: the
  template carries literal values, no [parameters(...)] interpolation).

  Round-trip promise (witnessed): the exported template validates Succeeded
  through `Smalt.Arm.Deployments.validate_deployment/1`.
  """

  alias Smalt.Registry
  alias Smalt.Store

  @schema "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"

  @spec export_rg(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, 404, map()}
  def export_rg(sub, rg, opts \\ []) when is_binary(sub) and is_binary(rg) and is_list(opts) do
    skip = opts |> Keyword.get(:skip_resource_types, []) |> MapSet.new()

    prefix = String.downcase("/subscriptions/#{sub}/resourceGroups/#{rg}/")

    rows =
      Store.list_prefix(:smalt_resources, prefix)
      |> Enum.filter(&resource_map?/1)
      |> Enum.reject(&(&1["type"] in skip))

    case rows do
      [] ->
        {:error, 404,
         %{
           "error" => %{
             "code" => "ResourceGroupResourceNotFound",
             "message" => "Resource group '#{rg}' has no exportable resources."
           }
         }}

      _ ->
        resources = Enum.map(rows, &resource_entry/1)

        {:ok,
         %{
           "$schema" => @schema,
           "contentVersion" => "1.0.0.0",
           "parameters" => %{},
           "variables" => %{},
           "resources" => resources,
           "outputs" => %{}
         }}
    end
  end

  # -- internals ---------------------------------------------------------------

  defp resource_map?(%{} = row),
    do: is_binary(row["type"]) and is_binary(row["name"]) and is_map(row["properties"])

  defp resource_map?(_), do: false

  defp resource_entry(row) do
    type = row["type"]
    entry = %{
      "type" => type,
      "apiVersion" => api_version_for(type),
      "name" => row["name"],
      "location" => Map.get(row, "location", "eastus"),
      "properties" => row["properties"]
    }

    case row_tags(row) do
      nil -> entry
      tags -> Map.put(entry, "tags", tags)
    end
  end

  defp row_tags(%{} = row) do
    case Map.get(row, "tags") do
      nil -> nil
      tags when tags == %{} -> nil
      tags -> tags
    end
  end


  defp api_version_for(type) do
    # Registry latest known version; stable fallback for types missing from
    # the version table (still registry-admitted).
    case Registry.api_versions() |> Map.get(type) do
      nil -> "2021-04-01"
      v -> v
    end
  end
end
