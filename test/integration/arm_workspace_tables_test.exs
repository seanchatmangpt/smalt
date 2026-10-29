# Integration-tier witness: LA workspace-tables ARM family (v26.10.19 w5 lane).
#
# Chicago discipline: real Store rows, real in-process dispatch through
# Smalt.ArmGateway.Router (workspace-tables family), real ingest through the
# real EgressRouter -> Sentinel.ingest/4 path. No mocks. Table stats come from
# Sentinel.table_stats/1 (landed wave-3) over the DCR whose name is the
# workspace name (workspace<->DCR binding documented at the family head in
# arm_gateway/router.ex).

defmodule Smalt.Internal.ArmWorkspaceTablesTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @la_version "2020-08-01"
  @rg "/subscriptions/sub-wst/resourceGroups/rg-wst"
  @ws_type "Microsoft.OperationalInsights/workspaces"
  @dcr_type "Microsoft.Insights/dataCollectionRules"

  @ok 200
  @created 201
  @not_found 404

  # -- helpers ------------------------------------------------------------------

  defp dispatch(router, method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  test "b11 enforce witness: DCR(=ws) 2 streams -> ingest -> GET tables -> 2 rows w/ counts; GET single -> 200" do
    ws = "ws-tables-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    base = "#{@rg}/providers/#{@ws_type}/#{ws}"

    # Real workspace resource via the admitted generic PUT route.
    assert dispatch(Router, :put, "#{base}?api-version=#{@la_version}", %{
             "location" => "eastus"
           }).status == @created

    # Real DCR named as the workspace (workspace<->DCR binding), 2 streams via
    # real EgressRouter ingest (implicit-create posture, default boot).
    for stream <- ["Custom-LogsA", "Custom-LogsB"] do
      conn =
        dispatch(Smalt.EgressRouter, :post, "/dataCollectionRules/#{ws}/streams/#{stream}?api-version=2023-01-01", [
          %{"TimeGenerated" => "2026-10-20T10:00:00Z", "v" => 1},
          %{"TimeGenerated" => "2026-10-20T11:00:00Z", "v" => 2}
        ])

      assert conn.status == 204
    end

    # GET tables: 2 rows, counts matching ingest.
    list_conn = dispatch(Router, :get, "#{base}/tables?api-version=#{@la_version}")

    assert list_conn.status == @ok

    rows =
      list_conn.resp_body
      |> Jason.decode!()
      |> Map.get("value")

    assert length(rows) == 2

    by_name = Map.new(rows, &{&1["name"], &1})

    for stream <- ["Custom-LogsA", "Custom-LogsB"] do
      row = Map.fetch!(by_name, stream)
      assert row["properties"]["totalRecords"] == 2
      assert row["properties"]["oldestTimeGenerated"] == "2026-10-20T10:00:00Z"
      assert row["properties"]["newestTimeGenerated"] == "2026-10-20T11:00:00Z"
    end
  end

  test "GET single table -> 200 with stats; unknown table -> 404 TableNotFound; unknown workspace -> 404 ResourceNotFound" do
    ws = "ws-single-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    base = "#{@rg}/providers/#{@ws_type}/#{ws}"

    assert dispatch(Router, :put, "#{base}?api-version=#{@la_version}", %{
             "location" => "eastus"
           }).status == @created

    assert dispatch(Smalt.EgressRouter, :post, "/dataCollectionRules/#{ws}/streams/Custom-Solo?api-version=2023-01-01", [
             %{"TimeGenerated" => "2026-10-20T09:30:00Z", "v" => 1}
           ]).status == 204

    single =
      dispatch(Router, :get, "#{base}/tables/Custom-Solo?api-version=#{@la_version}")

    assert single.status == @ok

    body = Jason.decode!(single.resp_body)

    assert body["name"] == "Custom-Solo"
    assert body["properties"]["totalRecords"] == 1
    assert body["properties"]["oldestTimeGenerated"] == "2026-10-20T09:30:00Z"
    assert body["properties"]["newestTimeGenerated"] == "2026-10-20T09:30:00Z"
    assert body["properties"]["retentionInDays"] == 730

    missing_table =
      dispatch(Router, :get, "#{base}/tables/NoSuchTable?api-version=#{@la_version}")

    assert missing_table.status == @not_found
    assert Jason.decode!(missing_table.resp_body)["error"]["code"] == "TableNotFound"

    missing_ws =
      dispatch(Router, :get, "#{@rg}/providers/#{@ws_type}/ws-never/tables?api-version=#{@la_version}")

    assert missing_ws.status == @not_found
    assert Jason.decode!(missing_ws.resp_body)["error"]["code"] == "ResourceNotFound"
  end
end
