defmodule Smalt.Test.Integration.PolicyEnforcementModeWitnessTest do
  @moduledoc """
  PY wf6 witness: `properties.enforcementMode` on policyAssignments PUT is
  persisted and echoed on GET, and is honored by `Smalt.Policy.enforce/3` —
  a `DoNotEnforce` assignment never refuses (a would-be deny is downgraded to
  an audit verdict and the non-compliance receipt notes the mode); flipping to
  `Default` re-arms the deny. Real `Smalt.Policy` against the real ETS tables,
  ARM-cased ids per AZB-25c (mixed-case `resourceGroups`).
  """

  use ExUnit.Case, async: false

  alias Smalt.Policy

  setup do
    Policy.reset_for_test()
    :ok
  end

  test "enforcementMode persists, echoes on GET, defaults to Default when omitted" do
    sub = "sub-w2b"
    rg = "rg-W2B"                       # ARM-cased (AZB-25c)
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

    def_id = defn["id"]

    assignment =
      Policy.put_policy_assignment(scope, "deny-assignment", %{
        "properties" => %{"policyDefinitionId" => def_id, "enforcementMode" => "DoNotEnforce"}
      })

    assert get_in(assignment, ["properties", "enforcementMode"]) == "DoNotEnforce"

    {:ok, fetched} = Policy.get_policy_assignment(scope, "deny-assignment")
    assert get_in(fetched, ["properties", "enforcementMode"]) == "DoNotEnforce"

    _ =
      Policy.put_policy_assignment(scope, "default-assignment", %{
        "properties" => %{"policyDefinitionId" => def_id}
      })

    {:ok, dflt} = Policy.get_policy_assignment(scope, "default-assignment")
    assert get_in(dflt, ["properties", "enforcementMode"]) == "Default"
  end

  test "DoNotEnforce: violating PUT succeeds with audit receipt; Default flip denies" do
    sub = "sub-w2b"
    rg = "rg-W2B"
    scope = "/subscriptions/#{sub}/resourceGroups/#{rg}"

    defn =
      Policy.put_policy_definition(sub, "deny-name-policy", %{
        "properties" => %{
          "policyRule" => %{"if" => %{"field" => "name", "notEquals" => "allowed-vm"},
                            "then" => %{"effect" => "deny"}}
        }
      })

    def_id = defn["id"]

    assignment =
      Policy.put_policy_assignment(scope, "deny-assignment", %{
        "properties" => %{"policyDefinitionId" => def_id, "enforcementMode" => "DoNotEnforce"}
      })

    violating = %{
      "id" => "#{scope}/providers/Microsoft.Compute/virtualMachines/bad-vm",
      "name" => "bad-vm",
      "type" => "Microsoft.Compute/virtualMachines",
      "location" => "westeu"
    }

    # DoNotEnforce: the violating PUT proceeds; a non-compliance receipt
    # noting the mode is recorded instead of a refusal.
    assert :ok = Policy.enforce(sub, rg, violating)

    assignment_id = assignment["id"]
    assert [bad_vm_id] = Policy.non_compliant_resources(assignment_id)
    assert bad_vm_id == violating["id"]

    # The receipt notes the mode: audit effect + enforcementMode=DoNotEnforce.
    nc_key = String.downcase("nc:#{assignment_id}:#{violating["id"]}")
    [{_, row}] = :ets.lookup(:smalt_policy, nc_key)
    assert row["effect"] == "audit"
    assert row["reason"] =~ "enforcementMode=DoNotEnforce"

    summary = Policy.non_compliance_summary()
    assert [%{"policyAssignmentId" => ^assignment_id}] = summary

    # Flip to Default: the same violating PUT is refused with 400 PolicyViolation.
    _ =
      Policy.put_policy_assignment(scope, "deny-assignment", %{
        "properties" => %{"policyDefinitionId" => def_id, "enforcementMode" => "Default"}
      })

    assert {:deny, body} = Policy.enforce(sub, rg, violating)
    assert %{"error" => %{"code" => "PolicyViolation"}} = Jason.decode!(body)
  end
end
