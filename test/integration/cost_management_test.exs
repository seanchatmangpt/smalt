# Integration-tier court: ARM Cost Management query + Consumption usageDetails
# (AZURE-FIDELITY lane 6).
#
# Chicago discipline: real in-process dispatch through
# Smalt.ArmGateway.Router over the real :smalt_cost_usage ETS event store.
# No mocks. The reconciliation court (Σ usage-details cost == ActualCost
# total, same window) reads both surfaces over the same seeded rows.

defmodule Smalt.Internal.CostManagementTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.CostManagement
  alias Smalt.ArmGateway.Router

  @sub "sub-cost-6"
  @ok 200
  @bad_request 400

  setup do
    CostManagement.reset(@sub)
    on_exit(fn -> CostManagement.reset(@sub) end)
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

    Router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp query_path, do: "/subscriptions/#{@sub}/providers/Microsoft.CostManagement/query"
  defp usage_path, do: "/subscriptions/#{@sub}/providers/Microsoft.Consumption/usageDetails"

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # -- Documented response shape + columns -----------------------------------

  test "seeded window: query returns documented envelope, columns, rows" do
    CostManagement.seed_events(@sub, [
      %{
        date: ~D[2026-10-20],
        service_name: "Virtual Machines",
        quantity: 8.0,
        cost: 0.32,
        tags: %{"env" => "court"}
      },
      %{
        date: ~D[2026-10-21],
        service_name: "Storage",
        quantity: 3.5,
        cost: 0.09
      }
    ])

    conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => %{"from" => "2026-10-01", "to" => "2026-10-31"}
      })

    assert conn.status == @ok

    body = decode(conn)

    assert body["type"] == "Microsoft.CostManagement/QueryResults"
    assert is_binary(body["id"]) and is_binary(body["name"])

    cols = body["properties"]["columns"]
    names = Enum.map(cols, & &1["name"])

    for documented <- ["Cost", "Currency", "UsageDateTime", "ChargeType", "ResourceId", "ServiceName"] do
      assert documented in names
    end

    assert Enum.all?(cols, &is_binary(&1["type"]))

    rows = body["properties"]["rows"]
    assert length(rows) == 2

    costs = Enum.map(rows, &Enum.at(&1, 0))
    assert_in_delta Enum.sum(costs), 0.41, 1.0e-9

    service_idx = Enum.find_index(names, &(&1 == "ServiceName"))
    assert Enum.map(rows, &Enum.at(&1, service_idx)) |> Enum.sort() == ["Storage", "Virtual Machines"]
  end

  # -- Time filtering ----------------------------------------------------------

  test "timePeriod filters: out-of-window events are excluded" do
    CostManagement.seed_events(@sub, [
      %{date: ~D[2026-10-20], service_name: "In", quantity: 1, cost: 1.5},
      %{date: ~D[2026-09-30], service_name: "Early", quantity: 1, cost: 99.0},
      %{date: ~D[2026-11-01], service_name: "Late", quantity: 1, cost: 88.0}
    ])

    conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => %{"from" => "2026-10-01", "to" => "2026-10-31"}
      })

    rows = decode(conn)["properties"]["rows"]

    assert length(rows) == 1
    assert_in_delta Enum.sum(Enum.map(rows, &Enum.at(&1, 0))), 1.5, 1.0e-9
  end

  test "timeframe MonthToDate resolves a real window" do
    today = Date.utc_today()

    CostManagement.seed_events(@sub, [
      %{date: today, service_name: "Today", quantity: 1, cost: 0.7}
    ])

    conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timeframe" => "MonthToDate"
      })

    assert conn.status == @ok

    rows = decode(conn)["properties"]["rows"]

    assert length(rows) == 1
    assert_in_delta Enum.sum(Enum.map(rows, &Enum.at(&1, 0))), 0.7, 1.0e-9
  end

  # -- Reconciliation court ----------------------------------------------------

  test "reconciliation: sum(usageDetails cost) == ActualCost total, same window" do
    today = Date.utc_today()
    y = Date.add(today, -1)

    CostManagement.seed_events(@sub, [
      %{date: today, service_name: "Virtual Machines", quantity: 2.0, cost: 0.08},
      %{date: y, service_name: "Storage", quantity: 5.0, cost: 0.11},
      %{date: y, service_name: "Virtual Machines", quantity: 3.0, cost: 0.12},
      # Out of window — must be excluded on BOTH surfaces.
      %{date: Date.add(today, -40), service_name: "Old", quantity: 9.0, cost: 500.0}
    ])

    window = %{"from" => Date.to_iso8601(Date.add(today, -7)), "to" => Date.to_iso8601(today)}

    query_conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => window
      })

    filter =
      "$filter=properties/usageStart ge '#{window["from"]}' and properties/usageEnd le '#{window["to"]}'"

    usage_conn =
      dispatch(:get, usage_path() <> "?api-version=2023-05-01&" <> URI.encode_query(%{"$filter" => filter}))

    assert query_conn.status == @ok
    assert usage_conn.status == @ok

    query_total =
      decode(query_conn)["properties"]["rows"] |> Enum.map(&Enum.at(&1, 0)) |> Enum.sum()

    usage_rows = decode(usage_conn)["value"]
    assert length(usage_rows) == 3

    usage_total =
      usage_rows
      |> Enum.map(& &1["properties"]["cost"])
      |> Enum.sum()

    assert_in_delta query_total, usage_total, 1.0e-9
    assert_in_delta usage_total, 0.31, 1.0e-9
  end

  # -- Empty window: documented empty shape ------------------------------------

  test "empty window: documented empty shape (columns present, rows [])" do
    CostManagement.seed_events(@sub, [
      %{date: ~D[2020-01-01], service_name: "Ancient", quantity: 1, cost: 1.0}
    ])

    conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => %{"from" => "2026-10-01", "to" => "2026-10-31"}
      })

    assert conn.status == @ok

    body = decode(conn)

    assert body["properties"]["rows"] == []
    assert length(body["properties"]["columns"]) == 6
  end

  # -- Typed refusals + usage-details filtering --------------------------------

  test "unsupported type and missing window are typed 400s" do
    conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "AmortizedCost",
        "timeframe" => "MonthToDate"
      })

    assert conn.status == @bad_request
    assert decode(conn)["error"]["code"] == "InvalidRequest"

    conn = dispatch(:post, query_path() <> "?api-version=2023-03-01", %{"type" => "ActualCost"})
    assert conn.status == @bad_request
  end

  test "usageDetails: documented columns, startDate/endDate filtering" do
    CostManagement.seed_events(@sub, [
      %{
        date: ~D[2026-10-20],
        service_name: "Virtual Machines",
        quantity: 4.0,
        cost: 0.16,
        tags: %{"lane" => "cost6"}
      },
      %{date: ~D[2026-10-25], service_name: "Storage", quantity: 1.0, cost: 0.02}
    ])

    conn =
      dispatch(
        :get,
        usage_path() <>
          "?api-version=2023-05-01&startDate=2026-10-20&endDate=2026-10-22"
      )

    assert conn.status == @ok

    rows = decode(conn)["value"]
    assert length(rows) == 1

    props = hd(rows)["properties"]

    for col <- ["date", "serviceName", "quantity", "cost", "tags"] do
      assert Map.has_key?(props, col)
    end

    assert props["date"] == "2026-10-20"
    assert props["serviceName"] == "Virtual Machines"
    assert props["quantity"] == 4.0
    assert_in_delta props["cost"], 0.16, 1.0e-9
    assert props["tags"] == %{"lane" => "cost6"}
  end

  test "missing api-version is a typed 400 on both surfaces" do
    assert dispatch(:post, query_path(), %{"type" => "ActualCost", "timeframe" => "MonthToDate"}).status ==
             @bad_request

    assert dispatch(:get, usage_path()).status == @bad_request
  end
end
