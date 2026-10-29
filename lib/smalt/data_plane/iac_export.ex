defmodule Smalt.DataPlane.IacExport do
  @moduledoc """
  IaC state export engine (T-15): projects the provisioned resource graph
  (the `:smalt_resources` Store table) into bicep and terraform.

  ## Single-source law

  There is ONE projection pass and TWO renderers:

      :smalt_resources rows
        -> intermediate_model/1   (the ONE walk: typed entries, symbolic
                                   names, declarative properties, outputs
                                   for keys/endpoints, parent references)
        -> render_bicep(model)     -> %{"main.bicep" => body}
        -> render_terraform(model) -> %{"main.tf" => .., "terraform.tfvars" => ..}

  `intermediate_model/1` is a PUBLIC function so a court can drive it
  directly (test/integration/iac_export_test.exs) and witness that both
  renderers consume its output verbatim — the formats are renderers, not
  separate exporters, so the bicep and the HCL can never disagree.

  ## Normalization discipline (read-path law, mirrored from the semantic
  projection `lib/smalt/semantic/store_read.ex`)

    * Row STRUCTURE is refused typed: a non-map row, a row whose identity is
      vacuous (`Smalt.Projection.Identity.valid?/1` — adopt, don't
      reimplement, the lens-7 identity fence), or a row with no binary
      `type` stops the export with `{:error, reason}` — never a silent skip,
      never a projected-garbage template block.
    * Field VALUES are lenient: a missing/non-binary `location` simply omits
      the location line (real ARM children like Service Bus queues carry no
      location; many top-level types inherit the RG location), and a
      non-map `properties` projects as `%{}`.
    * `provisioningState` is RUNTIME state — the export never re-declares it
      (an exported template must rebuild the world, not re-assert its
      provisioning history).

  ## Fidelity boundary (stub tier, disclosed)

  Known types (`Microsoft.Resources/resourceGroups`,
  `Microsoft.Storage/storageAccounts`, `Microsoft.KeyVault/vaults`,
  `Microsoft.ServiceBus/namespaces`, `Microsoft.ServiceBus/namespaces/queues`,
  `Microsoft.EventHub/namespaces`, `Microsoft.DocumentDB/databaseAccounts`)
  render real resource types, symbolic names, SKUs/kind scaffolding and
  outputs for keys/endpoints (bicep `listKeys()` / resource properties;
  terraform provider attributes). Unknown types render a generic block
  (plain bicep resource; `azapi_resource` for terraform — the generic
  escape hatch) with the stored properties verbatim. Known azurerm surface
  attributes beyond name/location/sku/tenant are a stub boundary; the
  round-trip receipts (bicep build / terraform plan) are the acceptance
  bar, not this module's claim.
  """

  alias Smalt.Projection.Identity
  alias Smalt.Store

  @table :smalt_resources

  # Pinned real api-versions for known types (real export pins the version
  # the resource was read under; the Store rows carry no api-version, so the
  # exporter pins the type's current stable one). Unknown types get a
  # placeholder literal — a real api-version cannot be invented for a type
  # the engine does not know.
  @known_api_versions %{
    "Microsoft.Resources/resourceGroups" => "2021-04-01",
    "Microsoft.Storage/storageAccounts" => "2023-05-01",
    "Microsoft.KeyVault/vaults" => "2023-07-01",
    "Microsoft.ServiceBus/namespaces" => "2022-10-01-preview",
    "Microsoft.ServiceBus/namespaces/queues" => "2022-10-01-preview",
    "Microsoft.EventHub/namespaces" => "2021-11-01",
    "Microsoft.DocumentDB/databaseAccounts" => "2023-04-15"
  }

  @generic_api_version "2023-01-01"

  # type string (canonical casing) -> entry kind. Matching is case-
  # insensitive (ARM types are), and a match re-cases the stored type to the
  # canonical spelling so `bicep build` sees the real type string even if
  # the router stored a differently-cased PUT body.
  @kind_by_type %{
    "Microsoft.Resources/resourceGroups" => :resource_group,
    "Microsoft.Storage/storageAccounts" => :storage_account,
    "Microsoft.KeyVault/vaults" => :key_vault,
    "Microsoft.ServiceBus/namespaces" => :servicebus_namespace,
    "Microsoft.ServiceBus/namespaces/queues" => :servicebus_queue,
    "Microsoft.EventHub/namespaces" => :eventhub_namespace,
    "Microsoft.DocumentDB/databaseAccounts" => :cosmos_account
  }

  # entry kind -> azurerm terraform resource type. Generic (unknown) kinds
  # escape through azapi_resource.
  @tf_type_by_kind %{
    resource_group: "azurerm_resource_group",
    storage_account: "azurerm_storage_account",
    key_vault: "azurerm_key_vault",
    servicebus_namespace: "azurerm_servicebus_namespace",
    servicebus_queue: "azurerm_servicebus_queue",
    eventhub_namespace: "azurerm_eventhub_namespace",
    cosmos_account: "azurerm_cosmosdb_account"
  }

  @namespace_kinds [:servicebus_namespace, :eventhub_namespace]

  @typedoc """
  One model entry: an exported row (`existing: false`) or a synthesized
  parent reference (`existing: true` — bicep `existing` block / terraform
  data source).
  """
  @type entry :: %{
          id: String.t() | nil,
          name: String.t(),
          type: String.t(),
          api_version: String.t(),
          kind: atom(),
          arm_kind: String.t() | nil,
          location: String.t() | nil,
          properties: map(),
          sku: map() | nil,
          scope: map() | nil,
          parent: map() | nil,
          symbolic_name: String.t(),
          existing: boolean(),
          outputs: [map()]
        }

  @typedoc "The ONE intermediate model both renderers consume."
  @type model :: %{
          source_table: atom(),
          resources: [entry()],
          synthetic: [entry()],
          outputs: [map()]
        }

  @doc """
  The ONE projection pass over the live Store (`:smalt_resources`).

  Returns `{:ok, model}` or `{:error, reason}` — a malformed row refuses the
  export typed, never a partially-rendered template.
  """
  @spec intermediate_model() :: {:ok, model()} | {:error, term()}
  def intermediate_model do
    intermediate_model(Store.list(@table))
  end

  @doc """
  The ONE projection pass over explicit rows (`:smalt_resources`-shaped
  maps: id/name/type/location/properties). Public so courts and callers can
  drive the engine without a Store.
  """
  @spec intermediate_model([term()]) :: {:ok, model()} | {:error, term()}
  def intermediate_model(rows) when is_list(rows) do
    with :ok <- refuse_non_map_rows(rows),
         :ok <- refuse_vacuous_identity(rows),
         :ok <- refuse_missing_type(rows) do
      {:ok, build_model(Enum.sort_by(rows, & &1["id"]))}
    end
  end

  def intermediate_model(_other), do: {:error, {:non_list_rows, @table}}

  # --- typed refusals (row STRUCTURE, never lenient) ------------------------------

  defp refuse_non_map_rows(rows) do
    case Enum.find(rows, &(!is_map(&1))) do
      nil -> :ok
      bad -> {:error, {:non_map_row, inspect(bad, limit: 10)}}
    end
  end

  defp refuse_vacuous_identity(rows) do
    case Enum.find(rows, fn row -> not Identity.valid?(row["id"]) end) do
      nil -> :ok
      bad -> {:error, {:vacuous_identity, @table, bad["id"]}}
    end
  end

  defp refuse_missing_type(rows) do
    case Enum.find(rows, fn row -> not (is_binary(row["type"]) and row["type"] != "") end) do
      nil -> :ok
      bad -> {:error, {:missing_type, bad["id"]}}
    end
  end

  # --- the one walk ---------------------------------------------------------------

  defp build_model(sorted_rows) do
    {entries, _taken} =
      Enum.map_reduce(sorted_rows, MapSet.new(), fn row, taken ->
        name = row_name(row)
        symbolic = symbolic_name(name, taken)
        {build_entry(row, name, symbolic), MapSet.put(taken, symbolic)}
      end)

    {wired_entries, synthetic} = attach_parents(entries)

    %{
      source_table: @table,
      resources: wired_entries,
      synthetic: Enum.sort_by(synthetic, &{&1.kind, &1.symbolic_name}),
      outputs: Enum.flat_map(wired_entries, & &1.outputs)
    }
  end

  defp row_name(%{"name" => name}) when is_binary(name) and name != "", do: name

  defp row_name(%{"id" => id}) when is_binary(id) do
    case String.split(id, "/", trim: true) do
      [] -> "res"
      segs -> List.last(segs)
    end
  end

  defp row_name(_), do: "res"

  defp build_entry(row, name, symbolic) do
    stored_type = row["type"]
    kind = kind_for(stored_type)
    type = canonical_type(stored_type, kind)
    properties = declarative_properties(row)

    %{
      id: row["id"],
      name: name,
      type: type,
      api_version: Map.get(@known_api_versions, type, @generic_api_version),
      kind: kind,
      arm_kind: bin_or_nil(row["kind"]),
      location: bin_or_nil(row["location"]),
      properties: properties,
      sku: sku_of(row),
      scope: nil,
      parent: nil,
      symbolic_name: symbolic,
      existing: false,
      outputs: outputs_for(type, kind, symbolic, properties)
    }
  end

  defp kind_for(type) do
    lowered = String.downcase(type)

    case Enum.find(@kind_by_type, fn {t, _} -> String.downcase(t) == lowered end) do
      {_canonical, kind} -> kind
      nil -> :generic
    end
  end

  defp canonical_type(stored_type, :generic), do: stored_type

  defp canonical_type(stored_type, _known) do
    lowered = String.downcase(stored_type)

    case Enum.find(@kind_by_type, fn {t, _} -> String.downcase(t) == lowered end) do
      {canonical, _kind} -> canonical
      nil -> stored_type
    end
  end

  # Lens-7 field-VALUE policy (parse_ts lenient precedent, mirroring
  # StoreRead.bin_or_nil): a non-binary location/kind projects nil — never a
  # raw type-lie into a rendered string slot.
  defp bin_or_nil(v) when is_binary(v) and v != "", do: v
  defp bin_or_nil(_), do: nil

  # provisioningState is runtime state — never re-declared by an export.
  # A non-map properties projects as %{} (same lenient malformed-value
  # policy as the semantic projection's non-map properties case).
  defp declarative_properties(row) do
    case row["properties"] do
      props when is_map(props) -> Map.delete(props, "provisioningState")
      _ -> %{}
    end
  end

  defp sku_of(row) do
    case row["sku"] do
      sku when is_map(sku) -> sku
      _ -> nil
    end
  end

  # --- parent references (resource groups, namespaces) ------------------------------

  # Top-level entries scope to the resource group named by their ARM id; the
  # queue child additionally parents to its namespace. When the referenced
  # parent is itself an exported row, the entry references that row's
  # symbolic name; otherwise a synthetic `existing` parent reference is
  # synthesized (bicep `existing` block / terraform data source) so the
  # graph stays deployable without fabricating a definition for it.
  defp attach_parents(entries) do
    rg_index =
      entries
      |> Enum.filter(&(&1.kind == :resource_group))
      |> Map.new(&{String.downcase(&1.name), &1})

    ns_index =
      entries
      |> Enum.filter(&(&1.kind in @namespace_kinds))
      |> Map.new(&{String.downcase(&1.name), &1})

    taken = MapSet.new(Enum.map(entries, & &1.symbolic_name))

    {entries, %{taken: taken, synthetic: synthetic}} =
      Enum.map_reduce(entries, %{taken: taken, synthetic: []}, fn entry, state ->
        parsed = parse_id(entry.id)

        {scope, state} = resolve_rg(parsed.rg, rg_index, state)

        {parent, state} = resolve_namespace(entry.kind, parsed, ns_index, scope, state)

        entry =
          entry
          |> Map.put(:scope, if(entry.kind == :resource_group, do: nil, else: scope))
          |> Map.put(:parent, parent)

        {entry, state}
      end)

    {entries, Enum.reverse(synthetic)}
  end

  defp resolve_rg(nil, _rg_index, state), do: {nil, state}

  defp resolve_rg(rg_segment, rg_index, state) do
    key = String.downcase(rg_segment)

    case Map.get(rg_index, key) do
      %{symbolic_name: sym} ->
        {%{kind: :resource_group, name: rg_segment, symbolic_name: sym, existing: false}, state}

      nil ->
        synthetic = state.synthetic

        case Enum.find(synthetic, &(&1.kind == :resource_group and String.downcase(&1.name) == key)) do
          %{symbolic_name: sym} ->
            {%{kind: :resource_group, name: rg_segment, symbolic_name: sym, existing: true}, state}

          nil ->
            {ref, state} = put_synthetic_resource_group(rg_segment, state)
            {%{kind: :resource_group, name: rg_segment, symbolic_name: ref.symbolic_name, existing: true}, state}
        end
    end
  end

  defp put_synthetic_resource_group(rg_segment, state) do
    {symbolic, state} = mint_symbolic(rg_segment, state)

    ref = %{
      id: nil,
      name: rg_segment,
      type: "Microsoft.Resources/resourceGroups",
      api_version: @known_api_versions["Microsoft.Resources/resourceGroups"],
      kind: :resource_group,
      arm_kind: nil,
      location: nil,
      properties: %{},
      sku: nil,
      scope: nil,
      parent: nil,
      symbolic_name: symbolic,
      existing: true,
      outputs: []
    }

    {ref, put_synthetic(ref, state)}
  end

  defp resolve_namespace(:servicebus_queue, parsed, ns_index, scope, state) do
    case namespace_name(parsed) do
      nil ->
        # A queue row whose id lost its namespace segment cannot name its
        # parent — it renders RG-scoped instead of a fabricated parent.
        {nil, state}

      ns_name ->
        key = String.downcase(ns_name)

        case Map.get(ns_index, key) do
          %{symbolic_name: sym} ->
            {%{kind: :servicebus_namespace, name: ns_name, symbolic_name: sym, existing: false, scope: scope}, state}

          nil ->
            synthetic = state.synthetic

            case Enum.find(synthetic, &(&1.kind == :servicebus_namespace and String.downcase(&1.name) == key)) do
              %{symbolic_name: sym} ->
                {%{kind: :servicebus_namespace, name: ns_name, symbolic_name: sym, existing: true, scope: scope}, state}

              nil ->
                {ref, state} = put_synthetic_namespace(ns_name, scope, state)
                {%{kind: :servicebus_namespace, name: ns_name, symbolic_name: ref.symbolic_name, existing: true, scope: scope}, state}
            end
        end
    end
  end

  defp resolve_namespace(_kind, _parsed, _ns_index, _scope, state), do: {nil, state}

  defp put_synthetic_namespace(ns_name, scope, state) do
    {symbolic, state} = mint_symbolic(ns_name, state)

    ref = %{
      id: nil,
      name: ns_name,
      type: "Microsoft.ServiceBus/namespaces",
      api_version: @known_api_versions["Microsoft.ServiceBus/namespaces"],
      kind: :servicebus_namespace,
      arm_kind: nil,
      location: nil,
      properties: %{},
      sku: nil,
      scope: scope,
      parent: nil,
      symbolic_name: symbolic,
      existing: true,
      outputs: []
    }

    {ref, put_synthetic(ref, state)}
  end

  defp put_synthetic(ref, %{taken: taken, synthetic: synthetic}) do
    %{taken: MapSet.put(taken, ref.symbolic_name), synthetic: [ref | synthetic]}
  end

  defp mint_symbolic(raw, %{taken: taken} = state) do
    symbolic = symbolic_name(raw, taken)
    {symbolic, %{state | taken: MapSet.put(taken, symbolic)}}
  end

  defp namespace_name(parsed) do
    case parsed do
      %{tail: segs} when is_list(segs) ->
        case Enum.find_index(segs, &(&1 == "namespaces")) do
          nil -> nil
          i -> Enum.at(segs, i + 1)
        end

      _ ->
        nil
    end
  end

  # /subscriptions/<sub>/resourcegroups/<rg>/providers/<provider>/...
  # (stored keys are lowercased full ARM ids; parse against that convention,
  # tolerating ids without a resourcegroup segment).
  defp parse_id(id) when is_binary(id) do
    case String.split(id, "/", trim: true) do
      ["subscriptions", _sub | rest] ->
        case rest do
          ["resourcegroups", rg | tail] -> %{rg: rg, tail: tail}
          _ -> %{rg: nil, tail: rest}
        end

      _ ->
        %{rg: nil, tail: nil}
    end
  end

  defp parse_id(_), do: %{rg: nil, tail: nil}

  # --- symbolic names ---------------------------------------------------------------

  # Symbolic names derive from the resource NAME (sanitized to an
  # identifier: lowercase, non-identifier runs -> "_", trimmed, digit-led
  # prefixed), deduplicated with _2/_3 suffixes so the exported file never
  # carries two blocks with the same symbolic name.
  @spec symbolic_name(String.t(), MapSet.t(String.t())) :: String.t()
  def symbolic_name(raw, taken) do
    unique_symbolic(sanitize_symbolic(raw), taken)
  end

  defp sanitize_symbolic(raw) do
    base =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")

    cond do
      base == "" -> "res"
      Regex.match?(~r/^\d/, base) -> "res_" <> base
      true -> base
    end
  end

  defp unique_symbolic(base, taken) do
    if MapSet.member?(taken, base), do: unique_symbolic(base, 2, taken), else: base
  end

  defp unique_symbolic(base, n, taken) do
    candidate = "#{base}_#{n}"

    if MapSet.member?(taken, candidate) do
      unique_symbolic(base, n + 1, taken)
    else
      candidate
    end
  end

  # --- outputs (keys/endpoints, where the real export tool does) ----------------------

  # Computed ONCE, here — both renderers print these expressions verbatim.
  # Key outputs are emitted for the key-bearing types unconditionally (the
  # keys are runtime material fetched via listKeys in real exports, never
  # stored declaratively); endpoint outputs only when the stored properties
  # actually carry the endpoint, so the export never fabricates a URL the
  # substrate didn't serve.
  defp outputs_for(_type, kind, _sym, _props)
       when kind in [:resource_group, :servicebus_queue, :generic],
       do: []

  defp outputs_for(type, :storage_account, sym, props) do
    tf_type = Map.fetch!(@tf_type_by_kind, kind_ref(type))

    endpoint =
      case props["primaryEndpoints"] do
        %{"blob" => _} ->
          [
            %{
              name: sym <> "_primary_blob_endpoint",
              bicep: "#{sym}.properties.primaryEndpoints.blob",
              tf: "#{tf_type}.#{sym}.primary_blob_endpoint",
              sensitive: false
            }
          ]

        _ ->
          []
      end

    endpoint ++
      [
        %{
          name: sym <> "_primary_access_key",
          bicep: "#{sym}.listKeys().keys[0].value",
          tf: "#{tf_type}.#{sym}.primary_access_key",
          sensitive: true
        }
      ]
  end

  defp outputs_for(type, :key_vault, sym, props) do
    tf_type = Map.fetch!(@tf_type_by_kind, kind_ref(type))

    case bin_or_nil(props["vaultUri"]) do
      nil ->
        []

      _uri ->
        [
          %{
            name: sym <> "_vault_uri",
            bicep: "#{sym}.properties.vaultUri",
            tf: "#{tf_type}.#{sym}.vault_uri",
            sensitive: false
          }
        ]
    end
  end

  defp outputs_for(type, ns_kind, sym, props) when ns_kind in @namespace_kinds do
    tf_type = Map.fetch!(@tf_type_by_kind, kind_ref(type))

    case bin_or_nil(props["serviceBusEndpoint"]) do
      nil ->
        []

      _endpoint ->
        [
          %{
            name: sym <> "_servicebus_endpoint",
            bicep: "#{sym}.properties.serviceBusEndpoint",
            tf: "#{tf_type}.#{sym}.hostname",
            sensitive: false
          }
        ]
    end
  end

  defp outputs_for(type, :cosmos_account, sym, props) do
    tf_type = Map.fetch!(@tf_type_by_kind, kind_ref(type))

    endpoint =
      case bin_or_nil(props["documentEndpoint"]) do
        nil ->
          []

        _ep ->
          [
            %{
              name: sym <> "_document_endpoint",
              bicep: "#{sym}.properties.documentEndpoint",
              tf: "#{tf_type}.#{sym}.endpoint",
              sensitive: false
            }
          ]
      end

    endpoint ++
      [
        %{
          name: sym <> "_primary_master_key",
          bicep: "#{sym}.listKeys().primaryMasterKey",
          tf: "#{tf_type}.#{sym}.primary_master_key",
          sensitive: true
        }
      ]
  end

  # kind atom for the canonical type string (outputs_for receives the
  # canonical type; recover the kind so the tf address uses the same map).
  defp kind_ref(type), do: Map.fetch!(@kind_by_type, type)

  # ================================================================================
  # bicep renderer
  # ================================================================================

  @doc """
  Renders the model as bicep: `%{"main.bicep" => body}`. Subscription-scoped
  (the exported graph includes its resource groups), real resource type
  strings, symbolic names, declarative properties, and the model's outputs
  verbatim.
  """
  @spec render_bicep(model()) :: %{String.t() => String.t()}
  def render_bicep(model) do
    others =
      Enum.filter(
        model.resources,
        &(&1.kind not in [:resource_group | @namespace_kinds] and &1.kind != :servicebus_queue)
      )

    body =
      [
        "targetScope = 'subscription'",
        "",
        bicep_header_comment(),
        "",
        bicep_section("// --- resource groups ---", bicep_of_kind(model.resources, :resource_group)),
        bicep_section(
          "// --- referenced (existing) resource groups ---",
          model.synthetic |> Enum.filter(&(&1.kind == :resource_group)) |> Enum.map(&bicep_resource/1)
        ),
        bicep_section("// --- namespaces ---", bicep_of_kinds(model.resources, @namespace_kinds)),
        bicep_section(
          "// --- referenced (existing) namespaces ---",
          model.synthetic |> Enum.filter(&(&1.kind in @namespace_kinds)) |> Enum.map(&bicep_resource/1)
        ),
        bicep_section("// --- other top-level resources ---", Enum.map(others, &bicep_resource/1)),
        bicep_section(
          "// --- child resources ---",
          model.resources |> Enum.filter(&(&1.kind == :servicebus_queue)) |> Enum.map(&bicep_resource/1)
        ),
        bicep_outputs_section(model.outputs)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    %{"main.bicep" => body}
  end

  defp bicep_header_comment do
    "# Generated by `mix smalt.export --format bicep` from the :smalt_resources projection\n" <>
      "# (Smalt.DataPlane.IacExport.intermediate_model/1) — the ONE walk both export formats render.\n" <>
      "# provisioningState is runtime state and is deliberately not re-declared."
  end

  defp bicep_of_kind(entries, kind), do: entries |> Enum.filter(&(&1.kind == kind)) |> Enum.map(&bicep_resource/1)

  defp bicep_of_kinds(entries, kinds),
    do: entries |> Enum.filter(&(&1.kind in kinds)) |> Enum.map(&bicep_resource/1)

  defp bicep_section(_header, []), do: nil
  defp bicep_section(header, blocks), do: [header, Enum.join(blocks, "\n\n")] |> Enum.join("\n")

  defp bicep_outputs_section([]), do: nil

  defp bicep_outputs_section(outputs) do
    lines = Enum.map(outputs, fn out -> "output #{out.name} string = #{out.bicep}" end)
    bicep_section("// --- outputs ---", [Enum.join(lines, "\n")])
  end

  defp bicep_resource(entry) do
    decl =
      if entry.existing do
        "resource #{entry.symbolic_name} '#{entry.type}@#{entry.api_version}' existing = {"
      else
        "resource #{entry.symbolic_name} '#{entry.type}@#{entry.api_version}' = {"
      end

    lines =
      [decl] ++
        bicep_scope_parent_lines(entry) ++
        ["  name: " <> bicep_literal(entry.name, 0, :bicep)] ++
        bicep_location_line(entry) ++
        bicep_extras(entry) ++
        bicep_properties_lines(entry) ++
        ["}"]

    Enum.join(lines, "\n")
  end

  # bicep forbids `scope` and `parent` on the same resource: a child's
  # `parent` already determines its scope (the parent carries the RG scope),
  # so parent wins and scope is emitted only for parentless entries.
  defp bicep_scope_parent_lines(%{parent: parent}) when parent != nil,
    do: ["  parent: #{parent.symbolic_name}"]

  defp bicep_scope_parent_lines(%{scope: scope}) when scope != nil,
    do: ["  scope: #{scope.symbolic_name}"]

  defp bicep_scope_parent_lines(_), do: []

  defp bicep_location_line(%{existing: true}), do: []

  defp bicep_location_line(%{location: loc}) when is_binary(loc),
    do: ["  location: " <> bicep_literal(loc, 0, :bicep)]

  defp bicep_location_line(_), do: []

  # Per-kind scaffolding: known types carry the required non-properties
  # surface (sku/kind) with stored values first and safe defaults where the
  # row carried none — a stub tier default is a disclosed default, never a
  # fabricated claim about the live resource.
  defp bicep_extras(%{existing: true}), do: []
  defp bicep_extras(%{kind: :resource_group}), do: []

  defp bicep_extras(%{kind: :storage_account} = entry) do
    kind = if is_binary(entry.arm_kind), do: entry.arm_kind, else: "StorageV2"

    [
      "  kind: " <> bicep_literal(kind, 0, :bicep),
      "  sku: { name: " <> bicep_literal(sku_name(entry, "Standard_LRS"), 0, :bicep) <> " }"
    ]
  end

  defp bicep_extras(%{kind: :key_vault} = entry) do
    family =
      if is_map(entry.sku) and is_binary(entry.sku["family"]) and entry.sku["family"] != "",
        do: entry.sku["family"],
        else: "A"

    [
      "  sku: { family: " <> bicep_literal(family, 0, :bicep) <>
        ", name: " <> bicep_literal(sku_name(entry, "standard"), 0, :bicep) <> " }"
    ]
  end

  defp bicep_extras(%{kind: ns_kind} = entry) when ns_kind in @namespace_kinds do
    ["  sku: { name: " <> bicep_literal(sku_name(entry, "Standard"), 0, :bicep) <> " }"]
  end

  defp bicep_extras(%{kind: :cosmos_account}), do: []
  defp bicep_extras(%{kind: :servicebus_queue}), do: []
  defp bicep_extras(%{kind: :generic}), do: []

  defp sku_name(%{sku: sku}, default) when is_map(sku) do
    case bin_or_nil(sku["name"]) do
      nil -> default
      name -> name
    end
  end

  defp sku_name(_entry, default), do: default

  defp bicep_properties_lines(%{existing: true}), do: []

  defp bicep_properties_lines(%{kind: :cosmos_account} = entry) do
    props = cosmos_properties(entry)
    if map_size(props) == 0, do: [], else: ["  properties: " <> bicep_literal(props, 1, :bicep)]
  end

  defp bicep_properties_lines(%{properties: props}) do
    if map_size(props) == 0, do: [], else: ["  properties: " <> bicep_literal(props, 1, :bicep)]
  end

  # Cosmos requires databaseAccountOfferType + locations; the stub tier
  # fills them from the stored properties first, then defaults (stored
  # values win, defaults are disclosed stub defaults).
  defp cosmos_properties(entry) do
    entry.properties
    |> Map.put_new("databaseAccountOfferType", "Standard")
    |> Map.update("consistencyPolicy", %{"defaultConsistencyLevel" => "Session"}, fn cp ->
      if is_map(cp), do: Map.put_new(cp, "defaultConsistencyLevel", "Session"), else: cp
    end)
    |> put_new_cosmos_locations(entry.location)
  end

  defp put_new_cosmos_locations(props, loc) when is_binary(loc),
    do: Map.put_new(props, "locations", [%{"locationName" => loc, "failoverPriority" => 0}])

  defp put_new_cosmos_locations(props, _loc), do: props

  # Literal renderer shared by both dialects (:bicep single-quote strings,
  # `key: value` maps; :hcl double-quote strings, `key = value` maps).
  defp bicep_literal(value, indent_level, :bicep), do: literal(value, indent_level, :bicep)

  defp literal(value, i, style)
  defp literal(v, _i, :bicep) when is_binary(v), do: quote_bicep(v)
  defp literal(v, _i, :hcl) when is_binary(v), do: quote_hcl(v)
  defp literal(v, _i, _s) when is_integer(v), do: Integer.to_string(v)
  defp literal(true, _i, _s), do: "true"
  defp literal(false, _i, _s), do: "false"
  defp literal(nil, _i, _s), do: "null"

  defp literal(v, i, s) when is_list(v),
    do: "[" <> Enum.map_join(v, ", ", &literal(&1, i, s)) <> "]"

  defp literal(v, _i, _s) when is_map(v) and map_size(v) == 0, do: "{}"

  defp literal(v, i, s) when is_map(v) do
    pad_in = String.duplicate("  ", i + 1)
    pad_out = String.duplicate("  ", i)

    inner =
      v
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join("\n", fn {k, val} ->
        pad_in <> literal_key(k) <> literal_sep(s) <> literal(val, i + 1, s)
      end)

    "{\n" <> inner <> "\n" <> pad_out <> "}"
  end

  defp literal_key(k) when is_binary(k),
    do: k |> String.replace("\"", "") |> String.replace("'", "")

  defp literal_key(k), do: literal_key(to_string(k))

  defp literal_sep(:bicep), do: ": "
  defp literal_sep(:hcl), do: " = "

  defp quote_bicep(v),
    do: "'" <> (v |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"

  defp quote_hcl(v),
    do: "\"" <> (v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

  # ================================================================================
  # terraform renderer (azurerm HCL + terraform.tfvars stub)
  # ================================================================================

  @doc """
  Renders the model as terraform: `%{"main.tf" => hcl, "terraform.tfvars" => stub}`.
  Names and locations ride `var.*` — the tfvars stub carries their literal
  values (the ticket's tfvars stub: names/locations) — plus a placeholder
  `tenant_id` when a Key Vault is exported (azurerm_key_vault requires it).
  """
  @spec render_terraform(model()) :: %{String.t() => String.t()}
  def render_terraform(model) do
    rendered = model.resources ++ model.synthetic
    has_generic? = Enum.any?(rendered, &(&1.kind == :generic))
    has_kv? = Enum.any?(rendered, &(&1.kind == :key_vault))

    main_tf =
      [
        tf_header_comment(),
        tf_providers(has_generic?),
        tf_variables(rendered, has_kv?),
        tf_section("# --- resource groups ---", tf_of_kind(rendered, :resource_group)),
        tf_section("# --- namespaces ---", tf_of_kinds(rendered, @namespace_kinds)),
        tf_section(
          "# --- other top-level resources ---",
          rendered
          |> Enum.filter(
            &(&1.kind not in [:resource_group | @namespace_kinds] and &1.kind != :servicebus_queue)
          )
          |> Enum.map(&tf_block/1)
        ),
        tf_section(
          "# --- child resources ---",
          rendered |> Enum.filter(&(&1.kind == :servicebus_queue)) |> Enum.map(&tf_block/1)
        ),
        tf_outputs_section(model.outputs)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %{"main.tf" => main_tf, "terraform.tfvars" => tfvars(rendered, has_kv?)}
  end

  defp tf_header_comment do
    "# main.tf — generated by `mix smalt.export --format terraform` from the :smalt_resources projection\n" <>
      "# (Smalt.DataPlane.IacExport.intermediate_model/1) — the ONE walk both export formats render.\n" <>
      "# Names/locations ride var.* (see terraform.tfvars); provisioningState is runtime state,\n" <>
      "# deliberately not re-declared."
  end

  defp tf_providers(has_generic?) do
    azurerm_lines = [
      "terraform {",
      "  required_providers {",
      "    azurerm = {",
      "      source  = \"hashicorp/azurerm\"",
      "      version = \"~> 3.0\"",
      "    }"
    ]

    azurerm_lines =
      if has_generic? do
        azurerm_lines ++
          [
            "    azapi = {",
            "      source  = \"Azure/azapi\"",
            "      version = \"~> 1.0\"",
            "    }"
          ]
      else
        azurerm_lines
      end

    Enum.join(azurerm_lines ++ ["  }", "}", "", "provider \"azurerm\" {", "  features {}", "}"], "\n")
  end

  defp tf_variables([], _has_kv?), do: nil

  defp tf_variables(rendered, has_kv?) do
    vars =
      rendered
      |> Enum.flat_map(fn entry ->
        base = ["#{entry.symbolic_name}_name"]
        if entry.location, do: base ++ ["#{entry.symbolic_name}_location"], else: base
      end)
      |> Enum.sort()
      |> maybe_prepend_tenant(has_kv?)
      |> Enum.map(fn var -> "variable \"#{var}\" {\n  type = string\n}" end)

    tf_section("# --- variables ---", [Enum.join(vars, "\n\n")])
  end

  defp maybe_prepend_tenant(vars, true), do: ["tenant_id" | vars]
  defp maybe_prepend_tenant(vars, false), do: vars

  defp tf_of_kind(rendered, kind), do: rendered |> Enum.filter(&(&1.kind == kind)) |> Enum.map(&tf_block/1)

  defp tf_of_kinds(rendered, kinds), do: rendered |> Enum.filter(&(&1.kind in kinds)) |> Enum.map(&tf_block/1)

  defp tf_section(_header, []), do: nil
  defp tf_section(header, blocks), do: [header, Enum.join(blocks, "\n\n")] |> Enum.join("\n")

  defp tf_outputs_section([]), do: nil

  defp tf_outputs_section(outputs) do
    blocks =
      Enum.map(outputs, fn out ->
        if out.sensitive do
          Enum.join(
            [
              "output \"#{out.name}\" {",
              "  value     = #{out.tf}",
              "  sensitive = true",
              "}"
            ],
            "\n"
          )
        else
          Enum.join(["output \"#{out.name}\" {", "  value = #{out.tf}", "}"], "\n")
        end
      end)

    tf_section("# --- outputs ---", blocks)
  end

  defp tf_block(entry) do
    cond do
      entry.kind == :resource_group and entry.existing -> tf_data_resource_group(entry)
      entry.kind == :resource_group -> tf_resource_group(entry)
      entry.kind in @namespace_kinds and entry.existing -> tf_data_namespace(entry)
      entry.kind == :servicebus_namespace -> tf_namespace(entry, "azurerm_servicebus_namespace")
      entry.kind == :eventhub_namespace -> tf_namespace(entry, "azurerm_eventhub_namespace")
      entry.kind == :storage_account -> tf_storage(entry)
      entry.kind == :key_vault -> tf_key_vault(entry)
      entry.kind == :cosmos_account -> tf_cosmos(entry)
      entry.kind == :servicebus_queue -> tf_queue(entry)
      entry.kind == :generic -> tf_generic(entry)
    end
  end

  # "azurerm_resource_group.rg.name" for an exported parent row;
  # "data.azurerm_resource_group.rg.name" for a synthesized existing one.
  defp tf_rg_name_expr(nil), do: nil

  defp tf_rg_name_expr(%{existing: true, symbolic_name: sym}),
    do: "data.azurerm_resource_group.#{sym}.name"

  defp tf_rg_name_expr(%{existing: false, symbolic_name: sym}),
    do: "azurerm_resource_group.#{sym}.name"

  defp tf_rg_id_expr(%{existing: true, symbolic_name: sym}),
    do: "data.azurerm_resource_group.#{sym}.id"

  defp tf_rg_id_expr(%{existing: false, symbolic_name: sym}),
    do: "azurerm_resource_group.#{sym}.id"

  defp tf_ns_id_expr(%{existing: true, symbolic_name: sym}),
    do: "data.azurerm_servicebus_namespace.#{sym}.id"

  defp tf_ns_id_expr(%{existing: false, symbolic_name: sym}),
    do: "azurerm_servicebus_namespace.#{sym}.id"

  defp assignments([]), do: []

  defp assignments(pairs) do
    width = pairs |> Enum.map(fn {k, _} -> String.length(k) end) |> Enum.max()

    Enum.map(pairs, fn {k, v} -> "  " <> String.pad_trailing(k, width) <> " = " <> v end)
  end

  defp tf_resource_group(entry) do
    pairs =
      [{"name", "var.#{entry.symbolic_name}_name"}] ++
        location_pairs(entry) ++
        (if entry.scope, do: [{"resource_group_name", tf_rg_name_expr(entry.scope)}], else: [])

    block("resource \"azurerm_resource_group\" \"#{entry.symbolic_name}\"", assignments(pairs))
  end

  defp tf_data_resource_group(entry) do
    block("data \"azurerm_resource_group\" \"#{entry.symbolic_name}\"", [
      {"name", "var.#{entry.symbolic_name}_name"}
    ])
  end

  defp tf_data_namespace(entry) do
    rg_expr =
      if entry.scope,
        do: tf_rg_name_expr(entry.scope),
        else: "var.#{entry.symbolic_name}_name"

    block(
      "data \"azurerm_servicebus_namespace\" \"#{entry.symbolic_name}\"",
      assignments([
        {"name", "var.#{entry.symbolic_name}_name"},
        {"resource_group_name", rg_expr}
      ])
    )
  end

  defp tf_namespace(entry, tf_type) do
    pairs =
      [
        {"name", "var.#{entry.symbolic_name}_name"},
        {"resource_group_name", tf_rg_name_expr(entry.scope)}
      ] ++
        location_pairs(entry) ++
        [{"sku", tf_string(sku_name(entry, "Standard"))}]

    block("resource \"#{tf_type}\" \"#{entry.symbolic_name}\"", assignments(pairs))
  end

  defp tf_storage(entry) do
    {tier, replication} = storage_tier_replication(entry)

    pairs =
      [
        {"name", "var.#{entry.symbolic_name}_name"},
        {"resource_group_name", tf_rg_name_expr(entry.scope)}
      ] ++
        location_pairs(entry) ++
        [
          {"account_tier", tf_string(tier)},
          {"account_replication_type", tf_string(replication)},
          {"account_kind", tf_string(if is_binary(entry.arm_kind), do: entry.arm_kind, else: "StorageV2")}
        ]

    block("resource \"azurerm_storage_account\" \"#{entry.symbolic_name}\"", assignments(pairs))
  end

  # "Standard_LRS" -> {"Standard", "LRS"}; an unrecognized/missing sku name
  # falls back to the standard tier with LRS replication (stub-tier default,
  # disclosed in the receipt).
  defp storage_tier_replication(entry) do
    case sku_name(entry, nil) do
      name when is_binary(name) ->
        case String.split(name, "_") do
          [tier, replication] -> {tier, replication}
          [tier, replication | _] -> {tier, replication}
          _ -> {"Standard", "LRS"}
        end

      _ ->
        {"Standard", "LRS"}
    end
  end

  defp tf_key_vault(entry) do
    pairs =
      [
        {"name", "var.#{entry.symbolic_name}_name"},
        {"resource_group_name", tf_rg_name_expr(entry.scope)}
      ] ++
        location_pairs(entry) ++
        [
          {"sku_name", tf_string(sku_name(entry, "standard"))},
          {"tenant_id", "var.tenant_id"}
        ]

    block("resource \"azurerm_key_vault\" \"#{entry.symbolic_name}\"", assignments(pairs))
  end

  defp tf_cosmos(entry) do
    props = entry.properties

    offer =
      if is_binary(props["databaseAccountOfferType"]), do: props["databaseAccountOfferType"], else: "Standard"

    consistency =
      case props["consistencyPolicy"] do
        %{"defaultConsistencyLevel" => level} when is_binary(level) -> level
        _ -> "Session"
      end

    head =
      assignments(
        [
          {"name", "var.#{entry.symbolic_name}_name"},
          {"resource_group_name", tf_rg_name_expr(entry.scope)}
        ] ++
          location_pairs(entry) ++
          [
            {"offer_type", tf_string(offer)},
            {"kind", tf_string("GlobalDocumentDB")}
          ]
      )

    nested =
      [
        "",
        "  consistency_policy {",
        "    consistency_level = " <> tf_string(consistency),
        "  }"
      ] ++ geo_location_lines(entry)

    block("resource \"azurerm_cosmosdb_account\" \"#{entry.symbolic_name}\"", head ++ nested)
  end

  defp geo_location_lines(%{location: loc, symbolic_name: sym}) when is_binary(loc) do
    [
      "",
      "  geo_location {",
      "    location          = var.#{sym}_location",
      "    failover_priority = 0",
      "  }"
    ]
  end

  defp geo_location_lines(_), do: []

  defp tf_queue(entry) do
    block(
      "resource \"azurerm_servicebus_queue\" \"#{entry.symbolic_name}\"",
      assignments([
        {"name", "var.#{entry.symbolic_name}_name"},
        {"namespace_id", tf_ns_id_expr(entry.parent)}
      ])
    )
  end

  defp tf_generic(entry) do
    pairs =
      [
        {"type", tf_string("#{entry.type}@#{entry.api_version}")},
        {"name", "var.#{entry.symbolic_name}_name"}
      ] ++
        (if entry.scope, do: [{"parent_id", tf_rg_id_expr(entry.scope)}], else: []) ++
        (if entry.location, do: [{"location", "var.#{entry.symbolic_name}_location"}], else: [])

    body =
      if map_size(entry.properties) == 0 do
        "  body = jsonencode({})"
      else
        "  body = jsonencode({\n    properties = " <> literal(entry.properties, 2, :hcl) <> "\n  })"
      end

    block("resource \"azapi_resource\" \"#{entry.symbolic_name}\"", assignments(pairs) ++ [body])
  end

  defp location_pairs(%{location: loc, symbolic_name: sym}) when is_binary(loc),
    do: [{"location", "var.#{sym}_location"}]

  defp location_pairs(_), do: []

  defp tf_string(v), do: literal(v, 0, :hcl)

  defp block(header, []), do: header

  defp block(header, lines), do: header <> " {\n" <> Enum.join(lines, "\n") <> "\n}"

  defp tfvars(rendered, has_kv?) do
    header =
      "# terraform.tfvars — generated by `mix smalt.export --format terraform`.\n" <>
        "# Stub carrying the exported world's names and locations (see main.tf var.*).\n" <>
        "# tenant_id is a PLACEHOLDER — set your tenant guid before plan/apply when a Key Vault\n" <>
        "# is exported (azurerm_key_vault requires it)."

    rows =
      rendered
      |> Enum.sort_by(& &1.symbolic_name)
      |> Enum.flat_map(fn entry ->
        base = [tfvars_line("#{entry.symbolic_name}_name", entry.name)]

        if entry.location,
          do: base ++ [tfvars_line("#{entry.symbolic_name}_location", entry.location)],
          else: base
      end)

    rows =
      if has_kv?,
        do: rows ++ [tfvars_line("tenant_id", "00000000-0000-0000-0000-000000000000")],
        else: rows

    header <> "\n\n" <> Enum.join(rows, "\n") <> "\n"
  end

  defp tfvars_line(name, value), do: "#{name} = " <> literal(value, 0, :hcl)
end
