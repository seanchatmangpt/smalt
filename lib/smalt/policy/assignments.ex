defmodule Smalt.Policy.Assignments do

  @moduledoc """
  Role definitions, role assignments (RBAC), and policy assignments — the
  ARM faces that BIND principals/definitions to scopes.

  Role definitions are BUILT-IN (Owner / Contributor / Reader, well-known
  Azure GUIDs) and served deterministically — never stored, never fabricated
  per-caller.

  RBAC enforcement: `Smalt.Policy.authorize?/3` + `/4` resolve assignment
  scope prefixes (subscription > RG > resource) with inheritance; built-in
  role GUIDs map to verb sets via `role_verbs/1`.
  """

  alias Smalt.Policy.Store


  @builtin_roles [
    %{
      "guid" => "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
      "role_name" => "Owner"
    },
    %{
      "guid" => "b24988ac-6180-42a0-ab88-20f7382dd24c",
      "role_name" => "Contributor"
    },
    %{
      "guid" => "acdd72a7-3385-48ef-bd42-f606fba81ae7",
      "role_name" => "Reader"
    }
  ]
  # ===========================================================================
  # Built-in role definitions
  # ===========================================================================

  @doc """
  Serves a built-in role definition by role name or GUID. `{scope_prefix}`
  is the placement (e.g. "/subscriptions/sub-1"); the id is derived from it.
  """
  def role_definition(scope_prefix, name_or_guid) do
    key = String.downcase(name_or_guid)

    case Enum.find(@builtin_roles, fn role ->
           String.downcase(role["guid"]) == key or String.downcase(role["role_name"]) == key
         end) do
      nil ->
        :error

      role ->
        {:ok,
         %{
           "id" =>
             "#{scope_prefix}/providers/Microsoft.Authorization/roleDefinitions/#{role["guid"]}",
           "name" => role["guid"],
           "type" => "Microsoft.Authorization/roleDefinitions",
           "properties" => %{"roleName" => role["role_name"], "type" => "BuiltInRole"}
         }}
    end
  end
  # ===========================================================================
  # Role assignments (RBAC)
  # ===========================================================================

  def put_role_assignment(scope_prefix, name, body) do
    Store.ensure_tables()

    record = %{
      "id" => "#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}",
      "name" => name,
      "type" => "Microsoft.Authorization/roleAssignments",
      "properties" => %{
        "principalId" => get_in(body, ["properties", "principalId"]),
        "roleDefinitionId" => get_in(body, ["properties", "roleDefinitionId"]),
        "scope" => get_in(body, ["properties", "scope"]) || scope_prefix
      }
    }

    :ets.insert(:smalt_rbac, {String.downcase(record["id"]), record})
    record
  end

  def get_role_assignment(scope_prefix, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_rbac, String.downcase(ra_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_role_assignment(scope_prefix, name) do
    Store.ensure_tables()
    :ets.delete(:smalt_rbac, String.downcase(ra_id(scope_prefix, name)))
    :ok
  end

  def list_role_assignments(scope_prefix) do
    Store.ensure_tables()
    prefix = String.downcase("#{scope_prefix}/providers/microsoft.authorization/roleassignments/")

    :smalt_rbac
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    # KD-COVERS: KD-125 — the shared :smalt_policy table also holds rem:/rs: rows
    # with no "id" key — a nil there 500'd both list faces permanently
    # (witnessed 2026-10-20, substrate.log 18:02/18:09). Nil-safe filter.
    |> Enum.filter(fn r ->
      case r["id"] do
        nil -> false
        id -> String.downcase(id) |> String.starts_with?(prefix)
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp ra_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}"
  # ===========================================================================
  # RBAC enforcement (KD-COVERS: KD-113) — leg a
  # ===========================================================================

  @doc """
  Verb sets granted by each built-in role (KD-113 leg a generalization).
  Owner = everything incl. authorize; Contributor = write/read/delete;
  Reader = read.
  """
  def role_verbs("Owner"), do: [:read, :write, :delete, :authorize]
  def role_verbs("Contributor"), do: [:read, :write, :delete]
  def role_verbs("Reader"), do: [:read]
  def role_verbs(_), do: []

  defp role_name_for_guid(guid_low) do
    case Enum.find(@builtin_roles, fn r -> String.downcase(r["guid"]) == guid_low end) do
      nil -> nil
      role -> role["role_name"]
    end
  end

  @doc """
  Whether `principal_id` holds `role_definition_id` at a scope covering
  `resource_id` (KD-113 leg a). ARM scope-prefix inheritance: a subscription-
  scope assignment covers every RG/resource under it, an RG-scope assignment
  covers every resource in the RG, an exact resource-scope assignment covers
  that resource. Case-insensitive (real ARM ids are mixed-case; records are
  stored downcased — same law as the AZB-25c exemption fix).

  `role_definition_id` may be the full definition id (…/roleDefinitions/<guid>)
  or the bare GUID; the well-known GUIDs map to verb sets via `role_verbs/1`.
  """
  def authorize?(principal_id, role_definition_id, resource_id) do
    matching_assignments(principal_id, role_definition_id, resource_id) != []
  end

  @doc """
  `authorize?/3` plus a verb gate: true only when the covering assignment's
  role grants `verb` (`:read` | `:write` | `:delete` | `:authorize`).
  """
  def authorize?(principal_id, role_definition_id, resource_id, verb)
      when verb in [:read, :write, :delete, :authorize] do
    matching_assignments(principal_id, role_definition_id, resource_id)
    |> Enum.any?(fn ra ->
      guid = ra_guid(ra)
      verb in role_verbs(role_name_for_guid(guid) || "")
    end)
  end

  defp ra_guid(ra) do
    ra
    |> get_in(["properties", "roleDefinitionId"])
    |> to_string()
    |> String.downcase()
    |> String.split("roledefinitions/")
    |> List.last()
  end

  defp matching_assignments(principal_id, role_definition_id, resource_id) do
    Store.ensure_tables()

    resource_low = String.downcase(resource_id || "")
    rd_guid = role_definition_id |> to_string() |> String.downcase()
    rd_guid = rd_guid |> String.split("roledefinitions/") |> List.last()

    :smalt_rbac
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(fn ra ->
      props = ra["properties"] || %{}
      ra_guid_low = String.downcase(get_in(props, ["roleDefinitionId"]) || "")

      get_in(ra, ["properties", "principalId"]) == principal_id and
        rd_guid != "" and String.ends_with?(ra_guid_low, "roledefinitions/" <> rd_guid) and
        scope_covers?(get_in(props, ["scope"]) || ra_scope(ra), resource_low)
    end)
  end

  # Assignment scope: fall back to the record's placement (id minus the
  # providers/... tail) when the body omitted properties.scope.
  defp ra_scope(ra) do
    case String.split(ra["id"] || "", "/providers/microsoft.authorization/") do
      [scope, _] -> scope
      _ -> ra["id"] || ""
    end
    |> String.downcase()
  end

  @doc false
  def scope_covers?(scope, resource_low) do
    scope = String.downcase(scope || "")
    resource_low == scope or String.starts_with?(resource_low, scope <> "/")
  end
  # ===========================================================================
  # Policy assignments
  # ===========================================================================

  @doc """
  Binds a policy definition at a scope. The scope is derived from the REQUEST
  path (subscription-scope or RG-scope route), never from the body — real ARM
  derives assignment scope from the placement, not from client-supplied text.

  `properties.enforcementMode` (DoNotEnforce | Default) is persisted and echoed
  on GET; omitted defaults to "Default" (real ARM semantics). A DoNotEnforce
  assignment skips deny evaluation in `enforce/3` (see `evaluate_assignment/2`).
  """
  def put_policy_assignment(scope_prefix, name, body) do
    Store.ensure_tables()

    enforcement_mode =
      case get_in(body, ["properties", "enforcementMode"]) do
        "DoNotEnforce" -> "DoNotEnforce"
        _ -> "Default"
      end

    record = %{
      "id" => "#{scope_prefix}/providers/Microsoft.Authorization/policyAssignments/#{name}",
      "name" => name,
      "type" => "Microsoft.Authorization/policyAssignments",
      "properties" => %{
        "policyDefinitionId" => get_in(body, ["properties", "policyDefinitionId"]),
        "enforcementMode" => enforcement_mode,
        "scope" => scope_prefix
      }
    }

    :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
    record
  end

  def get_policy_assignment(scope_prefix, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(pa_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_policy_assignment(scope_prefix, name) do
    Store.ensure_tables()

    id = String.downcase(pa_id(scope_prefix, name))
    :ets.delete(:smalt_policy, id)

    # Cascade the assignment's non-compliance receipts — a deleted assignment
    # must not leave GETable insight rows behind (same cascade law as the RG
    # sweep in the router).
    for {key, _} <- :ets.tab2list(:smalt_policy),
        is_binary(key) and String.starts_with?(key, "nc:#{id}:") do
      :ets.delete(:smalt_policy, key)
    end

    :ok
  end

  def list_policy_assignments(scope_prefix) do
    Store.ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyassignments/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    # KD-COVERS: KD-125 — the shared :smalt_policy table also holds rem:/rs: rows
    # with no "id" key — a nil there 500'd both list faces permanently
    # (witnessed 2026-10-20, substrate.log 18:02/18:09). Nil-safe filter.
    |> Enum.filter(fn r ->
      case r["id"] do
        nil -> false
        id -> String.downcase(id) |> String.starts_with?(prefix)
      end
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp pa_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyAssignments/#{name}"
end
