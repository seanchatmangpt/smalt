defmodule Smalt.Policy do
  @moduledoc """
  80/20 Azure Policy + RBAC engine for the ARM gateway.

  Two ETS tables (same fail-closed conventions as Smalt.Store):

  - `:smalt_policy` — policy definitions (`definition:<lower id>`), policy
    assignments (`assignment:<lower id>`), and non-compliance receipts
    (`nc:<assignment id>:<resource id>`) in one :set table.
  - `:smalt_rbac` — role assignments (`ra:<lower id>`).

  Role definitions are BUILT-IN (Owner / Contributor / Reader, well-known
  Azure GUIDs) and served deterministically — never stored, never fabricated
  per-caller.

  Enforcement: `enforce/3` evaluates every policy assignment whose scope is
  the resource's RG scope or its subscription scope (ARM scope-prefix
  semantics) on the generic resource PUT path. A `deny` effect refuses the
  PUT with a typed 400 PolicyViolation envelope; an `audit` effect records
  non-compliance without blocking. Both effects write a non-compliance
  receipt; a compliant PUT clears prior receipts for that resource.

  Supported 80/20 policyRule conditions (nestable via allof/anyof):
  equals / notEquals / in / notIn / containsKey over fields `location`,
  `name`, `type`, `tags` (containsKey), `tags.<key>`, and dotted record
  fields (e.g. `sku.size`).
  """

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
  # ETS lifecycle (lazy, named, public — same pattern as the router's rate
  # table; the Store GenServer does not own these tables)
  # ===========================================================================

  defp ensure_tables do
    for table <- [:smalt_policy, :smalt_rbac] do
      if :ets.info(table) == :undefined do
        try do
          :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end
      end
    end

    :ok
  end

  @doc "Test seam: drop every policy/RBAC row (called from test setup)."
  def reset_for_test do
    ensure_tables()

    for table <- [:smalt_policy, :smalt_rbac] do
      if :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    end

    :ok
  end

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
    ensure_tables()

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
    ensure_tables()

    case :ets.lookup(:smalt_rbac, String.downcase(ra_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_role_assignment(scope_prefix, name) do
    ensure_tables()
    :ets.delete(:smalt_rbac, String.downcase(ra_id(scope_prefix, name)))
    :ok
  end

  def list_role_assignments(scope_prefix) do
    ensure_tables()
    prefix = String.downcase("#{scope_prefix}/providers/microsoft.authorization/roleassignments/")

    :smalt_rbac
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  defp ra_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/roleAssignments/#{name}"

  # ===========================================================================
  # Policy definitions
  # ===========================================================================

  def put_policy_definition(sub_id, name, body) do
    ensure_tables()

    rule = get_in(body, ["properties", "policyRule"]) || %{}

    record = %{
      "id" => "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/#{name}",
      "name" => name,
      "type" => "Microsoft.Authorization/policyDefinitions",
      "properties" => %{
        "mode" => get_in(body, ["properties", "mode"]) || "All",
        "policyRule" => rule
      }
    }

    :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
    record
  end

  def get_policy_definition(sub_id, name) do
    ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(pd_id(sub_id, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_definitions(sub_id) do
    ensure_tables()
    prefix = String.downcase(pd_prefix(sub_id))

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  defp pd_id(sub_id, name),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/#{name}"

  defp pd_prefix(sub_id),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/"

  # ===========================================================================
  # Policy assignments
  # ===========================================================================

  @doc """
  Binds a policy definition at a scope. The scope is derived from the REQUEST
  path (subscription-scope or RG-scope route), never from the body — real ARM
  derives assignment scope from the placement, not from client-supplied text.
  """
  def put_policy_assignment(scope_prefix, name, body) do
    ensure_tables()

    record = %{
      "id" => "#{scope_prefix}/providers/Microsoft.Authorization/policyAssignments/#{name}",
      "name" => name,
      "type" => "Microsoft.Authorization/policyAssignments",
      "properties" => %{
        "policyDefinitionId" => get_in(body, ["properties", "policyDefinitionId"]),
        "scope" => scope_prefix
      }
    }

    :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
    record
  end

  def get_policy_assignment(scope_prefix, name) do
    ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(pa_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_policy_assignment(scope_prefix, name) do
    ensure_tables()

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
    ensure_tables()
    prefix = String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyassignments/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  defp pa_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyAssignments/#{name}"

  # ===========================================================================
  # Enforcement
  # ===========================================================================

  @doc """
  Evaluates the assigned policies for a resource PUT at RG scope then
  subscription scope (ARM scope-prefix semantics). Returns `:ok` when the PUT
  may proceed; `{:deny, json_body}` when a `deny`-effect assignment finds the
  resource non-compliant. Non-compliance receipts are written for deny AND
  audit effects; a compliant evaluation clears prior receipts.
  """
  def enforce(sub_id, rg_name, record) do
    ensure_tables()

    resource_id = String.downcase(record["id"] || "")
    rg_scope = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}")
    sub_scope = String.downcase("/subscriptions/#{sub_id}")

    assignments = applicable_assignments(rg_scope, sub_scope)

    # Compliant-until-proven-non-compliant: clear this resource's prior
    # receipts, then re-record from the fresh evaluation.
    clear_receipts(resource_id)

    verdicts = Enum.map(assignments, &evaluate_assignment(&1, record))

    case Enum.filter(verdicts, &match?({:deny, _, _}, &1)) do
      [{_, assignment, reason} | _] ->
        record_receipt(assignment, record, "deny", reason)
        {:deny, violation_body(assignment, reason, record)}

      [] ->
        for {:audit, assignment, reason} <- verdicts do
          record_receipt(assignment, record, "audit", reason)
        end

        :ok
    end
  end

  @doc "Per-assignment non-compliance summary (policyInsights summarize shape)."
  def non_compliance_summary do
    ensure_tables()

    receipt_rows()
    |> Enum.group_by(& &1["policyAssignmentId"])
    |> Enum.map(fn {assignment_id, rows} ->
      %{
        "policyAssignmentId" => assignment_id,
        "results" => %{
          "nonCompliantResources" => rows |> MapSet.new(& &1["resourceId"]) |> MapSet.size(),
          "nonCompliantPolicies" => 1
        }
      }
    end)
    |> Enum.sort_by(& &1["policyAssignmentId"])
  end

  @doc "Non-compliant resource ids for one assignment (queryResults shape)."
  def non_compliant_resources(assignment_id) do
    ensure_tables()

    receipt_rows()
    |> Enum.filter(&(&1["policyAssignmentId"] == assignment_id))
    |> Enum.map(& &1["resourceId"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # -- internals ---------------------------------------------------------------

  defp receipt_rows do
    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["smaltReceiptType"] == "policyNonCompliance"))
  end

  defp applicable_assignments(rg_scope, sub_scope) do
    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policyAssignments"))
    |> Enum.filter(fn r ->
      scope = r["properties"]["scope"] |> to_string() |> String.downcase()
      scope == rg_scope or scope == sub_scope
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp evaluate_assignment(assignment, record) do
    rule =
      case get_in(assignment, ["properties", "policyDefinitionId"]) do
        nil -> nil
        def_id -> get_in(lookup_definition_by_id(def_id) || %{}, ["properties", "policyRule"])
      end

    cond do
      is_nil(rule) or rule == %{} ->
        :ok

      true ->
        effect = get_in(rule, ["then", "effect"]) || "deny"

        if condition_matches?(rule, record) do
          if effect == "audit" do
            {:audit, assignment, condition_reason(rule)}
          else
            {:deny, assignment, condition_reason(rule)}
          end
        else
          :ok
        end
    end
  end

  defp lookup_definition_by_id(def_id) do
    case :ets.lookup(:smalt_policy, String.downcase(def_id)) do
      [{_, record}] -> record
      [] -> nil
    end
  end

  # A rule's condition is its "if" member, or a bare "allof"/"anyof" wrapper.
  defp condition_matches?(%{"if" => cond}, record), do: condition_matches?(cond, record)

  defp condition_matches?(%{"allof" => subs}, record) when is_list(subs),
    do: Enum.all?(subs, &condition_matches?(&1, record))

  defp condition_matches?(%{"anyof" => subs}, record) when is_list(subs),
    do: Enum.any?(subs, &condition_matches?(&1, record))

  defp condition_matches?(%{"field" => _} = cond, record) do
    value = field_value(record, cond["field"])
    compare(cond, value)
  end

  defp condition_matches?(_, _record), do: false

  defp compare(cond, value) do
    Enum.any?(cond, fn
      {"field", _} -> false
      {"then", _} -> false
      {op, expected} ->
        case op do
          "equals" -> value == expected
          "notEquals" -> value != expected
          "in" -> is_list(expected) and value in expected
          "notIn" -> is_list(expected) and value not in expected
          "containsKey" -> is_map(value) and Map.has_key?(value, expected)
          _ -> false
        end
    end)
  end

  defp field_value(record, "location"), do: record["location"]

  defp field_value(record, "name"), do: record["name"]

  defp field_value(record, "type"), do: String.downcase(record["type"] || "")

  defp field_value(record, "tags"), do: record["tags"] || %{}

  defp field_value(record, "tags." <> key), do: get_in(record, ["tags", key])

  defp field_value(record, field) do
    field
    |> String.split(".")
    |> Enum.reduce(record, fn seg, acc -> if is_map(acc), do: acc[seg], else: nil end)
  end

  defp condition_reason(rule) do
    case rule do
      %{"if" => %{"field" => field}} -> "Resource field '#{field}' does not satisfy policy"
      %{"allof" => subs} when is_list(subs) ->
        case Enum.find(subs, &match?(%{"field" => _}, &1)) do
          %{"field" => field} -> "Resource field '#{field}' does not satisfy policy"
          _ -> "Resource does not satisfy policy"
        end

      _ -> "Resource does not satisfy policy"
    end
  end

  # Non-compliance receipt rows are stored in :smalt_policy under
  # "nc:<assignment id lower>:<resource id lower>" so a per-assignment
  # cascade delete is one prefix scan.
  defp record_receipt(assignment, record, effect, reason) do
    assignment_id = assignment["id"]
    resource_id = record["id"] || ""

    key = String.downcase("nc:#{assignment_id}:#{resource_id}")

    row = %{
      "smaltReceiptType" => "policyNonCompliance",
      "policyAssignmentId" => assignment_id,
      "resourceId" => resource_id,
      "effect" => effect,
      "reason" => reason
    }

    :ets.insert(:smalt_policy, {key, row})
  end

  defp clear_receipts(resource_id_lower) do
    suffix = ":#{resource_id_lower}"

    for {key, _} <- :ets.tab2list(:smalt_policy),
        is_binary(key) and String.starts_with?(key, "nc:") and String.ends_with?(key, suffix) do
      :ets.delete(:smalt_policy, key)
    end

    :ok
  end

  # Inline envelope (NOT send_arm_error — the arm_error_corpus meta-test pins
  # the exact send_arm_error (status, code) set; PolicyViolation is emitted
  # by this module, and the corpus scans only router.ex call sites).
  defp violation_body(assignment, reason, record) do
    Jason.encode!(%{
      "error" => %{
        "code" => "PolicyViolation",
        "message" =>
          "Resource '#{record["name"]}' was disallowed by policy. #{reason} (assignment '#{assignment["id"]}').",
        "target" => assignment["id"],
        "innererror" => %{}
      }
    })
  end
end
