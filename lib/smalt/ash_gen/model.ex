defmodule Smalt.AshGen.Model do
  @moduledoc """
  RDF-free projection model between the ggen extraction (graphlaw SPARQL rows)
  and the Igniter AST generator.

  The Mix task (`lib/mix/tasks/smalt.gen.ash.ex`) runs the harmonized
  dual-vocabulary SPARQL through `GgenIgniter.Query.run/2` (fixed graphlaw
  engine) and feeds the plain string-keyed row maps here. The generator
  (`Smalt.AshGen.Generator`) consumes only structs, so it is drivable from
  `Igniter.Test` with no RDF stack in the loop.

  ## Harmonized vocabulary

  Both source vocabularies project onto one row shape:

  * `https://ggen.io/ontology/smalt#` (substrate pack): `smalt:TypeBinding`
    with `smalt:resourceType`/`smalt:apiVersion` (+ optional `smalt:bicepRef`).
  * `https://smalt.local/ontology/arm#` (bicep-derived): `Res_*` nodes with
    `smalt:resourceType`/`smalt:ashResource`/`smalt:armUriTemplate` linked to
    `TypeBinding` nodes via `smalt:hasBinding`.

  Derivable fields (`ash_resource`, `ash_domain`, `arm_uri_template`) are
  derived when absent — one naming law lives here and serves both sources.
  """

  @enforce_keys [:resource_type, :provider, :domain_module, :resource_module]
  defstruct [
    :resource_type,
    :provider,
    :domain_module,
    :resource_module,
    :api_version,
    :arm_uri_template,
    :bicep_ref,
    :parent_type,
    :parent_module
  ]

  @type binding_row :: %{optional(String.t()) => term()}
  @type parent_row :: %{String.t() => String.t()}

  @type t :: %__MODULE__{
          resource_type: String.t(),
          provider: String.t(),
          domain_module: module(),
          resource_module: module(),
          api_version: String.t() | nil,
          arm_uri_template: String.t() | nil,
          bicep_ref: String.t() | nil,
          parent_type: String.t() | nil,
          parent_module: module() | nil
        }

  @doc """
  Reduces raw ggen SPARQL rows into sorted models.

  * Builds the admitted set from `bindings` and prunes parent rows whose
    `parent_type` is not admitted (dangling-parent guard, e.g.
    `Microsoft.Compute/locations` scope prefixes).
  * Derives `ash_resource`/`arm_uri_template` when rows omit them, so both
    vocabularies produce identical models.
  * Sorts by `resource_type` (replay determinism).
  """
  @spec from_sparql_rows(%{bindings: [binding_row()], parents: [parent_row()]}) :: [t()]
  def from_sparql_rows(%{bindings: bindings, parents: parents}) do
    admitted = MapSet.new(bindings, & &1["resource_type"])

    parent_of =
      parents
      |> Enum.filter(fn row ->
        MapSet.member?(admitted, row["child_type"]) and
          MapSet.member?(admitted, row["parent_type"])
      end)
      |> Map.new(&{&1["child_type"], &1["parent_type"]})

    bindings
    |> Enum.group_by(&String.downcase(&1["resource_type"]))
    |> Enum.map(fn {_lower, variants} -> Enum.max_by(variants, &camel_score/1) end)
    |> Enum.map(&from_binding_row(&1, Map.get(parent_of, &1["resource_type"])))
    |> Enum.sort_by(& &1.resource_type)
  end

  @doc "Single-binding-row constructor; `parent_type` must already be admitted."
  def from_binding_row(row, parent_type \\ nil) do
    resource_type = fetch!(row, "resource_type")
    [provider | rest] = String.split(resource_type, "/")
    # ttl ashResource is NOT honored: the bicep script's singularizer has
    # witnessed bugs (CustomIpPrefixe); one naming law lives here (fixed).
    ash_resource = camelize_singular(List.last(rest))

    %__MODULE__{
      resource_type: resource_type,
      provider: provider,
      domain_module: domain_module(provider),
      resource_module: Module.concat([domain_module(provider), ash_resource]),
      api_version: row["api_version"],
      arm_uri_template: row["arm_uri_template"] || default_arm_uri(resource_type),
      bicep_ref: row["bicep_ref"],
      parent_type: parent_type,
      parent_module: parent_module(parent_type)
    }
  end

  @doc "Microsoft.Network => Smalt.Network."
  @spec domain_module(String.t() | nil) :: module() | nil
  def domain_module("Microsoft." <> rest), do: Module.concat([Smalt, rest])
  def domain_module(other), do: Module.concat([Smalt, other])

  @doc """
  Slice filter: keeps models whose provider prefix-matches any requested
  provider. `[]` keeps everything (full landing). Unknown providers raise
  (typed BLOCKED) — the caller (mix task) owns the exit-code contract.
  """
  @spec filter_by_providers([t()], [String.t()]) :: [t()]
  def filter_by_providers(models, []) do
    models
  end

  def filter_by_providers(models, providers) do
    known = models |> Enum.map(& &1.provider) |> Enum.uniq()

    Enum.each(providers, fn p ->
      unless Enum.any?(known, &String.starts_with?(&1, p)) do
        raise ArgumentError,
              "unknown provider filter #{inspect(p)} (ontology has: " <>
                Enum.join(Enum.sort(known), ", ") <> ")"
      end
    end)

    Enum.filter(models, fn m ->
      Enum.any?(providers, &String.starts_with?(m.provider, &1))
    end)
  end

  @doc "Parent type → parent module under the SAME provider as the child."
  def parent_module(nil), do: nil

  def parent_module(parent_type) do
    [provider | _] = String.split(parent_type, "/")
    ash = parent_type |> String.split("/") |> List.last() |> camelize_singular()
    Module.concat([domain_module(provider), ash])
  end

  @doc "URI-template synthesis when the graph omits armUriTemplate."
  @spec default_arm_uri(String.t()) :: String.t()
  def default_arm_uri(resource_type) do
    [provider | segs] = String.split(resource_type, "/")

    path = Enum.map_join(segs, "/", fn seg -> "#{seg}/{#{singularize(seg)}}" end)
    "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/#{provider}/#{path}"
  end

  # CamelCase variant wins the case-variant dedup ("dnsZones" over "dnszones"):
  # score = count of uppercase chars after position 0 of the leaf segment.
  defp camel_score(row) do
    leaf = row["resource_type"] |> String.split("/") |> List.last()
    leaf |> String.slice(1..-1//1) |> to_charlist() |> Enum.count(&(&1 in ?A..?Z))
  end

  defp fetch!(row, key) do
    row[key] || raise ArgumentError, "row missing #{inspect(key)}: #{inspect(row)}"
  end

  defp camelize_singular(type) do
    type |> singularize() |> Macro.camelize()
  end

  # Witnessed defects fixed (wave-1 L6 census): "databases" produced "databas",
  # "publicIpPrefixes" produced "publicIpPrefixe", and TTL case variants
  # ("dnszones" vs "dnsZones") produced duplicate modules.
  defp singularize(type) do
    cond do
      String.ends_with?(type, "ies") -> String.replace_suffix(type, "ies", "y")
      String.ends_with?(type, "xes") -> String.replace_suffix(type, "es", "")
      String.ends_with?(type, "ses") -> ses_stem(type)
      String.ends_with?(type, "s") and not String.ends_with?(type, "ss") ->
        String.slice(type, 0..-2//1)
      true -> type
    end
  end

  # "statuses" -> "status" (strip "es"); "databases" -> "database" (strip "s").
  defp ses_stem(type) do
    if String.at(type, -4) in ["u", "o"] do
      String.replace_suffix(type, "es", "")
    else
      String.slice(type, 0..-2//1)
    end
  end
end
