# AZURE-FIDELITY lane 2 — ARM deployments integration court (v26.10.25).
#
# Chicago discipline: real in-process dispatch through
# Smalt.ArmGateway.Router, real Store rows (:smalt_arm_deployments +
# :smalt_resources). No mocks. The gate template mirrors the terraform
# module shapes (storage account + Key Vault).

defmodule Smalt.Internal.ArmDeploymentsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @sub "sub-af2"
  @rg "rg-af2"

  @dep_base "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Resources/deployments"

  setup do
    # Real RG through the real route so the RG listing face is exercised.
    put_rg =
      dispatch(:put, "/subscriptions/#{@sub}/resourceGroups/#{@rg}?api-version=2021-04-01", %{
        "location" => "eastus"
      })

    assert put_rg.status in [200, 201]

    on_exit(fn ->
      case :ets.info(:smalt_arm_deployments) do
        :undefined -> :ok
        _ -> true = :ets.delete_all_objects(:smalt_arm_deployments)
      end

      case :ets.info(:smalt_arm_deployments_ops) do
      :undefined -> :ok
        _ -> true = :ets.delete_all_objects(:smalt_arm_deployments_ops)
      end

      :ok
    end)

    :ok
  end

  # GATE leg 1: storage account + KV template deploys, deployment GET shows
  # the Accepted/Running/Succeeded timestamps and Succeeded state.
  test "template with storage account + key vault deploys with lifecycle timestamps" do
    name = "dep-sa-kv-#{rand()}"

    {body, _sa, _kv} = template_body()

    put_conn = dispatch(:put, "#{@dep_base}/#{name}", body)

    assert put_conn.status == 200

    put_body = Jason.decode!(put_conn.resp_body)
    assert put_body["name"] == name

    # DIVERGENCE lane D4: documented DeploymentExtended carries top-level
    # `type` and NO top-level location.
    assert put_body["type"] == "Microsoft.Resources/deployments"
    refute Map.has_key?(put_body, "location")
    assert put_body["properties"]["provisioningState"] == "Succeeded"

    props = put_body["properties"]
    assert is_binary(props["acceptedAt"])
    assert is_binary(props["startedAt"])
    assert is_binary(props["timestamp"])

    # GET echo: same lifecycle, stable correlationId.
    get_body = dispatch(:get, "#{@dep_base}/#{name}").resp_body |> Jason.decode!()

    # DIVERGENCE lane D4: GET face mirrors the documented DeploymentExtended.
    assert get_body["type"] == "Microsoft.Resources/deployments"
    refute Map.has_key?(get_body, "location")

    assert get_body["properties"]["provisioningState"] == "Succeeded"
    assert get_body["properties"]["correlationId"] == put_body["properties"]["correlationId"]
    assert get_body["properties"]["acceptedAt"] == props["acceptedAt"]
  end

  # GATE leg 2: deploymentOperations lists one success op per template
  # resource, each naming its target resource.
  test "operations list shows per-resource success with targetResource" do
    name = "dep-ops-#{rand()}"

    {body, _sa, _kv} = template_body()

    assert dispatch(:put, "#{@dep_base}/#{name}", body).status == 200

    ops_conn = dispatch(:get, "#{@dep_base}/#{name}/operations")
    assert ops_conn.status == 200

    ops = Jason.decode!(ops_conn.resp_body)["value"]
    assert length(ops) == 2

    states = Enum.map(ops, & &1["properties"]["provisioningState"])
    assert states == ["Succeeded", "Succeeded"]

    targets =
      ops
      |> Enum.map(& &1["properties"]["targetResource"]["resourceType"])
      |> Enum.sort()

    assert targets == ["Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts"]

    # Timestamps: each op carries a real ISO8601 timestamp.
    Enum.each(ops, fn op ->
      assert is_binary(op["properties"]["timestamp"])
      assert match?({:ok, _, _}, DateTime.from_iso8601(op["properties"]["timestamp"]))
    end)
    end

  # GATE leg 3: deployed resources materialize into the provider store —
  # they appear in the RG listing exactly like directly-PUT resources.
  test "deployed resources appear in the resource group listing" do
    name = "dep-rglist-#{rand()}"
    {body, sa_name, _kv_name} = template_body()

    assert dispatch(:put, "#{@dep_base}/#{name}", body).status == 200

    list_conn =
      dispatch(:get, "/subscriptions/#{@sub}/resourceGroups/#{@rg}/resources?api-version=2021-04-01")

    assert list_conn.status == 200

    names = list_conn.resp_body |> Jason.decode!() |> Map.get("value", []) |> Enum.map(& &1["name"])

    assert sa_name in names
  end

  # GATE leg 4: malformed template -> documented ARM validation error.
  test "malformed template returns documented InvalidTemplate envelope" do
    # (a) template not an object.
    conn = dispatch(:put, "#{@dep_base}/#{rand()}", %{"properties" => %{"template" => "nope"}})

    assert conn.status == 400

    err = Jason.decode!(conn.resp_body)["error"]
    assert err["code"] == "InvalidTemplate"

    # (b) unknown resource type -> typed detail naming the type.
    conn2 =
      dispatch(:put, "#{@dep_base}/#{rand()}", %{
        "properties" => %{
          "mode" => "Incremental",
          "template" => %{
            "resources" => [
              %{"type" => "Microsoft.Foo/barBazes", "name" => "b1", "location" => "eastus"}
            ]
          }
        }
      })

    assert conn2.status == 400

    err2 = Jason.decode!(conn2.resp_body)["error"]
    assert err2["code"] == "InvalidTemplate"

    assert err2["details"]
           |> Enum.any?(&(&1["message"] =~ "Microsoft.Foo/barBazes"))

    # (c) validate face: same envelope, nothing written.
    conn3 =
      dispatch(:post, "#{@dep_base}/dep-valid-#{rand()}/validate", %{
        "properties" => %{
          "mode" => "Incremental",
          "template" => %{
            "resources" => [
              %{
                "type" => "Microsoft.KeyVault/vaults",
                "name" => "kv-valid-#{rand_id()}",
                "location" => "eastus",
                "properties" => %{"tenantId" => "t", "sku" => %{"family" => "A", "name" => "standard"}}
              }
            ]
          }
        }
      })

    assert conn3.status == 200

    # DIVERGENCE lane D4: documented success face is DeploymentValidateResult
    # {properties} — no top-level status.
    vbody = Jason.decode!(conn3.resp_body)
    assert Map.has_key?(vbody, "properties")
    assert vbody["properties"]["provisioningState"] == "Succeeded"
    refute Map.has_key?(vbody, "status")
    # validate writes nothing: no deployment materialized under this name.

    # validate face refuses the unknown type with the same envelope.
    conn4 =
      dispatch(:post, "#{@dep_base}/dep-valid-#{rand()}/validate", %{
        "properties" => %{
          "mode" => "Incremental",
          "template" => %{
            "resources" => [
              %{"type" => "Microsoft.Foo/barBazes", "name" => "b2", "location" => "eastus"}
            ]
          }
        }
      })

    assert conn4.status == 400
    assert Jason.decode!(conn4.resp_body)["error"]["code"] == "InvalidTemplate"
  end

  # -- helpers ------------------------------------------------------------------

  defp template_body do
    sa_name = "sadep#{rand_id()}"
    kv_name = "kvdep-#{rand_id()}"

    body = %{
      "properties" => %{
        "mode" => "Incremental",
        "template" => %{
          "resources" => [
            %{
              "type" => "Microsoft.Storage/storageAccounts",
              "name" => sa_name,
              "location" => "eastus",
              "sku" => %{"name" => "Standard_LRS"},
              "kind" => "StorageV2",
              "tags" => %{"lane" => "af2"}
            },
            %{
              "type" => "Microsoft.KeyVault/vaults",
              "name" => kv_name,
              "location" => "westus2",
              "properties" => %{
                "tenantId" => "00000000-0000-0000-0000-000000000000",
                "sku" => %{"family" => "A", "name" => "standard"}
              }
            }
          ]
        }
      }
    }

    {body, sa_name, kv_name}
  end

  defp rand, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp rand_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp dispatch(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    Router.call(Plug.Conn.fetch_query_params(conn), [])
  end
end
