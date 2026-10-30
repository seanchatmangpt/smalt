defmodule Smalt.Policy.Eval do

  @moduledoc """
  The policy/RBAC enforcement engine.

  RBAC enforcement: `lock_blocks?/2` gates verbs against CanNotDelete/
  ReadOnly lock records; `Smalt.Policy.enforce/3` checks locks before policy
  deny evaluation and refuses with a 409-class ScopeLocked envelope.

  Enforcement: `Smalt.Policy.enforce/3` evaluates every policy assignment
  whose scope is the resource's RG scope or its subscription scope (ARM
  scope-prefix semantics) on the generic resource PUT path. A `deny` effect
  refuses the PUT with a typed 400 PolicyViolation envelope; an `audit`
  effect records non-compliance without blocking. Both effects write a
  non-compliance receipt; a compliant PUT clears prior receipts for that
  resource.

  Supported 80/20 policyRule conditions (nestable via allof/anyof):
  equals / notEquals / in / notIn / containsKey over fields `location`,
  `name`, `type`, `tags` (containsKey), `tags.<key>`, and dotted record
  fields (e.g. `sku.size`).
  """

  alias Smalt.Policy.Assignments
  alias Smalt.Policy.Exemptions
  alias Smalt.Policy.Store


  # ===========================================================================
  # Management locks (KD-COVERS: KD-113) — leg b
  # ===========================================================================

  @lock_levels ["CanNotDelete", "ReadOnly"]

  @doc """
  Puts a management lock at a scope (subscription or RG placement). Requires
  `properties.level` in ["CanNotDelete", "ReadOnly"]. Returns `{:ok, record}`
  or `{:error, refusal}` for a malformed body.
  """
  def put_lock(scope_prefix, name, body) do
    Store.ensure_tables()

    level = get_in(body, ["properties", "level"])
    notes = get_in(body, ["properties", "notes"])

    if level in @lock_levels do
      record = %{
        "id" => "#{scope_prefix}/providers/Microsoft.Authorization/locks/#{name}",
        "name" => name,
        "type" => "Microsoft.Authorization/locks",
        "properties" => %{
          "level" => level,
          "notes" => notes,
          "scope" => get_in(body, ["properties", "scope"]) || scope_prefix
        }
      }

      :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
      {:ok, record}
    else
      {:error, lock_refusal(scope_prefix, name, "level must be one of #{inspect(@lock_levels)}")}
    end
  end

  def get_lock(scope_prefix, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(lock_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_lock(scope_prefix, name) do
    Store.ensure_tables()
    :ets.delete(:smalt_policy, String.downcase(lock_id(scope_prefix, name)))
    :ok
  end

  def list_locks(scope_prefix) do
    Store.ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/locks/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/locks"))
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

  defp lock_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/locks/#{name}"

  defp lock_refusal(scope_prefix, name, reason),
    do: %{
      "error" => %{
        "code" => "ManagementLockInvalid",
        "message" => "Management lock '#{name}' at scope '#{scope_prefix}' is invalid. #{reason}.",
        "target" => nil,
        "innererror" => %{}
      }
    }

  @doc """
  Whether any lock covering `resource_id` blocks `verb` (KD-113 leg b).
  Scope-prefix matching identical to `authorize?/3`: a lock at a scope that is
  the resource id or a prefix of it applies.

  - `:delete` blocked by CanNotDelete AND ReadOnly locks (real ARM: ReadOnly
    blocks writes AND deletes).
  - `:write` (PUT/PATCH) blocked by ReadOnly locks.
  - `:read` never blocked (management locks do not gate the data plane).
  """
  def lock_blocks?(resource_id, verb)

  def lock_blocks?(resource_id, verb) when verb in [:delete, :write] do
    Store.ensure_tables()

    resource_low = String.downcase(resource_id || "")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/locks"))
    |> Enum.any?(fn lock ->
      scope = get_in(lock, ["properties", "scope"]) |> to_string() |> String.downcase()
      level = get_in(lock, ["properties", "level"])

      Assignments.scope_covers?(scope, resource_low) and
        (level == "ReadOnly" or (verb == :delete and level == "CanNotDelete"))
    end)
  end

  def lock_blocks?(_resource_id, :read), do: false

  # ===========================================================================
  # Policy definitions
  # ===========================================================================

  def put_policy_definition(sub_id, name, body) do
    Store.ensure_tables()

    rule = get_in(body, ["properties", "policyRule"]) || %{}

    record = %{
      "id" =>
        "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/#{name}",
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
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(pd_id(sub_id, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_definitions(sub_id) do
    Store.ensure_tables()
    prefix = String.downcase(pd_prefix(sub_id))

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

  defp pd_id(sub_id, name),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/#{name}"

  defp pd_prefix(sub_id),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policyDefinitions/"
  # ===========================================================================
  # Policy set definitions (initiatives)
  # ===========================================================================

  @doc """
  Puts a policy SET definition (initiative): a named list of member policy
  definition references. Returns `{:ok, record}` or `{:error, refusal}` when
  the body is malformed (missing or empty `policyDefinitions` member list).
  """
  def put_policy_set_definition(sub_id, name, body) do
    Store.ensure_tables()

    raw_members = get_in(body, ["properties", "policyDefinitions"])
    members = if is_list(raw_members), do: raw_members, else: nil

    cond do
      is_nil(members) or members == [] ->
        {:error, set_refusal(name, "policyDefinitions must be a non-empty list of member definitions")}

      true ->
        member_ids =
          for m <- members,
              id = (is_map(m) and get_in(m, ["policyDefinitionId"])) || (is_binary(m) and m),
              do: id

        if member_ids == [] or length(member_ids) != length(members) do
          {:error,
           set_refusal(name, "every policyDefinitions member must carry a policyDefinitionId")}
        else
          record = %{
            "id" =>
              "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policySetDefinitions/#{name}",
            "name" => name,
            "type" => "Microsoft.Authorization/policySetDefinitions",
            "properties" => %{
              "policyType" => get_in(body, ["properties", "policyType"]) || "Custom",
              "policyDefinitions" =>
                Enum.map(member_ids, &%{"policyDefinitionId" => &1})
            }
          }

          :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
          {:ok, record}
        end
    end
  end

  def get_policy_set_definition(sub_id, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(psd_id(sub_id, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_set_definitions(sub_id) do
    Store.ensure_tables()
    prefix = String.downcase(psd_prefix(sub_id))

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policySetDefinitions"))
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

  defp psd_id(sub_id, name),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policySetDefinitions/#{name}"

  defp psd_prefix(sub_id),
    do: "/subscriptions/#{sub_id}/providers/Microsoft.Authorization/policySetDefinitions/"

  defp set_refusal(name, reason),
    do: %{
      "error" => %{
        "code" => "PolicySetDefinitionInvalid",
        "message" => "Policy set definition '#{name}' is invalid. #{reason}.",
        "target" => nil,
        "innererror" => %{}
      }
    }
  # ===========================================================================
  # Enforcement
  # ===========================================================================

  @doc """
  Evaluates the assigned policies for a resource PUT at RG scope then
  subscription scope (ARM scope-prefix semantics). Returns `:ok` when the PUT
  may proceed; `{:deny, json_body}` when a `deny`-effect assignment finds the
  resource non-compliant. Non-compliance receipts are written for deny AND
  audit effects; a compliant evaluation clears prior receipts.

  Lock check runs BEFORE policy evaluation (KD-113 leg b): a ReadOnly lock
  covering the resource refuses the PUT with a 409 ScopeLocked envelope —
  real ARM returns 409 ScopeLocked on write/delete against a locked scope,
  so the router must map the ScopeLocked code to 409 (not the 400 the
  PolicyViolation deny class gets).
  """
  def enforce(sub_id, rg_name, record) do
    Store.ensure_tables()

    resource_id = String.downcase(record["id"] || "")

    # Remediation snapshot seam: every enforcement pass (deny AND ok, lock
    # refusal included) leaves the evaluated record reachable at trigger time
    # via resource_state/1 — a remediation re-runs THIS record, not a stale
    # receipt row.
    :ets.insert(:smalt_policy, {String.downcase("rs:#{record["id"] || ""}"), %{
      "smaltReceiptType" => "policyResourceState",
      "resourceId" => record["id"] || "",
      "record" => record
    }})

    if lock_blocks?(resource_id, :write) do
      {:deny, scope_locked_body(record)}
    else
      enforce_policies(sub_id, rg_name, record, resource_id)
    end
  end

  defp enforce_policies(sub_id, rg_name, record, resource_id) do
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
    Store.ensure_tables()

    receipt_rows()
    |> Enum.group_by(& &1["policyAssignmentId"])
    |> Enum.map(fn {assignment_id, rows} ->
      %{
        "policyAssignmentId" => assignment_id,
        "results" => %{
          "nonCompliantResources" =>
            rows |> Enum.map(& &1["resourceId"]) |> Enum.uniq() |> length(),
          "nonCompliantPolicies" => 1
        }
      }
    end)
    |> Enum.sort_by(& &1["policyAssignmentId"])
  end

  @doc "Non-compliant resource ids for one assignment (queryResults shape)."
  def non_compliant_resources(assignment_id) do
    Store.ensure_tables()

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

  @doc false
  def evaluate_assignment(assignment, record) do
    do_not_enforce? =
      get_in(assignment, ["properties", "enforcementMode"]) == "DoNotEnforce"

    rules =
      case get_in(assignment, ["properties", "policyDefinitionId"]) do
        nil ->
          []

        def_id ->
          case definition_rules(def_id) do
            {:single, rule} -> [{def_id, rule}]
            {:set, members} -> members
            :missing -> []
          end
      end

    rules
    |> Enum.map(fn {def_id, rule} -> evaluate_rule(assignment, def_id, rule, record) end)
    |> Enum.reject(&(&1 == :ok))
    |> case do
      [] ->
        :ok

      verdicts ->
        # DoNotEnforce (PY wf6): the assignment never refuses — a would-be deny
        # is downgraded to an audit verdict and the receipt notes the mode.
        if do_not_enforce? do
          verdicts
          |> Enum.map(fn {effect, _def_id, reason} ->
            {if(effect == :deny, do: :audit, else: effect), assignment, reason}
          end)
          |> Enum.map(fn {effect, a, reason} ->
            {effect, a, reason <> " (enforcementMode=DoNotEnforce)"}
          end)
          |> Enum.sort_by(fn {effect, a, _} -> {effect_rank(effect), a["id"]} end)
          |> List.first()
        else
          # Deterministic worst-effect: any deny wins, first by sorted assignment id.
          verdicts
          |> Enum.map(fn {effect, _def_id, reason} -> {effect, assignment, reason} end)
          |> Enum.sort_by(fn {effect, a, _} -> {effect_rank(effect), a["id"]} end)
          |> List.first()
        end
    end
  end

  defp effect_rank("deny"), do: 0
  defp effect_rank(_), do: 1

  # Resolves an assignment's policyDefinitionId into its member rules:
  # a plain definition -> {:single, rule}; an initiative (policySet) ->
  # {:set, [{def_id, rule}]} iterating member definitions; unknown -> :missing.
  defp definition_rules(def_id) do
    case lookup_definition_by_id(def_id) do
      nil ->
        :missing

      %{"type" => "Microsoft.Authorization/policySetDefinitions"} = set ->
        members =
          set
          |> get_in(["properties", "policyDefinitions"])
          |> List.wrap()
          |> Enum.map(fn
            %{"policyDefinitionId" => mid} ->
              {mid, get_in(lookup_definition_by_id(mid) || %{}, ["properties", "policyRule"])}

            mid when is_binary(mid) ->
              {mid, get_in(lookup_definition_by_id(mid) || %{}, ["properties", "policyRule"])}
          end)

        {:set, members}

      definition ->
        {:single, get_in(definition, ["properties", "policyRule"])}
    end
  end

  defp evaluate_rule(_assignment, _def_id, rule, _record) when is_nil(rule) or rule == %{},
    do: :ok

  defp evaluate_rule(assignment, def_id, rule, record) do
    effect = get_in(rule, ["then", "effect"]) || "deny"

    if condition_matches?(rule, record) do
      if exemption_applies?(assignment, record) do
        record_exemption_receipt(assignment, def_id, record)
        :ok
      else
        reason = condition_reason(rule)
        effect = if effect == "audit", do: :audit, else: :deny
        {effect, def_id, reason}
      end
    else
      :ok
    end
  end

  # An ACTIVE (non-expired) exemption for this assignment exempts the
  # resource: the deny is skipped and an exemption receipt recorded.
  defp exemption_applies?(assignment, record) do
    assignment_id = assignment["id"]
    # AZB-25c: real ARM ids are mixed-case (`resourceGroups`,
    # `Microsoft.Network`, ...); the exemption scope is stored downcased, so
    # the resource id must be downcased here or the exemption never applies
    # (witnessed: identical sequence passes with a lowercase id, 400 with an
    # ARM-cased one — kd112 differential probe, 2026-10-20).
    resource_id = String.downcase(record["id"] || "")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policyExemptions"))
    |> Enum.any?(fn ex ->
      get_in(ex, ["properties", "policyAssignmentId"]) == assignment_id and
        Exemptions.exemption_active?(ex) and
        exemption_covers?(ex, resource_id)
    end)
  end

  defp exemption_covers?(ex, resource_id_low) do
    scope = get_in(ex, ["properties", "scope"]) |> to_string() |> String.downcase()
    resource_id_low == scope or String.starts_with?(resource_id_low, scope <> "/")
  end

  defp record_exemption_receipt(assignment, def_id, record) do
    ex_key =
      String.downcase("exr:#{assignment["id"]}:#{record["id"] || ""}:#{def_id}")

    :ets.insert(:smalt_policy, {ex_key, %{
      "smaltReceiptType" => "policyExemption",
      "policyAssignmentId" => assignment["id"],
      "policyDefinitionId" => def_id,
      "resourceId" => record["id"] || "",
      "exempted" => true
    }})
  end

  @doc false
  def lookup_definition_by_id(def_id) do
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
      {"field", _} ->
        false

      {"then", _} ->
        false

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
      %{"if" => %{"field" => field}} ->
        "Resource field '#{field}' does not satisfy policy"

      %{"allof" => subs} when is_list(subs) ->
        case Enum.find(subs, &match?(%{"field" => _}, &1)) do
          %{"field" => field} -> "Resource field '#{field}' does not satisfy policy"
          _ -> "Resource does not satisfy policy"
        end

      _ ->
        "Resource does not satisfy policy"
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

  # ScopeLocked (KD-113 leg b): same inline-envelope law as violation_body —
  # real ARM answers 409 ScopeLocked with ScopeLockedError code on a locked
  # write/delete; the ROUTER owns the 409 mapping (patch line in the lane
  # report), this module only emits the typed code.
  defp scope_locked_body(record) do
    Jason.encode!(%{
      "error" => %{
        "code" => "ScopeLocked",
        "message" =>
          "The scope '#{record["id"] || ""}' is locked at a level that blocks this operation. " <>
            "Remove the lock (Microsoft.Authorization/locks) to proceed.",
        "target" => record["id"] || "",
        "innererror" => %{}
      }
    })
  end
end
