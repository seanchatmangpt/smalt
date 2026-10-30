defmodule Smalt.Policy.Remediations do

  @moduledoc """
  Policy remediations (Microsoft.Authorization/policyRemediations) — the ARM
  face for scoped remediation records and their trigger.

  PUT/GET/LIST/DELETE at sub+RG scope, plus `trigger_policy_remediation/2`,
  which re-runs the assignment evaluation per resourceId at trigger time and
  records compliant-after / still-violating receipts. `Smalt.Policy.enforce/3`
  snapshots each evaluated record ("rs:" rows) so a trigger re-evaluates the
  live resource state.
  """

  alias Smalt.Policy.Eval
  alias Smalt.Policy.Store


  # ===========================================================================
  # Policy remediations (Microsoft.Authorization/policyRemediations)
  # ===========================================================================

  @doc """
  Puts a policy remediation at a scope (subscription or RG placement). Requires
  `properties.policyAssignmentId` and a non-empty `properties.resourceIds`
  string list. Returns `{:ok, record}` or `{:error, refusal}` for a malformed
  body.

  The record's `properties.provisioningState` starts as "Succeeded" (the PUT
  itself never fails on policy state) with a nil `remediationSummary` until
  `trigger_policy_remediation/2` re-runs the assignment evaluation per
  resource.
  """
  def put_policy_remediation(scope_prefix, name, body) do
    Store.ensure_tables()

    assignment_id = get_in(body, ["properties", "policyAssignmentId"])
    resource_ids = get_in(body, ["properties", "resourceIds"])

    valid_resources? =
      is_list(resource_ids) and resource_ids != [] and
        Enum.all?(resource_ids, &is_binary/1)

    cond do
      not is_binary(assignment_id) or assignment_id == "" ->
        {:error,
         remediation_refusal(scope_prefix, name, "policyAssignmentId is required")}

      not valid_resources? ->
        {:error,
         remediation_refusal(
           scope_prefix,
           name,
           "resourceIds must be a non-empty list of resource id strings"
         )}

      true ->
        record = %{
          "id" => "#{scope_prefix}/providers/Microsoft.Authorization/policyRemediations/#{name}",
          "name" => name,
          "type" => "Microsoft.Authorization/policyRemediations",
          "properties" => %{
            "policyAssignmentId" => assignment_id,
            "resourceIds" => resource_ids,
            "provisioningState" => "Succeeded",
            "remediationSummary" => nil,
            "lastTriggeredOn" => nil
          }
        }

        :ets.insert(:smalt_policy, {String.downcase(record["id"]), record})
        {:ok, record}
    end
  end

  def get_policy_remediation(scope_prefix, name) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase(remediation_id(scope_prefix, name))) do
      [{_, record}] -> {:ok, record}
      [] -> :error
    end
  end

  def list_policy_remediations(scope_prefix) do
    Store.ensure_tables()

    prefix =
      String.downcase("#{scope_prefix}/providers/microsoft.authorization/policyremediations/")

    :smalt_policy
    |> :ets.tab2list()
    |> Enum.map(fn {_, r} -> r end)
    |> Enum.filter(&(is_map(&1) and &1["type"] == "Microsoft.Authorization/policyRemediations"))
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

  @doc """
  Deletes a remediation and cascades its per-resource remediation receipts
  (prefix scan on "rem:<remediation id lower>:" — same cascade law as the
  assignment's nc: receipt sweep).
  """
  def delete_policy_remediation(scope_prefix, name) do
    Store.ensure_tables()

    rem_id_low = String.downcase(remediation_id(scope_prefix, name))

    for {key, _} <- :ets.tab2list(:smalt_policy),
        is_binary(key) and String.starts_with?(key, "rem:#{rem_id_low}:") do
      :ets.delete(:smalt_policy, key)
    end

    :ets.delete(:smalt_policy, rem_id_low)
    :ok
  end

  @doc """
  Re-runs the remediation's assignment evaluation for EVERY resourceId at
  trigger time (never at PUT time) and records one remediation receipt per
  resource, keyed "rem:<remediation id lower>:<resource id lower>" with
  `smaltReceiptType` "policyRemediation":

  - compliant — the re-run evaluation finds the resource satisfies the
    assignment's rules (including the exemption / DoNotEnforce paths, which
    are `:ok` verdicts in `evaluate_assignment/2`).
  - still-violating — the re-run finds a violation, with the reason carried
    from the evaluation.

  Typed faces on the still-violating side:

  - the assignment was deleted after the remediation was created → the
    receipt records still-violating with reason prefix
    "policyAssignmentNotFound" (a remediation whose assignment is gone cannot
    prove compliance, so it never reports compliant-after).
  - no resource state snapshot exists (the resource was never evaluated by
    `enforce/3`) → "resourceStateNotFound".

  Returns `{:ok, updated_record}` or `:error` when the remediation does not
  exist.
  """
  def trigger_policy_remediation(scope_prefix, name) do
    Store.ensure_tables()

    case get_policy_remediation(scope_prefix, name) do
      {:ok, record} ->
        assignment_id = get_in(record, ["properties", "policyAssignmentId"])
        assignment = Eval.lookup_definition_by_id(assignment_id)

        verdicts =
          record
          |> get_in(["properties", "resourceIds"])
          |> Enum.map(fn resource_id ->
            verdict =
              cond do
                is_nil(assignment) ->
                  {"still-violating",
                   "policyAssignmentNotFound: assignment '#{assignment_id}' does not exist"}

                is_nil(resource_state(resource_id)) ->
                  {"still-violating",
                   "resourceStateNotFound: resource '#{resource_id}' has no evaluated state"}

                true ->
                  case Eval.evaluate_assignment(assignment, resource_state(resource_id)) do
                    :ok ->
                      {"compliant", "Resource complies with all assigned policy rules"}

                    {effect, _assignment, reason} ->
                      {"still-violating", "#{reason} (effect=#{effect})"}
                  end
              end

            {outcome, reason} = verdict
            record_remediation_receipt(record, assignment_id, resource_id, outcome, reason)
            %{"resourceId" => resource_id, "status" => outcome, "reason" => reason}
          end)

        summary = %{
          "compliant" => Enum.count(verdicts, &(&1["status"] == "compliant")),
          "stillViolating" => Enum.count(verdicts, &(&1["status"] == "still-violating"))
        }

        updated =
          put_in(record, ["properties", "remediationSummary"], summary)
          |> put_in(["properties", "perResourceStatus"], verdicts)
          |> put_in(["properties", "lastTriggeredOn"], DateTime.from_unix!(Store.now_ms(), :millisecond) |> DateTime.to_iso8601())

        :ets.insert(:smalt_policy, {String.downcase(updated["id"]), updated})
        {:ok, updated}

      :error ->
        :error
    end
  end

  defp remediation_id(scope_prefix, name),
    do: "#{scope_prefix}/providers/Microsoft.Authorization/policyRemediations/#{name}"

  defp remediation_refusal(scope_prefix, name, reason),
    do: %{
      "error" => %{
        "code" => "PolicyRemediationInvalid",
        "message" => "Policy remediation '#{name}' at scope '#{scope_prefix}' is invalid. #{reason}.",
        "target" => nil,
        "innererror" => %{}
      }
    }

  defp record_remediation_receipt(remediation, assignment_id, resource_id, outcome, reason) do
    key = String.downcase("rem:#{remediation["id"]}:#{resource_id}")

    row = %{
      "smaltReceiptType" => "policyRemediation",
      "policyRemediationId" => remediation["id"],
      "policyAssignmentId" => assignment_id,
      "resourceId" => resource_id,
      "outcome" => outcome,
      "reason" => reason
    }

    :ets.insert(:smalt_policy, {key, row})
  end

  @doc """
  Resource-state snapshot reader for the remediation trigger: the most recent
  record `enforce/3` evaluated for this resource id (deny AND ok paths both
  snapshot). Nil when the resource was never evaluated.
  """
  def resource_state(resource_id) do
    Store.ensure_tables()

    case :ets.lookup(:smalt_policy, String.downcase("rs:#{resource_id || ""}")) do
      [{_, row}] -> row["record"]
      [] -> nil
    end
  end
end
