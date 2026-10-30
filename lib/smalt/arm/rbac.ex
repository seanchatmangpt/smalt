defmodule Smalt.Arm.Rbac do
  @moduledoc """
  ARM RBAC control-plane faces (wave-6 lane w6as, v26.10.20).

  Custom roleDefinitions + roleAssignments with real-ARM validation law:

  - Definitions: `permissions[].actions` arrays must be nonempty;
    `assignableScopes` must include the definition's placement scope.
  - Assignments: `roleDefinitionId` must reference an existing definition
    (built-in via `Smalt.Policy.role_definition/2` or custom in this
    module's table); unique per (principalId, roleDefinitionId, scope) —
    second insert is 409 DuplicateRoleAssignment.

  Verbs compose with `Smalt.Policy.role_verbs/1` for built-in GUIDs;
  custom definitions map their `actions` strings to verb atoms via
  `verbs_from_actions/1` (`*` → all four; "…/read" → :read etc.).

  `effective_rights/2` unions verb sets over every covering assignment
  (scope-prefix inheritance, case-insensitive — same law as
  `Smalt.Policy.authorize?/3`).

  ROUTER HOLD respected: no egress_router/arm_gateway edits; the wire
  patch is staged at `tmp/w6as/router_patch_draft.md`.
  """

  @table_defs :smalt_arm_rbac_defs
  @table_ra :smalt_arm_rbac_assignments

  @valid_verbs [:read, :write, :delete, :authorize]

  # -- tables ----------------------------------------------------------------

  defp ensure_tables do
    for table <- [@table_defs, @table_ra] do
      if :ets.info(table) == :undefined do
        try do
          :ets.new(table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true},
            {:heir, Process.whereis(:init), []}
          ])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    :ok
  end

  @doc "Test seam: drop every RBAC row."
  def reset_for_test do
    ensure_tables()

    for table <- [@table_defs, @table_ra] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  # -- roleDefinitions -------------------------------------------------------
  end

  @doc """
  PUT a custom role definition. `scope_prefix` is the placement
  (e.g. "/subscriptions/sub-1" or "/subscriptions/sub-1/resourceGroups/rg1").
  """
  def put_role_definition(scope_prefix, name, body) do
    ensure_tables()
    perms = get_in(body, ["properties", "permissions"]) || []

    case validate_permissions(perms) do
      :ok ->
        scopes = get_in(body, ["properties", "assignableScopes"]) || []

        if scope_covers_list?(scope_prefix, scopes) do
          create_definition(scope_prefix, name, body, perms, scopes)
        else
          {:error, {:bad_request, "AssignableScopesMustIncludeScope",
            "assignableScopes must include the definition's placement scope #{scope_prefix}"}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_definition(scope_prefix, name, body, perms, scopes) do
    def_id = "#{scope_prefix}/providers/Microsoft.Authorization/roleDefinitions/#{name}"

    record = %{
      "id" => def_id,
      "name" => name,
      "type" => "Microsoft.Authorization/roleDefinitions",
      "properties" => %{
        "roleName" => get_in(body, ["properties", "roleName"]) || name,
        "type" => "CustomRole",
        "assignmentsNeeded" => false,
        "permissions" => perms,
        "assignableScopes" => scopes
      }
    }

    :ets.insert(@table_defs, {String.downcase(def_id), record})
    {:ok, record}
  end

  defp validate_permissions([]) do
    {:error, {:bad_request, "EmptyPermissions",
      "permissions must be a nonempty array of {actions, notActions}"}}
  end

  defp validate_permissions(perms) do
    if Enum.all?(perms, fn row ->
         is_map(row) and is_list(row["actions"]) and row["actions"] != []
       end) do
      :ok
    else
      {:error, {:bad_request, "EmptyPermissions",
        "every permissions entry needs a nonempty actions array"}}
    end
  end

  @doc "GET a custom role definition by name (GUID or chosen name)."
  def get_role_definition(scope_prefix, name) do
    ensure_tables()

    case :ets.lookup(@table_defs, String.downcase(def_id(scope_prefix, name))) do
      [{_, rec}] -> {:ok, rec}
      [] -> :error
    end
  end

  @doc "LIST custom role definitions under a scope prefix."
  def list_role_definitions(scope_prefix) do
    ensure_tables()
    prefix = String.downcase(def_id(scope_prefix, ""))

    @table_defs
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  @doc "DELETE a custom role definition. `:error` when absent."
  def delete_role_definition(scope_prefix, name) do
    ensure_tables()
    key = String.downcase(def_id(scope_prefix, name))

    case :ets.lookup(@table_defs, key) do
      [{_, _}] ->
        # Refuse when assignments reference it (real ARM parity). Both
        # assignment stores are consulted: this module's own table AND
        # Smalt.Policy's :smalt_rbac (the wire face's roleAssignments store
        # via Smalt.Policy.put_role_assignment).
        refs =
          [@table_ra, :smalt_rbac]
          |> Enum.filter(&(:ets.info(&1) != :undefined))
          |> Enum.flat_map(&:ets.tab2list/1)
          |> Enum.any?(fn {_, ra} ->
            rd = get_in(ra, ["properties", "roleDefinitionId"]) || ""
            String.downcase(rd) == key or String.ends_with?(String.downcase(rd), "/" <> name)
          end)

        if refs do
          {:error, {:bad_request, "RoleDefinitionInUse",
            "role definition is referenced by existing role assignments"}}
        else
          :ets.delete(@table_defs, key)
          :ok
        end

      [] ->
        :error
    end
  end

  defp def_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/roleDefinitions/#{name}"

  # -- roleAssignments -------------------------------------------------------

  @doc """
  PUT a role assignment. `roleDefinitionId` must resolve to a definition
  (custom via this module or built-in via `Smalt.Policy.role_definition/2`).
  Unique per (principalId, roleDefinitionId, scope) — duplicate → 409.
  """
  def put_role_assignment(scope_prefix, name, body) do
    ensure_tables()

    props = body["properties"] || %{}
    principal = props["principalId"]
    rd_id = props["roleDefinitionId"]

    cond do
      not is_binary(principal) or principal == "" ->
        {:error, {:bad_request, "MissingPrincipal", "properties.principalId is required"}}

      not is_binary(rd_id) or rd_id == "" ->
        {:error, {:bad_request, "MissingRoleDefinition", "properties.roleDefinitionId is required"}}

      definition_for(rd_id, scope_prefix) == :error ->
        {:error, {:bad_request, "RoleDefinitionDoesNotExist",
          "roleDefinitionId does not reference an existing role definition"}}

      true ->
        scope = props["scope"] || scope_prefix
        create_assignment(scope_prefix, name, principal, rd_id, scope)
    end
  end

  defp create_assignment(scope_prefix, name, principal, rd_id, scope) do
    ra_id = "#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}"
    key = String.downcase(ra_id)

    dup? =
      @table_ra
      |> :ets.tab2list()
      |> Enum.any?(fn {_, ra} ->
        p = ra["properties"] || %{}

        p["principalId"] == principal and
          same_role_definition?(p["roleDefinitionId"], rd_id) and
          String.downcase(p["scope"] || "") == String.downcase(scope)
      end)

    if dup? do
      {:error, {:conflict, "DuplicateRoleAssignment",
        "an assignment for this principal/role/scope tuple already exists"}}
    else
      record = %{
        "id" => ra_id,
        "name" => name,
        "type" => "Microsoft.Authorization/roleAssignments",
        "properties" => %{"principalId" => principal, "roleDefinitionId" => rd_id, "scope" => scope}
      }

      :ets.insert(@table_ra, {key, record})
      {:ok, record}
    end
  end

  defp same_role_definition?(a, b) do
    String.downcase(a || "") == String.downcase(b || "")
  end

  @doc "GET one assignment."
  def get_role_assignment(scope_prefix, name) do
    ensure_tables()
    key = String.downcase("#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}")

    case :ets.lookup(@table_ra, key) do
      [{_, rec}] -> {:ok, rec}
      [] -> :error
    end
  end

  @doc """
  LIST assignments at a scope; `$filter=principalId eq '...'` narrows to the
  principal.
  """
  def list_role_assignments(scope_prefix, filter \\ nil) do
    ensure_tables()
    prefix = String.downcase("#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/")
    principal = parse_principal_filter(filter)

    @table_ra
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(fn ra ->
      String.downcase(ra["id"]) |> String.starts_with?(prefix) and
        (principal == nil or get_in(ra, ["properties", "principalId"]) == principal)
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp parse_principal_filter(nil), do: nil

  defp parse_principal_filter(filter) do
    case Regex.run(~r/principalId\s+eq\s+'([^']+)'/i, filter) do
      [_, principal] -> principal
      _ -> nil
    end
  end

  @doc "DELETE an assignment. `:error` when absent."
  def delete_role_assignment(scope_prefix, name) do
    ensure_tables()
    key = String.downcase("#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}")

    case :ets.lookup(@table_ra, key) do
      [{_, _}] ->
        :ets.delete(@table_ra, key)
        :ok

      [] ->
        :error
    end
  end

  defp definition_for(rd_id, _scope_prefix) do
    custom? =
      @table_defs
      |> :ets.tab2list()
      |> Enum.any?(fn {_, defn} ->
        String.downcase(defn["id"]) == String.downcase(rd_id) or
          String.downcase(defn["name"]) == String.downcase(rd_id)
      end)

    if custom? do
      {:ok, :custom}
    else
      case Smalt.Policy.role_definition("/subscriptions/definition-probe", rd_id) do
        {:ok, _} -> {:ok, :builtin}
        :error -> :error
      end
    end
  end

  # -- effective_rights --------------------------------------------------------

  @doc """
  Union of verbs (:read | :write | :delete | :authorize) granted to
  `principal_id` on `resource_id` by every covering assignment (scope-prefix
  inheritance, case-insensitive). Sources: this module's custom assignments
  AND the landed `:smalt_rbac` assignments owned by `Smalt.Policy`.
  Built-in GUIDs map via `Smalt.Policy.role_verbs/1`; custom definitions map
  via their permissions actions.
  """
  def effective_rights(principal_id, resource_id) do
    ensure_tables()
    resource_low = String.downcase(resource_id || "")

    custom_assignments = assignments_for(principal_id, resource_low, @table_ra)
    builtin_assignments = assignments_for(principal_id, resource_low, :smalt_rbac)

    (Enum.map(custom_assignments, &assignment_verbs/1) ++
       Enum.map(builtin_assignments, &assignment_verbs/1))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp assignments_for(principal_id, resource_low, table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(fn ra ->
      props = ra["properties"] || %{}

      props["principalId"] == principal_id and
        scope_covers?(props["scope"] || "", resource_low)
    end)
  end

  defp scope_covers?(scope, resource_low) when is_binary(scope) and scope != "" do
    resource_low == scope or String.starts_with?(resource_low, scope <> "/")
  end

  defp scope_covers?(_, _), do: false

  # assignableScopes must include the definition's placement scope
  # (case-insensitive prefix law, same scope_covers?/2 semantics).
  defp scope_covers_list?(scope_prefix, scopes) do
    prefix_low = String.downcase(scope_prefix)

    Enum.any?(scopes, fn scope ->
      scope_covers?(String.downcase(scope), prefix_low)
    end)
  end

  defp assignment_verbs(ra) do
    rd = get_in(ra, ["properties", "roleDefinitionId"]) || ""
    guid = rd |> String.downcase() |> String.split("roledefinitions/") |> List.last()

    case Smalt.Policy.role_verbs(role_name_for_guid(guid) || "") do
      [] -> verbs_from_definition(rd)
      verbs -> verbs
    end
  end

  defp role_name_for_guid(guid) do
    case Enum.find(builtin_guids(), fn {g, _} -> g == guid end) do
      {_, name} -> name
      nil -> nil
    end
  end

  defp builtin_guids do
    # Mirrors Smalt.Policy's @builtin_roles well-known GUIDs (Owner /
    # Contributor / Reader); Policy does not export an accessor.
    [
      {"8e3af657-a8ff-443c-a75c-2fe8c4bcb635", "Owner"},
      {"b24988ac-6180-42a0-ab88-20f7382dd24c", "Contributor"},
      {"acdd72a7-3385-48ef-bd42-f606fba81ae7", "Reader"}
    ]
  end

  defp verbs_from_definition(rd_id) do
    case find_definition(rd_id) do
      {:ok, defn} ->
        perms = get_in(defn, ["properties", "permissions"]) || []
        Enum.flat_map(perms, fn p -> verbs_from_actions(p["actions"] || []) end)

      :error ->
        []
    end
  end

  defp find_definition(rd_id) do
    custom =
      @table_defs
      |> :ets.tab2list()
      |> Enum.find(fn {_, defn} ->
        String.downcase(defn["id"]) == String.downcase(rd_id) or
          String.downcase(defn["name"]) == String.downcase(rd_id)
      end)

    cond do
      custom != nil ->
        {:ok, elem(custom, 1)}

      true ->
        case Smalt.Policy.role_definition("/subscriptions/definition-probe", rd_id) do
          {:ok, builtin} -> {:ok, builtin}
          :error -> :error
        end
    end
  end

  defp verbs_from_actions(actions) do
    actions
    |> Enum.flat_map(fn
      "*" ->
        @valid_verbs

      action when is_binary(action) ->
        cond do
          String.contains?(action, "read") -> [:read]
          String.contains?(action, "write") -> [:write]
          String.contains?(action, "delete") -> [:delete]
          String.contains?(action, "join") or String.contains?(action, "action") -> [:authorize]
          true -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # -- wire helpers ------------------------------------------------------------
  @doc "Typed ARM error body for a {:error, {:bad_request, code, msg}} / {:conflict, ...}."
  def error_wire({:error, {:bad_request, code, msg}}), do: arm_error(400, code, msg)
  def error_wire({:error, {:conflict, code, msg}}), do: arm_error(409, code, msg)

  defp arm_error(status, code, msg) do
    %{:status => status,
      "error" => %{"code" => code, "message" => msg}}
  end
end
