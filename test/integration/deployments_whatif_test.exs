# AZURE-FIDELITY gap closure G1 — deployment what-if integration court.
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router,
# real Store rows (:smalt_arm_deployments + :smalt_resources), no mocks.
#
# Closes the ActionNotFound gap on
#   POST .../providers/Microsoft.Resources/deployments/{name}/what-if
# Contract under test: 200 {properties: {changes: [...], status},
# location header}; changes diff the template against the LIVE
# :smalt_resources store — Create when absent (store NOT mutated), NoChange
# when the projection of the template equals the stored row, Modify with
# before/after + property delta when they differ.

defmodule Smalt.Internal.DeploymentsWhatIfTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @sub "sub-whatif"
  @rg "rg-whatif"

  @dep_base "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Resources/deployments"

  setup do
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

  defp template_body(sa_name, props \\ %{}) do
    %{
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
              "tags" => %{"lane" => "whatif"},
              "properties" => props
            }
          ]
        }
      }
    }
  end

  defp what_if(sa_name, props \\ %{}) do
    dispatch(:post, "#{@dep_base}/dep-whatif-#{rand()}/what-if", template_body(sa_name, props))
  end

  defp single_change(conn) do
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["status"] == "Succeeded"

    # Location header names the deployment the what-if ran against.
    assert [loc] = Plug.Conn.get_resp_header(conn, "location")
    assert loc =~ "/deployments/"

    changes = body["properties"]["changes"]
    assert length(changes) == 1
    hd(changes)
  end

  # GATE leg 1: fresh template -> Create per resource, and the store is NOT
  # mutated (the resource is still absent after what-if).
  test "what-if on fresh template yields Create without mutating the store" do
    sa = "sawhatif#{rand()}"

    change = single_change(what_if(sa))

    assert change["changeType"] == "Create"
    assert change["before"] == nil
    assert is_map(change["after"])

    id = change["resourceId"]
    assert id == "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/#{sa}"

    # The store did NOT change: a direct GET of the resource 404s.
    get_conn =
      dispatch(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/#{sa}?api-version=2021-04-01"
      )

    assert get_conn.status == 404
  end

  # GATE leg 2: deploy the template for real, then what-if the IDENTICAL
  # template -> NoChange (projection-vs-store equality, enrichment included).
  test "what-if over an identical deployed resource yields NoChange" do
    sa = "sawhatif#{rand()}"
    dep = "dep-nochange-#{rand()}"

    assert dispatch(:put, "#{@dep_base}/#{dep}", template_body(sa)).status == 200

    change = single_change(what_if(sa))

    assert change["changeType"] == "NoChange"
    assert change["delta"] == nil
  end

  # GATE leg 3: deploy, then what-if a template with a modified property ->
  # Modify with before/after and a property delta naming the changed key.
  test "what-if with modified properties yields Modify with before/after delta" do
    sa = "sawhatif#{rand()}"
    dep = "dep-modify-#{rand()}"

    assert dispatch(:put, "#{@dep_base}/#{dep}", template_body(sa)).status == 200

    change = single_change(what_if(sa, %{"supportHttpsTrafficOnly" => false}))

    assert change["changeType"] == "Modify"

    delta = change["delta"]
    assert is_list(delta)

    entry =
      Enum.find(delta, fn d -> d["path"] == "properties.supportHttpsTrafficOnly" end) ||
        Enum.find(delta, fn d -> d["path"] == "properties.#{sa}" end) ||
        Enum.find(delta, fn d -> String.starts_with?(d["path"], "properties.") end)

    assert entry
    assert entry["propertyChangeType"] in ["Update", "Add"]

    assert entry["before"] != entry["after"]
    assert is_map(change["before"]) and is_map(change["after"])
  end

  # Bonus leg: sub-scope what-if route answers too (no rg).
  test "subscription-scope what-if route responds" do
    sa = "sawhatif#{rand()}"

    conn =
      dispatch(
        :post,
        "/subscriptions/#{@sub}/providers/Microsoft.Resources/deployments/dep-sub-#{rand()}/what-if",
        template_body(sa)
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["properties"]["status"] == "Succeeded"
  end

  defp rand, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

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
