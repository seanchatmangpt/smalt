# CONVERGENCE lane V10 — ARM policy-assignments read surface court.
#
# Chicago discipline: real in-process dispatch through
# Smalt.ArmGateway.Router, real :smalt_policy rows (seeded through
# Smalt.ArmGateway.PolicyAssignments.seed/1). No mocks. The documented
# envelope and the seeded athena-encoded classes (required-tags audit-deny,
# location-allowlist) are asserted on the REAL list routes at BOTH scopes,
# plus the documented empty envelope for an unknown scope.

defmodule Smalt.Internal.PolicyAssignmentsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.PolicyAssignments
  alias Smalt.ArmGateway.Router

  @sub "sub-v10"
  @seed_rg PolicyAssignments.seed_rg()
  @pa_type "Microsoft.Authorization/policyAssignments"

  setup do
    clean(@sub)

    on_exit(fn -> clean(@sub) end)

    :ok
  end

  defp clean(sub) do
    case :ets.info(:smalt_policy) do
      :undefined ->
        :ok

      _ ->
        prefix = String.downcase("/subscriptions/#{sub}/")

        for {key, _} <- :ets.tab2list(:smalt_policy),
            is_binary(key) and String.contains?(key, prefix) and
              String.contains?(key, "policyassignments") do
          :ets.delete(:smalt_policy, key)
        end

        :ok
    end
  end

  defp sub_list_path(sub \\ @sub),
    do:
      "/subscriptions/#{sub}/providers/Microsoft.Authorization/policyAssignments?api-version=2024-05-01"

  defp rg_list_path(rg, sub \\ @sub),
    do:
      "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Authorization/policyAssignments?api-version=2024-05-01"

  # One decode helper — the court asserts on decoded envelopes only.
  defp get_decoded(path) do
    conn = Router.call(Plug.Conn.fetch_query_params(conn(:get, path)), [])
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  test "documented envelope: seeded assignments listed at subscription scope" do
    assert PolicyAssignments.seed(@sub) == 4

    {status, body} = get_decoded(sub_list_path())

    assert status == 200
    assert Map.keys(body) == ["value"]
    assert is_list(body["value"])

    names = Enum.map(body["value"], & &1["name"])
    assert Enum.sort(names) == ["location-allowlist", "required-tags"]

    for rec <- body["value"] do
      assert rec["type"] == @pa_type

      assert String.downcase(rec["id"]) ==
               String.downcase(
                 "/subscriptions/#{@sub}/providers/Microsoft.Authorization/policyAssignments/#{rec["name"]}"
               )

      assert rec["properties"]["enforcementMode"] == "Default"
      assert String.starts_with?(rec["properties"]["scope"], "/subscriptions/#{@sub}")

      assert String.contains?(rec["properties"]["policyDefinitionId"], rec["name"])
    end

    tags = Enum.find(body["value"], &(&1["name"] == "required-tags"))

    assert tags["properties"]["policyDefinitionId"] ==
             "/providers/Microsoft.Authorization/policyDefinitions/required-tags"

    loc = Enum.find(body["value"], &(&1["name"] == "location-allowlist"))

    assert loc["properties"]["policyDefinitionId"] ==
             "/providers/Microsoft.Authorization/policyDefinitions/location-allowlist"
  end

  test "documented envelope: seeded assignments listed at resource-group scope" do
    assert PolicyAssignments.seed(@sub) == 4

    {status, body} = get_decoded(rg_list_path(@seed_rg))

    assert status == 200
    assert Map.keys(body) == ["value"]

    names = Enum.map(body["value"], & &1["name"])
    assert Enum.sort(names) == ["location-allowlist", "required-tags"]

    for rec <- body["value"] do
      assert rec["type"] == @pa_type

      assert rec["properties"]["scope"] ==
               "/subscriptions/#{@sub}/resourceGroups/#{@seed_rg}"

      assert String.contains?(rec["id"], "/resourceGroups/#{@seed_rg}/")
    end
  end

  test "list faces are disjoint by scope: sub rows never carry /resourceGroups/" do
    assert PolicyAssignments.seed(@sub) == 4

    {_, sub_body} = get_decoded(sub_list_path())
    {_, rg_body} = get_decoded(rg_list_path(@seed_rg))

    for rec <- sub_body["value"] do
      refute String.contains?(rec["id"], "/resourceGroups/")
    end

    for rec <- rg_body["value"] do
      assert String.contains?(rec["id"], "/resourceGroups/#{@seed_rg}/")
    end
  end

  test "unknown scope -> documented empty envelope, never a 404" do
    assert PolicyAssignments.list_subscriptions_scope("sub-unknown-v10") == %{"value" => []}

    assert PolicyAssignments.list_resource_groups_scope("sub-unknown-v10", "rg-unknown-v10") ==
             %{"value" => []}

    {status, body} = get_decoded(sub_list_path("sub-unknown-v10"))
    assert status == 200
    assert body == %{"value" => []}

    {status, body} = get_decoded(rg_list_path("rg-unknown-v10", "sub-unknown-v10"))
    assert status == 200
    assert body == %{"value" => []}
  end

  test "seed is idempotent: re-seed overwrites the same ids, envelope stays at 2 per scope" do
    assert PolicyAssignments.seed(@sub) == 4
    assert PolicyAssignments.seed(@sub) == 4

    {_, sub_body} = get_decoded(sub_list_path())
    assert length(sub_body["value"]) == 2

    {_, rg_body} = get_decoded(rg_list_path(@seed_rg))
    assert length(rg_body["value"]) == 2
  end
end
