defmodule Smalt.Test.Integration.PolicyRemediationWitnessTest do
  @moduledoc """
  W2-L witness: policyRemediations — PUT/GET/LIST/DELETE at sub+RG scope, and
  the enforcement interplay: `trigger_policy_remediation/2` re-runs the
  assignment evaluation per resourceId at TRIGGER time against the live
  resource-state snapshot (`enforce/3` "rs:" rows) and records one receipt per
  resource:

  - compliant (compliant-after: the resource was re-enforced into compliance
    and the trigger re-evaluation returns :ok, exemption path included)
  - still-violating (unchanged resource; and the typed face
    `policyAssignmentNotFound` when the assignment was deleted after the
    remediation was created — a remediation whose assignment is gone cannot
    prove compliance)
  - `resourceStateNotFound` for a resource never evaluated by `enforce/3`.

  Real `Smalt.Policy` against the real ETS tables, ARM-cased ids per AZB-25c.
  """

  use ExUnit.Case, async: false

  alias Smalt.Policy

  setup do
    Policy.reset_for_test()
    :ok
  end

  defp deny_policy(sub, rg) do
    scope = "/subscriptions/#{sub}/resourceGroups/#{rg}"

    defn =
      Policy.put_policy_definition(sub, "deny-name-policy", %{
        "properties" => %{
          "policyRule" => %{
            "if" => %{"field" => "name", "notEquals" => "allowed-vm"},
            "then" => %{"effect" => "deny"}
          }
        }
      })

    assignment =
      Policy.put_policy_assignment(scope, "deny-assignment", %{
        "properties" => %{"policyDefinitionId" => defn["id"]}
      })

    {scope, assignment, defn}
  end

  defp violating_vm(scope),
    do: %{
      "id" => "#{scope}/providers/Microsoft.Compute/virtualMachines/bad-vm",
      "name" => "bad-vm",
      "type" => "Microsoft.Compute/virtualMachines",
      "location" => "westeu"
    }

  defp compliant_vm(scope),
    do: %{violating_vm(scope) | "name" => "allowed-vm"}

  test "deny policy -> violating resource -> PUT remediation -> trigger records per-resource receipts" do
    sub = "sub-w2l"
    rg = "rg-W2L"
    {scope, assignment, _defn} = deny_policy(sub, rg)
    assignment_id = assignment["id"]
    resource_id = "#{scope}/providers/Microsoft.Compute/virtualMachines/bad-vm"

    # Deny: the violating resource cannot land; the refusal leaves a receipt.
    assert {:deny, body} = Policy.enforce(sub, rg, violating_vm(scope))
    assert %{"error" => %{"code" => "PolicyViolation"}} = Jason.decode!(body)

    # PUT remediation: typed refusals first.
    assert {:error, refusal} =
             Policy.put_policy_remediation(scope, "rem-1", %{
               "properties" => %{"resourceIds" => [resource_id]}
             })

    assert %{"error" => %{"code" => "PolicyRemediationInvalid"}} = refusal

    assert {:error, _} =
             Policy.put_policy_remediation(scope, "rem-1", %{
               "properties" => %{"policyAssignmentId" => assignment_id, "resourceIds" => []}
             })

    assert {:error, _} =
             Policy.put_policy_remediation(scope, "rem-1", %{
               "properties" => %{"policyAssignmentId" => assignment_id, "resourceIds" => [1]}
             })

    # The valid PUT lands.
    {:ok, rem} =
      Policy.put_policy_remediation(scope, "rem-1", %{
        "properties" => %{"policyAssignmentId" => assignment_id, "resourceIds" => [resource_id]}
      })

    assert get_in(rem, ["properties", "provisioningState"]) == "Succeeded"
    assert get_in(rem, ["properties", "remediationSummary"]) == nil

    assert {:ok, ^rem} = Policy.get_policy_remediation(scope, "rem-1")
    assert [%{"name" => "rem-1"}] = Policy.list_policy_remediations(scope)

    # Trigger: the resource is STILL violating (its snapshot is the refused
    # record) — one still-violating receipt per resource.
    {:ok, triggered} = Policy.trigger_policy_remediation(scope, "rem-1")

    assert get_in(triggered, ["properties", "remediationSummary"]) == %{
             "compliant" => 0,
             "stillViolating" => 1
           }

    rem_id = rem["id"]

    nc_key = String.downcase("rem:#{rem_id}:#{resource_id}")
    [{_, row}] = :ets.lookup(:smalt_policy, nc_key)
    assert row["outcome"] == "still-violating"
    assert row["reason"] =~ "does not satisfy policy"
    assert row["policyAssignmentId"] == assignment_id

    # Fix the resource: the compliant PUT passes enforcement and updates the
    # resource-state snapshot.
    assert :ok = Policy.enforce(sub, rg, compliant_vm(scope))

    {:ok, triggered2} = Policy.trigger_policy_remediation(scope, "rem-1")
    assert get_in(triggered2, ["properties", "remediationSummary"]) == %{"compliant" => 1, "stillViolating" => 0}

    [{_, row2}] = :ets.lookup(:smalt_policy, nc_key)
    assert row2["outcome"] == "compliant"

    # Trigger against a never-evaluated resource: typed resourceStateNotFound.
    {:ok, _} =
      Policy.put_policy_remediation(scope, "rem-ghost", %{
        "properties" => %{
          "policyAssignmentId" => assignment_id,
          "resourceIds" => ["#{scope}/providers/Microsoft.Compute/virtualMachines/ghost"]
        }
      })

    {:ok, ghost} = Policy.trigger_policy_remediation(scope, "rem-ghost")

    assert get_in(ghost, ["properties", "remediationSummary"]) == %{
             "compliant" => 0,
             "stillViolating" => 1
           }

    assert hd(get_in(ghost, ["properties", "perResourceStatus"]))["reason"] =~
             "resourceStateNotFound"
  end

  test "assignment deleted -> remediation re-eval is still-violating with policyAssignmentNotFound face" do
    sub = "sub-w2l"
    rg = "rg-W2L"
    {scope, assignment, defn} = deny_policy(sub, rg)
    assignment_id = assignment["id"]
    resource_id = "#{scope}/providers/Microsoft.Compute/virtualMachines/bad-vm"

    assert {:deny, _} = Policy.enforce(sub, rg, violating_vm(scope))

    {:ok, rem} =
      Policy.put_policy_remediation(scope, "rem-2", %{
        "properties" => %{"policyAssignmentId" => assignment_id, "resourceIds" => [resource_id]}
      })

    # Delete the assignment (cascades nc: receipts) — the remediation record
    # and its trigger surface survive.
    assert :ok = Policy.delete_policy_assignment(scope, "deny-assignment")
    assert Policy.get_policy_assignment(scope, "deny-assignment") == :error

    {:ok, triggered} = Policy.trigger_policy_remediation(scope, "rem-2")

    assert get_in(triggered, ["properties", "remediationSummary"]) == %{
             "compliant" => 0,
             "stillViolating" => 1
           }

    rem_id = rem["id"]

    [{_, row}] =
      :ets.lookup(:smalt_policy, String.downcase("rem:#{rem_id}:#{resource_id}"))

    assert row["outcome"] == "still-violating"
    assert row["reason"] =~ "policyAssignmentNotFound"
    refute row["reason"] =~ "complies"

    _ = defn

    # LIST at RG scope sees it; DELETE cascades the remediation receipts.
    assert [%{"name" => "rem-2"}] = Policy.list_policy_remediations(scope)
    assert :ok = Policy.delete_policy_remediation(scope, "rem-2")

    assert :ets.lookup(
             :smalt_policy,
             String.downcase("rem:#{rem_id}:#{resource_id}")
           ) == []

    assert Policy.list_policy_remediations(scope) == []
  end

  test "exempted resource re-evaluates compliant-after through the trigger" do
    sub = "sub-w2l"
    rg = "rg-W2L"
    {scope, assignment, _defn} = deny_policy(sub, rg)
    assignment_id = assignment["id"]
    resource_id = "#{scope}/providers/Microsoft.Compute/virtualMachines/bad-vm"

    assert {:deny, _} = Policy.enforce(sub, rg, violating_vm(scope))

    {:ok, _} =
      Policy.put_policy_remediation(scope, "rem-3", %{
        "properties" => %{"policyAssignmentId" => assignment_id, "resourceIds" => [resource_id]}
      })

    # An active exemption for this assignment covers the resource: the
    # re-run evaluation resolves :ok (exemption path) -> compliant.
    {:ok, _} =
      Policy.put_policy_exemption(scope, "waiver", %{
        "properties" => %{"policyAssignmentId" => assignment_id, "scope" => scope}
      })

    {:ok, triggered} = Policy.trigger_policy_remediation(scope, "rem-3")

    assert get_in(triggered, ["properties", "remediationSummary"]) == %{
             "compliant" => 1,
             "stillViolating" => 0
           }

    rem_id = "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Authorization/policyRemediations/rem-3"

    [{_, row}] =
      :ets.lookup(:smalt_policy, String.downcase("rem:#{rem_id}:#{resource_id}"))

    assert row["outcome"] == "compliant"
  end
end
