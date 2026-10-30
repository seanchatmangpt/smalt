# GAP1-C1 lane — custom roleDefinitions PUT/GET/DELETE on the ARM face.
#
# Gate:
# - PUT custom roleDefinition at subscription scope -> 201, then GET -> 200
#   with the same roleName/permissions/assignableScopes roundtripped
# - rg-scope PUT/GET/DELETE
# - built-in GET (Owner GUID) still serves 200 via Smalt.Policy, never stored
# - THE LAW: PUT with empty permissions -> 400 EmptyPermissions
# - THE LAW: PUT whose assignableScopes omit the placement scope -> 400
#   AssignableScopesMustIncludeScope
# - DELETE -> 200, then GET -> 404
# - DELETE of a definition referenced by a role assignment -> 400
#   RoleDefinitionInUse, definition survives
#
# Chicago discipline: real Smalt.Arm.Rbac ETS tables, real ARM router
# dispatch (Plug in-process), real Smalt.Policy built-in table — asserts on
# final state, no mocks.

defmodule Integration.RbacRoleDefinitionsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  @api_version "2022-04-01"
  @sub "00000000-0000-0000-0000-000000000000"
  @rg "rg-rbacdef"
  @base "/subscriptions/#{@sub}"
  @rg_base "#{@base}/resourceGroups/#{@rg}"

  setup do
    Smalt.Arm.Rbac.reset_for_test()
    :ok
  end

  defp arm_req(method, path, body \\ nil, api_version \\ @api_version) do
    url = "#{path}?api-version=#{api_version}"

    conn =
      if body do
        conn(method, url, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, url)
      end

    Smalt.ArmGateway.Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp def_body(role_name, scope) do
    %{
      "properties" => %{
        "roleName" => role_name,
        "permissions" => [%{"actions" => ["Microsoft.Storage/storageAccounts/read"]}],
        "assignableScopes" => [scope]
      }
    }
  end

  test "PUT custom role definition at subscription scope returns 201 and GET roundtrips" do
    body = def_body("custom-storage-reader", @base)

    conn = arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/def-guid-1", body)
    assert conn.status == 201

    rec = Jason.decode!(conn.resp_body)
    assert rec["name"] == "def-guid-1"
    assert rec["type"] == "Microsoft.Authorization/roleDefinitions"
    assert rec["properties"]["roleName"] == "custom-storage-reader"
    assert rec["id"] == "#{@base}/providers/Microsoft.Authorization/roleDefinitions/def-guid-1"

    get = arm_req(:get, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/def-guid-1")
    assert get.status == 200
    assert Jason.decode!(get.resp_body)["properties"]["roleName"] == "custom-storage-reader"
  end

  test "PUT + GET + DELETE at resource-group scope" do
    body = def_body("rg-scoped-role", @rg_base)

    conn = arm_req(:put, "#{@rg_base}/providers/Microsoft.Authorization/roleDefinitions/def-rg-1", body)
    assert conn.status == 201

    get = arm_req(:get, "#{@rg_base}/providers/Microsoft.Authorization/roleDefinitions/def-rg-1")
    assert get.status == 200
    assert Jason.decode!(get.resp_body)["id"] == "#{@rg_base}/providers/Microsoft.Authorization/roleDefinitions/def-rg-1"

    del = arm_req(:delete, "#{@rg_base}/providers/Microsoft.Authorization/roleDefinitions/def-rg-1")
    assert del.status == 200

    gone = arm_req(:get, "#{@rg_base}/providers/Microsoft.Authorization/roleDefinitions/def-rg-1")
    assert gone.status == 404
  end

  test "built-in role definition GET still serves 200 via Smalt.Policy" do
    conn = arm_req(:get, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["properties"]["type"] == "BuiltInRole"
  end

  test "PUT with empty permissions answers 400 EmptyPermissions" do
    body = %{
      "properties" => %{
        "roleName" => "bad",
        "permissions" => [],
        "assignableScopes" => [@base]
      }
    }

    conn = arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/bad-def", body)
    assert conn.status == 400

    err = Jason.decode!(conn.resp_body)
    assert err["error"]["code"] == "EmptyPermissions"
  end

  test "PUT whose assignableScopes omit the placement scope answers 400" do
    body = def_body("wrong-scope", "/subscriptions/other-sub")

    conn = arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/wrong-def", body)
    assert conn.status == 400

    err = Jason.decode!(conn.resp_body)
    assert err["error"]["code"] == "AssignableScopesMustIncludeScope"
  end

  test "DELETE of a definition referenced by a role assignment answers 400 RoleDefinitionInUse and the definition survives" do
    body = def_body("in-use-role", @base)

    put = arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/in-use-def", body)
    assert put.status == 201

    ra_body = %{
      "properties" => %{
        "roleDefinitionId" =>
          "#{@base}/providers/Microsoft.Authorization/roleDefinitions/in-use-def",
        "principalId" => "00000000-0000-0000-0000-000000000001"
      }
    }

    ra = arm_req(:put, "#{@base}/providers/Microsoft.Authorization/roleAssignments/ra-1", ra_body)
    assert ra.status == 201

    del = arm_req(:delete, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/in-use-def")
    assert del.status == 400
    assert Jason.decode!(del.resp_body)["error"]["code"] == "RoleDefinitionInUse"

    survivor = arm_req(:get, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/in-use-def")
    assert survivor.status == 200
  end

  test "DELETE of an absent definition answers 404" do
    conn = arm_req(:delete, "#{@base}/providers/Microsoft.Authorization/roleDefinitions/nope-def")
    assert conn.status == 404
  end
end
