# Integration-tier court: ARM Cost Management forecast (CONVERGENCE lane V11).
#
# Chicago discipline: real in-process dispatch through Smalt.ArmGateway.Router
# over the real :smalt_cost_usage ETS event store. No mocks. The forecast
# surface reads the same seeded rows the query surface reads, so unit
# consistency (actual forecast rows == query rows for the same window) holds
# by construction and is asserted on real dispatch, not stubbed calls.

defmodule Smalt.Internal.CostForecastTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.CostManagement
  alias Smalt.ArmGateway.Router

  @sub "sub-cost-forecast-11"
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

  defp forecast_path, do: "/subscriptions/#{@sub}/providers/Microsoft.CostManagement/forecast"
  defp query_path, do: "/subscriptions/#{@sub}/providers/Microsoft.CostManagement/query"

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # -- Documented response shape + Forecast column -----------------------------

  test "seeded window: forecast returns documented envelope with Forecast column" do
    today = Date.utc_today()

    CostManagement.seed_events(@sub, [
      %{date: today, service_name: "Virtual Machines", quantity: 24.0, cost: 0.96},
      %{date: today, service_name: "Storage", quantity: 12.5, cost: 0.29}
    ])

    conn =
      dispatch(:post, forecast_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => %{"from" => Date.to_iso8601(today), "to" => Date.to_iso8601(today)}
      })

    assert conn.status == @ok

    body = decode(conn)

    assert body["type"] == "Microsoft.CostManagement/ForecastResults"
    assert is_binary(body["id"]) and is_binary(body["name"])
    assert String.contains?(body["id"], "/Microsoft.CostManagement/forecastResults/")

    cols = body["properties"]["columns"]
    names = Enum.map(cols, & &1["name"])

    # Unit consistency with the query surface: the documented ActualCost
    # column subset appears in the forecast column list, plus the documented
    # Forecast column.
    for documented <- ["Cost", "Currency", "UsageDateTime", "ChargeType", "ResourceId", "ServiceName"] do
      assert documented in names
    end

    assert "Forecast" in names
    assert Enum.all?(cols, &is_binary(&1["type"]))

    rows = body["properties"]["rows"]
    assert length(rows) == 2

    forecast_idx = Enum.find_index(names, &(&1 == "Forecast"))
    assert Enum.map(rows, &Enum.at(&1, forecast_idx)) |> Enum.uniq() == ["actual"]
  end

  test "forecast rows extend the usage window (actual + projected dates)" do
    today = Date.utc_today()

    CostManagement.seed_events(@sub, [
      # Trailing history (before the forecast window start): drives the
      # per-service projected daily rate.
      %{date: Date.add(today, -2), service_name: "Virtual Machines", quantity: 24.0, cost: 0.48},
      # In-window actuals.
      %{date: Date.add(today, -1), service_name: "Virtual Machines", quantity: 24.0, cost: 0.96},
      %{date: today, service_name: "Virtual Machines", quantity: 24.0, cost: 0.96}
    ])

    conn =
      dispatch(:post, forecast_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => %{
          "from" => Date.to_iso8601(Date.add(today, -1)),
          "to" => Date.to_iso8601(Date.add(today, 2))
        }
      })

    assert conn.status == @ok

    body = decode(conn)
    names = Enum.map(body["properties"]["columns"], & &1["name"])
    usage_idx = Enum.find_index(names, &(&1 == "UsageDateTime"))
    forecast_idx = Enum.find_index(names, &(&1 == "Forecast"))
    cost_idx = Enum.find_index(names, &(&1 == "Cost"))

    rows = body["properties"]["rows"]

    # Two dates with events -> actual rows; two empty dates -> projected rows.
    {actuals, projected} = Enum.split_with(rows, &(Enum.at(&1, forecast_idx) == "actual"))
    assert length(actuals) == 2
    assert length(projected) == 2

    # Actual rows match the seeded events exactly (unit consistency with query).
    actual_dates = Enum.map(actuals, &Enum.at(&1, usage_idx)) |> Enum.sort()

    assert actual_dates == [Date.to_iso8601(Date.add(today, -1)), Date.to_iso8601(today)]

    assert_in_delta Enum.sum(Enum.map(actuals, &Enum.at(&1, cost_idx))), 1.92, 1.0e-9

    # Projected dates are strictly beyond the usage window and deterministic:
    # trailing 7-day VM average = 0.48 / 7.
    projected_dates = Enum.map(projected, &Enum.at(&1, usage_idx)) |> Enum.sort()

    assert projected_dates ==
             [Date.to_iso8601(Date.add(today, 1)), Date.to_iso8601(Date.add(today, 2))]

    for row <- projected do
      assert_in_delta Enum.at(row, cost_idx), 0.48 / 7, 1.0e-9
    end
  end

  test "unit consistency: query total == sum of actual forecast rows, same window" do
    today = Date.utc_today()

    CostManagement.seed_events(@sub, [
      %{date: today, service_name: "Virtual Machines", quantity: 2.0, cost: 0.08},
      %{date: today, service_name: "Storage", quantity: 5.0, cost: 0.11},
      %{date: Date.add(today, -1), service_name: "Storage", quantity: 3.0, cost: 0.06}
    ])

    window = %{
      "from" => Date.to_iso8601(Date.add(today, -1)),
      "to" => Date.to_iso8601(today)
    }

    query_conn =
      dispatch(:post, query_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => window
      })

    forecast_conn =
      dispatch(:post, forecast_path() <> "?api-version=2023-03-01", %{
        "type" => "ActualCost",
        "timePeriod" => window
      })

    assert query_conn.status == @ok
    assert forecast_conn.status == @ok

    query_total =
      decode(query_conn)["properties"]["rows"] |> Enum.map(&Enum.at(&1, 0)) |> Enum.sum()

    forecast_body = decode(forecast_conn)
    names = Enum.map(forecast_body["properties"]["columns"], & &1["name"])
    forecast_idx = Enum.find_index(names, &(&1 == "Forecast"))
    cost_idx = Enum.find_index(names, &(&1 == "Cost"))

    actual_total =
      forecast_body["properties"]["rows"]
      |> Enum.filter(&(Enum.at(&1, forecast_idx) == "actual"))
      |> Enum.map(&Enum.at(&1, cost_idx))
      |> Enum.sum()

    assert_in_delta query_total, actual_total, 1.0e-9
    assert_in_delta actual_total, 0.25, 1.0e-9
  end

  test "unsupported type and missing window are typed 400s on forecast" do
    conn =
      dispatch(:post, forecast_path() <> "?api-version=2023-03-01", %{
        "type" => "AmortizedCost",
        "timeframe" => "MonthToDate"
      })

    assert conn.status == @bad_request
    assert decode(conn)["error"]["code"] == "InvalidRequest"

    conn = dispatch(:post, forecast_path() <> "?api-version=2023-03-01", %{"type" => "ActualCost"})
    assert conn.status == @bad_request
  end

  test "missing api-version is a typed 400 on forecast" do
    conn =
      dispatch(:post, forecast_path(), %{
        "type" => "ActualCost",
        "timeframe" => "MonthToDate"
      })

    assert conn.status == @bad_request
  end
end
