# ARM provider/resource-type matrix projected from the substrate Registry.
# Registry-derived projection over `Smalt.Registry` (the ggen-projected
# ontology artifact) — no hand-typed truth for admitted types: namespaces
# and apiVersions are derived by grouping Registry rows on the namespace
# segment at RUNTIME (only `@extra_types` is compile-time). The only
# compile-time projection is `@extra_types`. Registry reads
# (`registry_namespaces/0`, `registry_rows/1`) are runtime calls into
# Smalt.Registry — the module is deterministic, not build-time-frozen.
# Pattern: Smalt.Projection.Canonical (deterministic, Registry-derived).
defmodule Smalt.ArmGateway.ProviderMatrix do
  @moduledoc """
  azurerm-compatible provider/resourceType matrix for the ARM gateway.

  Admitted rows are projected from `Smalt.Registry` (runtime Registry reads,
  deterministic per registry state — only `@extra_types` is compile-time):
  `provider/1` and `provider_listing/1` group the Registry's admitted
  resource types by namespace segment (`Microsoft.Network/virtualNetworks`
  -> namespace `Microsoft.Network`, leaf type `virtualNetworks`) and bind
  each leaf to `[Registry.latest_version(type)]`.

  Handwritten supplement: `@extra_types` carries non-admitted inventory
  types that azurerm probes on an empty subscription (e.g.
  `Microsoft.Resources/subscriptions`) — they are NOT Registry truth and
  NOT admitted surface, only terraform-provider discovery noise.
  """

  alias Smalt.Registry

  @registration_state "Registered"

  # Canonical ARM-location-names form (plan §3.2). smalt stores `location`
  # verbatim from the PUT body, so the advertised list must already be in the
  # casing azurerm round-trips (ARM names, not "East US"-style display names)
  # for advertised == stored with zero drift.
  @default_locations Enum.sort(["eastus", "westus2", "local"])

  @extra_types %{
    "Microsoft.Resources" => [
      %{"resourceType" => "subscriptions", "apiVersions" => ["2022-12-01"]},
      %{"resourceType" => "tenants", "apiVersions" => ["2022-12-01"]},
      %{"resourceType" => "locations", "apiVersions" => ["2022-12-01"]}
    ],
    "Microsoft.ManagedIdentity" => [
      %{"resourceType" => "userAssignedIdentities", "apiVersions" => ["2023-01-31"]}
    ]
  }

  @typedoc "Azure provider namespace, e.g. `\"Microsoft.Network\"`."
  @type namespace :: String.t()

  @doc "Namespaces with admitted Registry rows (derived, not hand-typed)."
  @spec registry_namespaces() :: [namespace(), ...]
  def registry_namespaces do
    Registry.admitted_resource_types()
    |> Enum.map(&namespace_of/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Provider object for `ns`, or nil when the namespace is unknown (neither
  admitted Registry rows nor an `@extra_types` supplement row).
  """
  @spec provider(namespace() | String.t()) :: map() | nil
  def provider(ns) do
    case resource_types(ns) do
      [] -> nil
      rts -> %{
               "namespace" => ns,
               "resourceTypes" => rts,
               "registrationState" => @registration_state
             }
    end
  end

  @doc """
  Full azurerm-style provider listing: `{"value" => [provider, ...]}`,
  namespaces sorted deterministically. Accepts an options map (reserved).
  """
  @spec provider_listing(map()) :: map()
  def provider_listing(_opts \\ %{}) do
    %{"value" => Enum.map(all_namespaces(), &provider/1)}
  end

  @doc "Default Azure locations advertised in the matrix."
  def default_locations, do: @default_locations

  # ---------------------------------------------------------------------------
  # Compile-time projection
  # ---------------------------------------------------------------------------

  defp resource_types(ns) do
    (registry_rows(ns) ++ Map.get(@extra_types, ns, []))
    |> Enum.sort_by(& &1["resourceType"])
  end

  defp registry_rows(ns) do
    Registry.admitted_resource_types()
    |> Enum.filter(&(namespace_of(&1) == ns))
    |> Enum.sort()
    |> Enum.map(fn type ->
      %{"resourceType" => leaf_type(type), "apiVersions" => [Registry.latest_version(type)]}
    end)
  end

  defp namespace_of(type) do
    type |> String.split("/") |> hd()
  end

  defp leaf_type(type) do
    type |> String.split("/") |> tl() |> Enum.join("/")
  end

  # ---------------------------------------------------------------------------
  # Handwritten supplement (NOT Registry truth — azurerm probe noise only);
  # attribute bodies live above their first use (compile-time expansion).
  # ---------------------------------------------------------------------------

  defp all_namespaces do
    (registry_namespaces() ++ Map.keys(@extra_types)) |> Enum.uniq() |> Enum.sort()
  end
end
