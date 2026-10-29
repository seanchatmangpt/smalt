# CONVERGENCE lane V4 (retry, narrowed) — KQL `where` at the ResourceGraph route.
#
# Interim finding from the prior attempt: the KQL evaluator already supports
# `where` fully (data_plane resource_graph.ex); the reported 400 on
# where-queries does NOT originate at the clause gate — the gate's whitelist
# (@supported_clauses) already carries `where` (arm_gateway/resource_graph.ex:34),
# and this court witnesses where-queries answering through the REAL route
# (Smalt.ArmGateway.Router in-process dispatch, real Store rows, real evaluator).
#
# Chicago discipline: real router, real Store, real evaluator — no mocks.
#
# Legs:
#   1. where == filter — a where clause filters the real seeded rows.
#   2. where + project composed — filtered AND column-projected.
#   3. unknown clause still 400 — the strict law survives the where admission:
#      an unsupported clause composed WITH a where stage still answers the
#      typed 400 UnsupportedClause.
defmodule SmaltTest.Integration.KqlWhereRouteTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Store

  @sub "00000000-0000-0000-0000-0000000000v4"
  @rg "rg-v4-where"
  @av "2022-10-01"

  setup do
    resources = [
      %{
        "id" => res_id("storagetype", "disk-v4a"),
        "name" => "disk-v4a",
        "type" => "Microsoft.Compute/disks",
        "location" => "westus",
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{}
      },
      %{
        "id" => res_id("storagetype", "sa-v4"),
        "name" => "sa-v4",
        "type" => "Microsoft.Storage/storageAccounts",
        "location" => "eastus",
        "properties" => %{"provisioningState" => "Succeeded"},
        "tags" => %{}
      }
    ]

    Enum.each(resources, fn r -> Store.put(:smalt_resources, r["id"], r) end)

    on_exit(fn ->
      Enum.each(resources, fn r -> Store.delete(:smalt_resources, r["id"]) end)
    end)

    {:ok, resources: resources}
  end

  defp res_id(kind, name) do
    String.downcase(
      "/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.storage/#{kind}/#{name}"
    )
  end

  defp dispatch(query, api_version \\ @av) do
    path = "/providers/Microsoft.ResourceGraph/resources?api-version=#{api_version}"

    conn(:post, path, Jason.encode!(%{"query" => query, "subscriptions" => [@sub]}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call([])
  end

  # Leg 1: where == filter.
  test "where clause filters real rows through the route" do
    conn = dispatch("Resources | where name == \"disk-v4a\"")

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert %{"count" => 1, "data" => [%{"name" => "disk-v4a"}]} = body
  end

  # Leg 2: where + project composed.
  test "where + project composes: filtered rows AND projected columns" do
    conn = dispatch("Resources | where type =~ 'microsoft.storage/storageaccounts' | project name, location")

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert body["count"] == 1

    assert [%{"name" => "sa-v4", "location" => "eastus"}] = body["data"]

    # projected columns only, plus the always-carried row identity (V20b:
    # real ResourceGraph rows never drop the ARM id).
    assert Enum.all?(body["data"], fn row ->
             Map.keys(row) |> Enum.sort() == ["id", "location", "name"]
           end)
  end

  # Leg 3: the strict law survives — unknown clause WITH where still 400s typed.
  test "unknown clause composed with where still answers typed 400 UnsupportedClause" do
    conn = dispatch("Resources | where type =~ 'microsoft.storage/storageaccounts' | mv-expand x | project name")

    assert conn.status == 400

    body = Jason.decode!(conn.resp_body)

    assert body["error"]["code"] == "UnsupportedClause"
    assert body["error"]["message"] =~ "mv-expand"
  end
end
