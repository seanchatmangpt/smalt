defmodule Smalt.PolicyRbacTest do
  @moduledoc """
  Additive tests for the 80/20 Azure Policy + RBAC lane: role assignment CRUD
  + built-in roleDefinitions, policy definition/assignment CRUD, enforcement
  (deny -> 400 PolicyViolation / compliant -> 201), and policyInsights
  non-compliance listing.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @opts Router.init([])
  @av "api-version=2022-04-01"

  setup do
    if :ets.info(:smalt_resources) == :undefined, do: {:ok, _} = Store.start_link([])
    Store.clear()
    Smalt.Policy.reset_for_test()
    :ok
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp rg_path, do: "/subscriptions/sub-1/resourceGroups/rg-1"

  defp resource_path(name), do: "#{rg_path()}/providers/Microsoft.Storage/storageAccounts/#{name}"

  defp put_resource(name, overrides \\ %{}) do
    payload =
      Map.merge(
        %{"location" => "eastus", "properties" => %{}},
        overrides
      )

    conn(:put, resource_path(name) <> "?api-version=2021-04-01", payload)
    |> Router.call(@opts)
  end

  defp put_policy_definition(name, rule) do
    conn(
      :put,
      "/subscriptions/sub-1/providers/Microsoft.Authorization/policyDefinitions/#{name}?#{@av}",
      %{"properties" => %{"policyRule" => rule}}
    )
    |> Router.call(@opts)
    |> tap(&assert(&1.status == 201, "policy definition PUT failed: #{&1.status}"))
  end

  defp put_assignment(name, def_name, scope_path) do
    conn(
      :put,
      "#{scope_path}/providers/Microsoft.Authorization/policyAssignments/#{name}?#{@av}",
      %{
        "properties" => %{
          "policyDefinitionId" =>
            "/subscriptions/sub-1/providers/Microsoft.Authorization/policyDefinitions/#{def_name}"
        }
      }
    )
    |> Router.call(@opts)
    |> tap(&assert(&1.status == 201, "policy assignment PUT failed: #{&1.status}"))
  end

  defp summarize do
    conn(
      :get,
      "/subscriptions/sub-1/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?#{@av}"
    )
    |> Router.call(@opts)
    |> body()
    |> Map.fetch!("value")
  end

  defp query_results(assignment_id) do
    conn(
      :get,
      "/subscriptions/sub-1/providers/Microsoft.PolicyInsights/policyStates/latest/queryResults?policyAssignmentId=#{URI.encode_www_form(assignment_id)}&#{@av}"
    )
    |> Router.call(@opts)
    |> body()
    |> Map.fetch!("value")
  end

  # -- Role assignments ----------------------------------------------------------

  describe "role assignments (RBAC)" do
    test "PUT/GET/DELETE + list at subscription scope" do
      put_conn =
        conn(
          :put,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleAssignments/ra-1?#{@av}",
          %{
            # location is DefaultShape's required path (refusal-tier law:
            # a location-less body answers 400 InvalidResourceShape).
            "location" => "eastus",
            "properties" => %{
              "principalId" => "00000000-0000-0000-0000-000000000001",
              "roleDefinitionId" =>
                "/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
              "scope" => "/subscriptions/sub-1"
            }
          }
        )
        |> Router.call(@opts)

      assert put_conn.status == 201
      ra = body(put_conn)
      assert ra["type"] == "Microsoft.Authorization/roleAssignments"
      assert ra["properties"]["principalId"] == "00000000-0000-0000-0000-000000000001"
      assert ra["properties"]["scope"] == "/subscriptions/sub-1"

      get_conn =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleAssignments/ra-1?#{@av}"
        )
        |> Router.call(@opts)

      assert get_conn.status == 200
      assert body(get_conn)["name"] == "ra-1"

      list_conn =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleAssignments?#{@av}"
        )
        |> Router.call(@opts)

      assert list_conn.status == 200
      assert [%{"name" => "ra-1"}] = body(list_conn)["value"]

      del_conn =
        conn(
          :delete,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleAssignments/ra-1?#{@av}"
        )
        |> Router.call(@opts)

      assert del_conn.status == 200

      get_after =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleAssignments/ra-1?#{@av}"
        )
        |> Router.call(@opts)

      assert get_after.status == 404
    end

    test "RG-scope variant + scope-scoped list" do
      put_conn =
        conn(
          :put,
          "#{rg_path()}/providers/Microsoft.Authorization/roleAssignments/ra-rg?#{@av}",
          %{
            "location" => "eastus",
            "properties" => %{
              "principalId" => "00000000-0000-0000-0000-000000000002",
              "roleDefinitionId" =>
                "/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
            }
          }
        )
        |> Router.call(@opts)

      assert put_conn.status == 201
      assert body(put_conn)["properties"]["scope"] == rg_path()

      list_conn =
        conn(:get, "#{rg_path()}/providers/Microsoft.Authorization/roleAssignments?#{@av}")
        |> Router.call(@opts)

      assert [%{"name" => "ra-rg"}] = body(list_conn)["value"]
    end

    test "built-in roleDefinitions served by name and by GUID (Owner/Contributor/Reader)" do
      for {q, expected} <- [
            {"Owner", "Owner"},
            {"reader", "Reader"},
            {"b24988ac-6180-42a0-ab88-20f7382dd24c", "Contributor"}
          ] do
        conn =
          conn(
            :get,
            "/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/#{q}?#{@av}"
          )
          |> Router.call(@opts)

        assert conn.status == 200
        assert body(conn)["properties"]["roleName"] == expected
        assert body(conn)["properties"]["type"] == "BuiltInRole"
      end

      missing =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/roleDefinitions/NoSuchRole?#{@av}"
        )
        |> Router.call(@opts)

      assert missing.status == 404
    end
  end

  # -- Policy definitions / assignments ------------------------------------------

  describe "policy definitions and assignments" do
    test "policy definition PUT/GET round-trips the policyRule" do
      rule = %{
        "if" => %{"field" => "location", "notIn" => ["eastus", "westus"]},
        "then" => %{"effect" => "deny"}
      }

      put_conn = put_policy_definition("allowed-locations", rule)
      assert body(put_conn)["properties"]["policyRule"]["if"]["notIn"] == ["eastus", "westus"]

      get_conn =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/policyDefinitions/allowed-locations?#{@av}"
        )
        |> Router.call(@opts)

      assert get_conn.status == 200
      assert body(get_conn)["properties"]["policyRule"]["if"]["notIn"] == ["eastus", "westus"]

      list_conn =
        conn(
          :get,
          "/subscriptions/sub-1/providers/Microsoft.Authorization/policyDefinitions?#{@av}"
        )
        |> Router.call(@opts)

      assert [%{"name" => "allowed-locations"}] = body(list_conn)["value"]
    end

    test "assignment at RG scope derives its scope from the placement, not the body" do
      put_conn = put_assignment("loc-guard", "allowed-locations", rg_path())
      assert body(put_conn)["properties"]["scope"] == rg_path()

      get_conn =
        conn(
          :get,
          "#{rg_path()}/providers/Microsoft.Authorization/policyAssignments/loc-guard?#{@av}"
        )
        |> Router.call(@opts)

      assert get_conn.status == 200
    end
  end

  # -- Enforcement ---------------------------------------------------------------

  describe "policy enforcement on resource PUT" do
    test "non-compliant PUT -> 400 PolicyViolation, resource NOT persisted" do
      put_policy_definition("allowed-locations", %{
        "if" => %{"field" => "location", "notIn" => ["eastus", "westus"]},
        "then" => %{"effect" => "deny"}
      })

      put_assignment("loc-guard", "allowed-locations", rg_path())

      conn = put_resource("bad-thing", %{"location" => "northcentralus"})
      assert conn.status == 400
      assert body(conn)["error"]["code"] == "PolicyViolation"
      assert body(conn)["error"]["target"] =~ "policyAssignments/loc-guard"
      assert body(conn)["error"]["innererror"] == %{}

      refute match?(
               {:ok, _},
               Store.get(:smalt_resources, String.downcase(resource_path("bad-thing")))
             )
    end

    test "compliant PUT -> 201 and clears prior non-compliance receipts" do
      put_policy_definition("env-guard", %{
        "if" => %{"field" => "tags.env", "notEquals" => "prod"},
        "then" => %{"effect" => "deny"}
      })

      put_assignment("env-guard", "env-guard", rg_path())

      assert put_resource("flip", %{"tags" => %{"env" => "dev"}}).status == 400
      assert summarize() != []

      assert put_resource("flip", %{"tags" => %{"env" => "prod"}}).status in [200, 202]
      assert summarize() == []
    end

    test "audit effect records non-compliance but allows the PUT" do
      put_policy_definition("require-env-tag-audit", %{
        "if" => %{"field" => "tags", "containsKey" => "env"},
        "then" => %{"effect" => "audit"}
      })

      put_assignment("env-audit", "require-env-tag-audit", rg_path())

      assert put_resource("untagged-thing").status in [200, 202]
      assert summarize() == []

      assert put_resource("tagged-thing", %{"tags" => %{"env" => "prod"}}).status in [200, 202]

      entry =
        Enum.find(summarize(), fn e ->
          e["policyAssignmentId"] =~ "policyAssignments/env-audit"
        end)

      assert entry["results"]["nonCompliantResources"] == 1
    end

    test "required tag deny + subscription-scope assignment applies to every RG" do
      put_policy_definition("require-tags", %{
        "if" => %{"field" => "tags.env", "notEquals" => "prod"},
        "then" => %{"effect" => "deny"}
      })

      put_assignment("tags-guard", "require-tags", "/subscriptions/sub-1")

      conn = put_resource("tagless", %{"tags" => %{"team" => "x"}})
      assert conn.status == 400
      assert body(conn)["error"]["code"] == "PolicyViolation"

      conn2 =
        conn(
          :put,
          "/subscriptions/sub-1/resourceGroups/rg-2/providers/Microsoft.Storage/storageAccounts/tagged?api-version=2021-04-01",
          %{"location" => "eastus", "tags" => %{"env" => "prod"}, "properties" => %{}}
        )
        |> Router.call(@opts)

      assert conn2.status in [200, 202]
    end

    test "no assignment -> PUT proceeds untouched" do
      assert put_resource("plain").status in [200, 202]
    end

    test "sku size deny rule via dotted field" do
      put_policy_definition("sku-sizes", %{
        "if" => %{"field" => "sku.name", "in" => ["Standard_GRS"]},
        "then" => %{"effect" => "deny"}
      })

      put_assignment("sku-guard", "sku-sizes", rg_path())

      conn =
        conn(
          :put,
          resource_path("big-vm") <> "?api-version=2021-04-01",
          %{"location" => "eastus", "sku" => %{"name" => "Standard_GRS"}, "properties" => %{}}
        )
        |> Router.call(@opts)

      assert conn.status == 400
      assert body(conn)["error"]["code"] == "PolicyViolation"

      assert put_resource("small-vm", %{"sku" => %{"name" => "Standard_LRS"}}).status in [
               200,
               202
             ]
    end
  end

  # -- policyInsights ------------------------------------------------------------

  describe "policyInsights" do
    test "queryResults lists non-compliant resources per assignment; assignment delete cascades" do
      put_policy_definition("allowed-locations", %{
        "if" => %{"field" => "location", "notIn" => ["eastus"]},
        "then" => %{"effect" => "deny"}
      })

      put_assignment("loc-guard", "allowed-locations", rg_path())

      assert put_resource("bad-thing", %{"location" => "brazilsouth"}).status == 400

      assignment_id = "#{rg_path()}/providers/Microsoft.Authorization/policyAssignments/loc-guard"

      assert query_results(assignment_id) == [resource_path("bad-thing")]

      del_conn =
        conn(:delete, assignment_id <> "?#{@av}")
        |> Router.call(@opts)

      assert del_conn.status == 200
      assert query_results(assignment_id) == []
    end
  end
end
