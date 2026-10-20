defmodule Smalt.Policy do
  @moduledoc """
  80/20 Azure Policy + RBAC engine for the ARM gateway.

  Two ETS tables (same fail-closed conventions as Smalt.Store):

  - `:smalt_policy` — policy definitions (`definition:<lower id>`), policy
    assignments (`assignment:<lower id>`), and non-compliance receipts
    (`nc:<assignment id>:<resource id>`) in one :set table.
  - `:smalt_rbac` — role assignments (`ra:<lower id>`).

  Management locks (`Microsoft.Authorization/locks`, KD-113 leg b) and policy
  exemptions share the `:smalt_policy` table, discriminated by `type`.

  RBAC enforcement: `authorize?/3` + `authorize?/4` resolve assignment scope
  prefixes (subscription ⊃ RG ⊃ resource) with inheritance; built-in role
  GUIDs map to verb sets via `role_verbs/1`. `lock_blocks?/2` gates verbs
  against CanNotDelete/ReadOnly lock records; `enforce/3` checks locks before
  policy deny evaluation and refuses with a 409-class ScopeLocked envelope.

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
          :ets.new(table, [
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            {:write_concurrency, true},
            # Shadow-table law (PW lane, wire witness 2026-10-19): these tables
            # are NOT in Store's boot list (StoreTables.shadow_tables), so the
            # first creator can be a Bandit request task — without an heir the
            # table DIES with that request process and every later request sees
            # a fresh store (witnessed: PUT 201 then GET 404 on the same beam).
            # Heir to :init (permanent, node-local) makes the table outlive its
            # creator; ensure_tables' ArgumentError rescue keeps the create race
            # fail-safe when several requests race the first insert.
            {:heir, Process.whereis(:init), []}
          ])
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
    ensure_tables()

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

  defp scope_covers?(scope, resource_low) do
    scope = String.downcase(scope || "")
    resource_low == scope or String.starts_with?(resource_low, scope <> "/")
  end

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
    ensure_tables()

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
    ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(lock_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def delete_lock(scope_prefix, name) do
    ensure_tables()
    :ets.delete(:smalt_policy, String.downcase(lock_id(scope_prefix, name)))
    :ok
  end

  def list_locks(scope_prefix) do
    ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/locks/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/locks"))
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
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
    ensure_tables()

    resource_low = String.downcase(resource_id || "")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/locks"))
    |> Enum.any?(fn lock ->
      scope = get_in(lock, ["properties", "scope"]) |> to_string() |> String.downcase()
      level = get_in(lock, ["properties", "level"])

      scope_covers?(scope, resource_low) and
        (level == "ReadOnly" or (verb == :delete and level == "CanNotDelete"))
    end)
  end

  def lock_blocks?(_resource_id, :read), do: false

  # ===========================================================================
  # Policy definitions
  # ===========================================================================

  def put_policy_definition(sub_id, name, body) do
    ensure_tables()

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

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyassignments/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  defp pa_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyAssignments/#{name}"

  # ===========================================================================
  # Policy set definitions (initiatives)
  # ===========================================================================

  @doc """
  Puts a policy SET definition (initiative): a named list of member policy
  definition references. Returns `{:ok, record}` or `{:error, refusal}` when
  the body is malformed (missing or empty `policyDefinitions` member list).
  """
  def put_policy_set_definition(sub_id, name, body) do
    ensure_tables()

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
    ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(psd_id(sub_id, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_set_definitions(sub_id) do
    ensure_tables()
    prefix = String.downcase(psd_prefix(sub_id))

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policySetDefinitions"))
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
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
  # Policy exemptions
  # ===========================================================================

  @doc """
  Puts a policy exemption at a scope (subscription or RG placement). Requires
  `properties.policyAssignmentId`; honors `properties.expiresOn` (ISO-8601).
  Returns `{:ok, record}` or `{:error, refusal}` for a malformed body.
  """
  def put_policy_exemption(scope_prefix, name, body) do
    ensure_tables()

    assignment_id = get_in(body, ["properties", "policyAssignmentId"])
    expires_on = get_in(body, ["properties", "expiresOn"])

    cond do
      not is_binary(assignment_id) or assignment_id == "" ->
        {:error, exemption_refusal(scope_prefix, name, "policyAssignmentId is required")}

      expires_on != nil and not is_binary(expires_on) ->
        {:error, exemption_refusal(scope_prefix, name, "expiresOn must be an ISO-8601 string")}

      true ->
        record = %{
          "id" => "#{scope_prefix}/providers/Microsoft.Authorization/policyExemptions/#{name}",
          "name" => name,
          "type" => "Microsoft.Authorization/policyExemptions",
          "properties" => %{
            "policyAssignmentId" => assignment_id,
            "scope" => get_in(body, ["properties", "scope"]) || scope_prefix,
            "expiresOn" => expires_on,
            "category" => get_in(body, ["properties", "category"]) || "Waiver"
          }
        }

        :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
        {:ok, record}
    end
  end

  def get_policy_exemption(scope_prefix, name) do
    ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(exemption_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_exemptions(scope_prefix) do
    ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyexemptions/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policyExemptions"))
    |> Enum.filter(&(String.downcase(&1["id"]) |> String.starts_with?(prefix)))
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Deletes an exemption. An exemption whose `expiresOn` is in the past is
  swept too (ARM semantics: an expired exemption no longer exempts, so it
  must not linger GETable).
  """
  def delete_policy_exemption(scope_prefix, name) do
    ensure_tables()

    case get_policy_exemption(scope_prefix, name) do
      {:ok, record} ->
        # Cascade the exemption's receipts keyed by its exemption id.
        ex_id_low = String.downcase(record["id"])

        for {key, _} <- :ets.tab2list(:smalt_policy),
            is_binary(key) and String.starts_with?(key, "exr:#{ex_id_low}:") do
          :ets.delete(:smalt_policy, key)
        end

        :ets.delete(:smalt_policy, ex_id_low)
        :ok

      :error ->
        :ok
    end
  end

  defp exemption_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyExemptions/#{name}"

  defp exemption_refusal(scope_prefix, name, reason),
    do: %{
      "error" => %{
        "code" => "PolicyExemptionInvalid",
        "message" => "Policy exemption '#{name}' at scope '#{scope_prefix}' is invalid. #{reason}.",
        "target" => nil,
        "innererror" => %{}
      }
    }

  # ===========================================================================
  # Clock seam
  # ===========================================================================

  @doc """
  Expiry clock, overridable in tests via
  `Application.put_env(:smalt, :policy_now_ms, ms)`.
  """
  def now_ms do
    Application.get_env(:smalt, :policy_now_ms) ||
      DateTime.utc_now() |> DateTime.to_unix(:millisecond)
  end

  defp expired?(nil), do: false

  defp expired?(expires_on) when is_binary(expires_on) do
    case DateTime.from_iso8601(expires_on) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) <= now_ms()
      _ -> false
    end
  end

  defp expired?(_), do: false

  @doc "Whether the exemption record is active (exists and expiresOn not past)."
  def exemption_active?(record) do
    is_map(record) and not expired?(get_in(record, ["properties", "expiresOn"]))
  end

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
    ensure_tables()

    resource_id = String.downcase(record["id"] || "")

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
    ensure_tables()

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
        # Deterministic worst-effect: any deny wins, first by sorted assignment id.
        verdicts
        |> Enum.map(fn {effect, _def_id, reason} -> {effect, assignment, reason} end)
        |> Enum.sort_by(fn {effect, a, _} -> {effect_rank(effect), a["id"]} end)
        |> List.first()
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
        exemption_active?(ex) and
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
