# L35 court (KD-188): ARM storage account managementPolicies child route.
#
# Chicago discipline: real dispatch through Smalt.ArmGateway.Router (the
# 9443 ARM mux face, all plugs live), real Store rows (:smalt_resources,
# downcased resource-id keys), no mocks, no network. The route claim, the
# api-version gate, the singleton-name law, the parent-account 404
# StorageAccountNotFound semantics and the synchronous DELETE 200 are
# pinned over real request -> response pairs.
#
# KD-COVERS: KD-188
#
# Context: solo (integration tier, in-process dispatch).
defmodule Smalt.Internal.StorageManagementPoliciesTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @sub "sub-l35"
  @rg "rg-l35"
  @base "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts"

  @av "api-version=2022-09-01"

  @policy_body %{
    "properties" => %{
      "policy" => %{
        "rules" => [
          %{
            "enabled" => true,
            "name" => "lifecycle-rule",
            "type" => "Lifecycle",
            "definition" => %{
              "actions" => %{
                "baseBlob" => %{"delete" => %{"daysAfterModificationGreaterThan" => 30}}
              },
              "filters" => %{"blobTypes" => ["blockBlob"]}
            }
          }
        ]
      }
    }
  }

  # -- harness -------------------------------------------------------------------

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp acct_name, do: "acl35" <> unique()

  defp account_id(acct) do
    String.downcase("#{@base}/#{acct}")
  end

  defp policy_base(acct), do: "#{@base}/#{acct}/managementPolicies"

  defp seed_account(acct) do
    :ok =
      Smalt.Store.put(:smalt_resources, account_id(acct), %{
        "id" => account_id(acct),
        "name" => acct,
        "type" => "Microsoft.Storage/storageAccounts",
        "location" => "eastus",
        "properties" => %{"provisioningState" => "Succeeded"}
      })

    :ok
  end

  defp dispatch(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(conn, [])
  end

  # -- the court -----------------------------------------------------------------

  test "PUT default creates (201), re-PUT idempotent (200), GET echoes the stored policy" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:put, "#{policy_base(acct)}/default?#{@av}", @policy_body)
    assert conn.status == 201

    body = Jason.decode!(conn.resp_body)
    assert String.downcase(body["id"]) == String.downcase("#{policy_base(acct)}/default")
    assert body["name"] == "default"
    assert body["type"] == "Microsoft.Storage/storageAccounts/managementPolicies"
    assert body["properties"]["provisioningState"] == "Succeeded"
    assert length(body["properties"]["policy"]["rules"]) == 1

    conn2 = dispatch(:put, "#{policy_base(acct)}/default?#{@av}", @policy_body)
    assert conn2.status == 200

    conn3 = dispatch(:get, "#{policy_base(acct)}/default?#{@av}")
    assert conn3.status == 200

    body3 = Jason.decode!(conn3.resp_body)

    assert get_in(body3, ["properties", "policy", "rules", Access.at(0), "definition", "actions", "baseBlob", "delete", "daysAfterModificationGreaterThan"]) == 30
  end

  test "non-default name refused typed 400 ManagementPolicyNameInvalid" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:put, "#{policy_base(acct)}/not-default?#{@av}", @policy_body)
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ManagementPolicyNameInvalid"
  end

  test "PUT without a map properties member refused typed 400 InvalidRequestContent" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:put, "#{policy_base(acct)}/default?#{@av}", %{"policy" => %{"rules" => []}})
    assert conn.status == 400

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "InvalidRequestContent"
  end

  test "missing parent account answers typed 404 StorageAccountNotFound on PUT/GET" do
    acct = acct_name()

    put_conn = dispatch(:put, "#{policy_base(acct)}/default?#{@av}", @policy_body)
    assert put_conn.status == 404

    assert Jason.decode!(put_conn.resp_body)["error"]["code"] == "StorageAccountNotFound"

    get_conn = dispatch(:get, "#{policy_base(acct)}/default?#{@av}")
    assert get_conn.status == 404

    assert Jason.decode!(get_conn.resp_body)["error"]["code"] == "StorageAccountNotFound"
  end

  test "GET of a never-PUT policy on an existing account answers 404 ResourceNotFound" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:get, "#{policy_base(acct)}/default?#{@av}")
    assert conn.status == 404

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  test "DELETE answers synchronous 200; later GET 404s; DELETE of absent policy 404s" do
    acct = acct_name()
    seed_account(acct)

    assert dispatch(:put, "#{policy_base(acct)}/default?#{@av}", @policy_body).status == 201

    assert dispatch(:delete, "#{policy_base(acct)}/default?#{@av}").status == 200

    assert dispatch(:get, "#{policy_base(acct)}/default?#{@av}").status == 404

    conn = dispatch(:delete, "#{policy_base(acct)}/default?#{@av}")
    assert conn.status == 404

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "ResourceNotFound"
  end

  test "PATCH answers the typed 405 MethodNotAllowed (real Azure has no PATCH face)" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:patch, "#{policy_base(acct)}/default?#{@av}", @policy_body)
    assert conn.status == 405

    assert Jason.decode!(conn.resp_body)["error"]["code"] == "MethodNotAllowed"
  end

  test "api-version law: missing -> 400 MissingApiVersionParameter; future -> 400 InvalidApiVersionParameter; past admitted (KD-78)" do
    acct = acct_name()
    seed_account(acct)

    missing = dispatch(:get, "#{policy_base(acct)}/default")
    assert missing.status == 400

    assert Jason.decode!(missing.resp_body)["error"]["code"] == "MissingApiVersionParameter"

    future = dispatch(:get, "#{policy_base(acct)}/default?api-version=2099-01-01")
    assert future.status == 400

    assert Jason.decode!(future.resp_body)["error"]["code"] == "InvalidApiVersionParameter"

    past = dispatch(:get, "#{policy_base(acct)}/default?api-version=2021-04-01")
    assert past.status in [200, 404]
  end

  test "the pre-KD-188 divergence face is retired: the route no longer 404s RouteNotFound" do
    acct = acct_name()
    seed_account(acct)

    conn = dispatch(:put, "#{policy_base(acct)}/default?#{@av}", @policy_body)

    refute conn.status == 404 and Jason.decode!(conn.resp_body)["error"]["code"] == "RouteNotFound"
    assert conn.status == 201
  end
end
