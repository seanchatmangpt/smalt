defmodule Smalt.Enclave.Engine do
  @moduledoc """
  Topological execution engine for the tf_enclave: builds the dependency DAG
  from `{:ref, label, attr}` terms, orders resources topologically, and
  provisions each IN-PROCESS through the ARM gateway router — no sockets,
  no TLS, no terraform binary.

  ## Input contract (consumed from `Smalt.Enclave.Hcl`)

  `apply/2` takes a list of resource terms, either maps or tuples:

      %{type: "azurerm_key_vault", label: :kv, attrs: %{name: "kv1", ...}}
      {:resource, "azurerm_key_vault", :kv, %{name: "kv1", ...}}

  Attr keys may be atoms or binaries; they are normalized to binaries.
  Any attr value (including values nested in maps/lists) may be a
  `{:ref, label, attr}` term naming another resource in the SAME set —
  e.g. `resource_group_name: {:ref, :rg, :name}`. Refs resolve against the
  referenced resource's DECLARED attrs (the azurerm interpolation semantic:
  `azurerm_resource_group.rg.name` is the declared name), so ordering is
  static and deterministic.

  ## Outcomes

      {:ok, outcomes}
      # outcomes: list of %{label:, type:, arm_type:, status:, id:} in apply
      # order; indexable via outcome_for/2

      {:error, {:duplicate_label, label}}
      {:error, {:cycle, [labels]}}
      {:error, {:missing_ref_target, label, ref_label}}
      {:error, {:unknown_ref_attr, label, ref_label, attr}}
      {:error, {:unknown_resource_type, type, label}}
      {:error, {:apply_failed, %{label:, type:, status:, code:, message:}}}

  `{:apply_failed, ...}` is the passthrough face of the gateway refusal:
  `code` is the ARM/GraphLaw envelope code verbatim (e.g.
  `InvalidResourceShape` for a SHACL refusal), so a GraphLaw-typed refusal
  travels to the caller without re-typing.
  """

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry

  @default_sub "00000000-0000-0000-0000-000000000000"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Plan + apply `resources` in dependency order. See the module doc for the
  input contract and outcome shapes.
  """
  def apply(resources, opts \\ [])

  def apply([], _opts), do: {:ok, []}

  def apply(resources, opts) when is_list(resources) do
    sub = Keyword.get(opts, :subscription_id, @default_sub)

    with {:ok, normalized} <- normalize(resources),
         {:ok, order} <- topo(normalized),
         {:ok, resolved} <- resolve_refs(normalized),
         :ok <- preflight(normalized, order) do
      run(normalized, resolved, order, sub, [])
    end
  end

  @doc "Outcome for `label` from an apply/2 result list."
  @spec outcome_for([map()], atom() | String.t()) :: map() | nil
  def outcome_for(outcomes, label) when is_list(outcomes) do
    Enum.find(outcomes, &(&1.label == to_string(label)))
  end

  # ---------------------------------------------------------------------------
  # Normalization: accept maps or {:resource, type, label, attrs} tuples
  # ---------------------------------------------------------------------------

  defp normalize(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn term, {:ok, acc} ->
      case norm_resource(term) do
        {:ok, res} ->
          if Map.has_key?(acc, res.label) do
            {:halt, {:error, {:duplicate_label, res.label}}}
          else
            {:cont, {:ok, Map.put(acc, res.label, res)}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp norm_resource(%{type: type, label: label, attrs: attrs})
       when is_binary(type) and is_map(attrs) do
    {:ok, %{type: type, label: norm_label(label), attrs: stringy_keys(attrs)}}
  end

  defp norm_resource({:resource, type, label, attrs})
       when is_binary(type) and is_map(attrs) do
    {:ok, %{type: type, label: norm_label(label), attrs: stringy_keys(attrs)}}
  end

  defp norm_resource(other), do: {:error, {:malformed_resource, other}}

  defp norm_label(label) when is_atom(label), do: Atom.to_string(label)
  defp norm_label(label) when is_binary(label), do: label

  defp stringy_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  # ---------------------------------------------------------------------------
  # Ref resolution: {:ref, label, attr} -> the target's declared attr value
  # ---------------------------------------------------------------------------

  defp resolve_refs(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn {label, res}, {:ok, acc} ->
      case walk_refs(res.attrs, label, resources, MapSet.new()) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, label, resolved)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # SHIM-COURT: visited-set guards against cyclic ref chains (a self-ref or
  # mutual ref within attr values would otherwise loop forever; topo cannot
  # catch these because it deliberately drops self-edges from the DAG).
  defp walk_refs({:ref, target, attr}, from, resources, seen) do
    target = to_string(target)
    attr = to_string(attr)
    key = {target, attr}

    if MapSet.member?(seen, key) do
      {:error, {:cycle, key}}
    else
      case Map.fetch(resources, target) do
        :error ->
          {:error, {:missing_ref_target, from, target}}

        {:ok, %{attrs: attrs}} ->
          case Map.fetch(attrs, attr) do
            :error -> {:error, {:unknown_ref_attr, from, target, attr}}
            {:ok, value} -> walk_refs(value, from, resources, MapSet.put(seen, key))
          end
      end
    end
  end

  defp walk_refs(map, from, resources, seen) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case walk_refs(v, from, resources, seen) do
        {:ok, rv} -> {:cont, {:ok, Map.put(acc, k, rv)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp walk_refs(list, from, resources, seen) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      case walk_refs(v, from, resources, seen) do
        {:ok, rv} -> {:cont, {:ok, [rv | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp walk_refs(value, _from, _resources, _seen), do: {:ok, value}

  # ---------------------------------------------------------------------------
  # DAG construction + topological order (Kahn; ready set sorted by label so
  # the order is deterministic for a given resource set)
  # ---------------------------------------------------------------------------

  defp ref_targets(value) when is_map(value) do
    Enum.flat_map(value, fn {_k, v} -> ref_targets(v) end)
  end

  defp ref_targets(value) when is_list(value), do: Enum.flat_map(value, &ref_targets/1)
  defp ref_targets({:ref, target, _attr}), do: [to_string(target)]
  defp ref_targets(_), do: []

  defp topo(resources) do
    known = MapSet.new(Map.keys(resources))

    deps =
      Map.new(resources, fn {label, res} ->
        {label,
         res.attrs
         |> ref_targets()
         |> MapSet.new()
         # Unknown ref targets are not DAG nodes — resolve_refs reports them
         # typed ({:missing_ref_target}); topo must not turn them into cycles.
         |> MapSet.intersection(known)
         |> MapSet.delete(label)}
      end)

    remaining = resources |> Map.keys() |> Enum.sort()

    kahn(deps, [], remaining)
  end

  defp kahn(_deps, order, []), do: {:ok, Enum.reverse(order)}

  defp kahn(deps, order, remaining) do
    placed = MapSet.new(order)

    ready =
      remaining
      |> Enum.filter(&MapSet.subset?(Map.fetch!(deps, &1), placed))
      |> Enum.sort()

    case ready do
      [] -> {:error, {:cycle, Enum.sort(remaining)}}
      _ -> kahn(deps, Enum.reverse(ready, order), remaining -- ready)
    end
  end

  # ---------------------------------------------------------------------------
  # Preflight: every resource type must be in the azurerm->ARM mapping table
  # ---------------------------------------------------------------------------

  defp preflight(resources, order) do
    Enum.find_value(order, fn label ->
      res = Map.fetch!(resources, label)

      case arm_type(res.type) do
        {:ok, _} ->
          # SHIM-COURT: attr-completeness preflight — a resource missing a
          # required attr surfaces typed here instead of as a KeyError from
          # arm_target/4 (contract: all-failures-typed).
          case required_attrs(res.type) -- Map.keys(res.attrs) do
            [] -> nil
            [missing | _] -> {:error, {:missing_attr, label, missing}}
          end

        :error ->
          {:error, {:unknown_resource_type, res.type, label}}
      end
    end) || :ok
  end

  # Attrs arm_target/4 clauses Map.fetch! unconditionally. Keep in sync with
  # the arm_target clause heads.
  defp required_attrs("azurerm_resource_group"), do: ["name"]
  defp required_attrs("azurerm_key_vault"), do: ["name", "resource_group_name", "tenant_id"]
  defp required_attrs("azurerm_storage_account"), do: ["name", "resource_group_name"]

  defp required_attrs("azurerm_storage_container"),
    do: ["name", "resource_group_name", "account_name"]

  defp required_attrs("azurerm_cosmosdb_account"), do: ["name", "resource_group_name"]

  defp required_attrs("azurerm_cosmosdb_sql_database"),
    do: ["name", "resource_group_name", "account_name"]

  defp required_attrs("azurerm_cosmosdb_sql_container"),
    do: ["name", "resource_group_name", "account_name", "database_name"]

  defp required_attrs("azurerm_eventhub_namespace"), do: ["name"]
  defp required_attrs("azurerm_eventhub"), do: ["name", "resource_group_name", "namespace_name"]

  defp required_attrs("azurerm_servicebus_namespace"), do: ["name"]

  defp required_attrs("azurerm_servicebus_queue"),
    do: ["name", "resource_group_name", "namespace_name"]

  # Passthrough: ARM-form types need scope + name like every child.
  defp required_attrs("Microsoft." <> _rest), do: ["name", "resource_group_name"]

  defp required_attrs(_), do: []

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  defp run(resources, resolved, order, sub, acc) do
    order
    |> Enum.reduce_while({:ok, acc}, fn label, {:ok, outcomes} ->
      res = Map.fetch!(resources, label)
      attrs = Map.fetch!(resolved, label)

      case dispatch(sub, res, attrs) do
        {:ok, outcome} -> {:cont, {:ok, [outcome | outcomes]}}
        {:error, failure} -> {:halt, {:error, {:apply_failed, failure}}}
      end
    end)
    |> case do
      {:ok, outcomes} -> {:ok, Enum.reverse(outcomes)}
      err -> err
    end
  end

  defp dispatch(sub, %{type: type, label: label}, attrs) do
    with {:ok, arm_type} <- arm_type(type),
         {path, body} <- arm_target(type, arm_type, attrs, sub) do
      api_version = Registry.latest_version(arm_type) || "2021-04-01"

      conn =
        Plug.Test.conn(:put, path <> "?api-version=" <> api_version, body)
        |> Router.call(Router.init([]))

      case conn.status do
        status when status in 200..299 ->
          {:ok,
           %{
             label: label,
             type: type,
             arm_type: arm_type,
             status: status,
             id: response_id(conn, path)
           }}

        status ->
          {:error, apply_failure(label, type, status, conn)}
      end
    else
      {:error, _} = err -> err
    end
  end

  # The LRO face of a storage-account create returns the OPERATION id in the
  # body (an /operations/... URL), which is NOT the resource id. Accept the
  # body id only when it is a resource record (has both "id" and "type" —
  # child records carry the router's own canonical id); else the PUT path.
  defp response_id(conn, path) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{"id" => id, "type" => _type}} when is_binary(id) -> id
      _ -> path |> String.split("?") |> List.first()
    end
  rescue
    _ -> path |> String.split("?") |> List.first()
  end

  defp apply_failure(label, type, status, conn) do
    {code, message} =
      case Jason.decode(conn.resp_body) do
        {:ok, %{"error" => %{"code" => code, "message" => message}}} ->
          {code, message}

        _ ->
          {"Unknown", inspect(conn.resp_body, limit: 40)}
      end

    %{label: label, type: type, status: status, code: code, message: message}
  end

  # ---------------------------------------------------------------------------
  # azurerm -> ARM mapping table (one clause per azurerm type; the ggen
  # projection replaces this table, so keep each clause flat and literal)
  # ---------------------------------------------------------------------------

  defp arm_type("azurerm_resource_group"), do: {:ok, "Microsoft.Resources/resourceGroups"}
  defp arm_type("azurerm_key_vault"), do: {:ok, "Microsoft.KeyVault/vaults"}
  defp arm_type("azurerm_storage_account"), do: {:ok, "Microsoft.Storage/storageAccounts"}

  defp arm_type("azurerm_storage_container"),
    do: {:ok, "Microsoft.Storage/storageAccounts/blobServices/containers"}

  defp arm_type("azurerm_cosmosdb_account"), do: {:ok, "Microsoft.DocumentDB/databaseAccounts"}

  defp arm_type("azurerm_cosmosdb_sql_database"),
    do: {:ok, "Microsoft.DocumentDB/databaseAccounts/sqlDatabases"}

  defp arm_type("azurerm_cosmosdb_sql_container"),
    do: {:ok, "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/sqlContainers"}

  defp arm_type("azurerm_eventhub_namespace"), do: {:ok, "Microsoft.EventHub/namespaces"}
  defp arm_type("azurerm_eventhub"), do: {:ok, "Microsoft.EventHub/namespaces/eventhubs"}

  defp arm_type("azurerm_servicebus_namespace"), do: {:ok, "Microsoft.ServiceBus/namespaces"}
  defp arm_type("azurerm_servicebus_queue"), do: {:ok, "Microsoft.ServiceBus/namespaces/queues"}
  # ---------------------------------------------------------------------------
  # Passthrough clause: types already in ARM form ("Microsoft.*") ride the
  # generic provider route verbatim — the gateway's GraphLaw gate is the
  # authority, and a refused type surfaces as the typed apply_failed face.
  # MUST precede the catch-all.
  # ---------------------------------------------------------------------------

  defp arm_type("Microsoft." <> _rest = arm_type), do: {:ok, arm_type}
  defp arm_type(_), do: :error

  # Path + body per type. Child resources read their parent scope from the
  # ref-resolved attrs (resource_group_name / account_name / namespace_name).
  # SHIM-COURT unblock (lane405): arm_type unused in this head; underscore per SLA.
  defp arm_target("azurerm_resource_group", _arm_type, attrs, sub) do
    name = Map.fetch!(attrs, "name")
    location = Map.get(attrs, "location", "smalt-local")

    body =
      %{"location" => location}
      |> maybe_put("name", name)
      |> maybe_put("tags", Map.get(attrs, "tags"))

    {rg_path(sub, name), body}
  end

  defp arm_target("azurerm_key_vault", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    properties =
      %{
        "tenantId" => Map.fetch!(attrs, "tenant_id"),
        "sku" => %{"family" => "A", "name" => Map.get(attrs, "sku_name", "standard")}
      }
      |> maybe_put("enableSoftDelete", Map.get(attrs, "enable_soft_delete"))
      |> maybe_put("softDeleteRetentionInDays", Map.get(attrs, "soft_delete_retention_in_days"))
      |> maybe_put("enableRbacAuthorization", Map.get(attrs, "enable_rbac_authorization"))

    {provider_path(sub, rg, "Microsoft.KeyVault", "vaults", name),
     %{"location" => Map.get(attrs, "location", "smalt-local"), "properties" => properties}}
  end

  defp arm_target("azurerm_storage_account", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    tier = Map.get(attrs, "account_tier", "Standard")
    replication = Map.get(attrs, "account_replication_type", "LRS")

    sku_name = Map.get(attrs, "sku_name") || tier <> "_" <> replication

    {provider_path(sub, rg, "Microsoft.Storage", "storageAccounts", name),
     %{
       "location" => Map.get(attrs, "location", "smalt-local"),
       "sku" => %{"name" => sku_name},
       "kind" => Map.get(attrs, "kind", "StorageV2")
     }}
  end

  defp arm_target("azurerm_storage_container", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    account = Map.fetch!(attrs, "account_name")
    name = Map.fetch!(attrs, "name")

    {provider_path(sub, rg, "Microsoft.Storage", "storageAccounts", account) <>
       "/blobServices/default/containers/" <> name,
     %{"location" => Map.get(attrs, "location", "smalt-local")}}
  end

  defp arm_target("azurerm_cosmosdb_account", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    properties =
      %{"databaseAccountOfferType" => Map.get(attrs, "offer_type", "Standard")}
      |> maybe_put("consistencyPolicy", Map.get(attrs, "consistency_policy"))

    {provider_path(sub, rg, "Microsoft.DocumentDB", "databaseAccounts", name),
     %{
       "location" => Map.get(attrs, "location", "smalt-local"),
       "kind" => Map.get(attrs, "kind", "GlobalDocumentDB"),
       "properties" => properties
     }}
  end

  defp arm_target("azurerm_cosmosdb_sql_database", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    account = Map.fetch!(attrs, "account_name")
    name = Map.fetch!(attrs, "name")

    {provider_path(sub, rg, "Microsoft.DocumentDB", "databaseAccounts", account) <>
       "/sqlDatabases/" <> name, %{"location" => Map.get(attrs, "location", "smalt-local")}}
  end

  defp arm_target("azurerm_cosmosdb_sql_container", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    account = Map.fetch!(attrs, "account_name")
    database = Map.fetch!(attrs, "database_name")
    name = Map.fetch!(attrs, "name")

    {provider_path(sub, rg, "Microsoft.DocumentDB", "databaseAccounts", account) <>
       "/sqlDatabases/" <> database <> "/sqlContainers/" <> name,
     %{"location" => Map.get(attrs, "location", "smalt-local")}}
  end

  defp arm_target("azurerm_eventhub_namespace", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    sku = Map.get(attrs, "sku", "Standard")

    {provider_path(sub, rg, "Microsoft.EventHub", "namespaces", name),
     %{
       "location" => Map.get(attrs, "location", "smalt-local"),
       "sku" => %{"name" => sku, "tier" => Map.get(attrs, "sku_tier", sku)}
     }}
  end

  defp arm_target("azurerm_eventhub", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    namespace = Map.fetch!(attrs, "namespace_name")
    name = Map.fetch!(attrs, "name")

    properties =
      %{}
      |> maybe_put("partitionCount", Map.get(attrs, "partition_count"))
      |> maybe_put("messageRetentionInDays", Map.get(attrs, "message_retention_in_days"))

    {provider_path(sub, rg, "Microsoft.EventHub", "namespaces", namespace) <>
       "/eventhubs/" <> name,
     %{"location" => Map.get(attrs, "location", "smalt-local"), "properties" => properties}}
  end

  defp arm_target("azurerm_servicebus_namespace", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    sku = Map.get(attrs, "sku", "Standard")

    {provider_path(sub, rg, "Microsoft.ServiceBus", "namespaces", name),
     %{
       "location" => Map.get(attrs, "location", "smalt-local"),
       "sku" => %{"name" => sku, "tier" => Map.get(attrs, "sku_tier", sku)}
     }}
  end

  defp arm_target("azurerm_servicebus_queue", _arm_type, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    namespace = Map.fetch!(attrs, "namespace_name")
    name = Map.fetch!(attrs, "name")

    properties =
      %{}
      |> maybe_put("maxDeliveryCount", Map.get(attrs, "max_delivery_count"))
      |> maybe_put("lockDuration", Map.get(attrs, "lock_duration"))

    {provider_path(sub, rg, "Microsoft.ServiceBus", "namespaces", namespace) <> "/queues/" <> name,
     %{"location" => Map.get(attrs, "location", "smalt-local"), "properties" => properties}}
  end

  # -- path helpers -------------------------------------------------------------

  defp arm_target("Microsoft." <> _rest = arm_type, _arm_type_marker, attrs, sub) do
    rg = Map.fetch!(attrs, "resource_group_name")
    name = Map.fetch!(attrs, "name")

    {ns, kind} =
      case String.split(arm_type, "/", parts: 2) do
        [ns, kind] -> {ns, kind}
        ns -> {ns, ""}
      end

    {provider_path(sub, rg, ns, kind, name),
     %{"location" => Map.get(attrs, "location", "smalt-local")}}
  end

  defp rg_path(sub, name), do: "/subscriptions/#{sub}/resourceGroups/#{name}"

  defp provider_path(sub, rg, ns, kind, name) do
    rg_path(sub, rg) <> "/providers/#{ns}/#{kind}/#{name}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
