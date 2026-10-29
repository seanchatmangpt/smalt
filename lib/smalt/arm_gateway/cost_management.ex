defmodule Smalt.ArmGateway.CostManagement do
  @moduledoc """
  ARM Cost Management + Consumption parity surface (AZURE-FIDELITY lane 6).

  Two endpoints, assembled from a seeded usage/cost event store:

    * `POST /subscriptions/{sub}/providers/Microsoft.CostManagement/query`
      — documented request `{type: "ActualCost", timeframe | timePeriod}`,
      documented response `{id, name, type, properties: {columns, rows}}`.
      Columns are a documented ActualCost subset (Cost, Currency,
      UsageDateTime, ChargeType, ResourceId, ServiceName).

    * `POST /subscriptions/{sub}/providers/Microsoft.CostManagement/forecast`
      — same request grammar as query, documented ForecastResults envelope
      (columns = the ActualCost subset + `Forecast`), rows projected
      emulator-simple from the trailing window (see `forecast/2`).

    * `GET /subscriptions/{sub}/providers/Microsoft.Consumption/usageDetails`
      — documented usage-details columns (date, serviceName, quantity, cost,
      tags).

  ## Event store

  A single public ETS bag table (`:smalt_cost_usage`), rows
  `{sub_id, unique, event}`. The internal event record:

      %{date: Date.t, service_name: binary, quantity: number, cost: float,
        currency: binary, resource_id: binary, tags: map}

  Wiring posture ("wire what exists, seed the rest deterministically"): the
  M9/M10-class throttle/latency realism plugs (`Smalt.Egress.LatencyPlug`,
  `Smalt.Egress.ThrottlePlug`, the ARM fixed-window throttle) model wire
  behavior, not spend — no metering producer exists on this tree, so the
  store is fed deterministically: `seed_defaults/1` mints a fixed-shape
  3-event window anchored on the current UTC date, and `seed_events/2`
  admits caller-supplied events (the integration court pins exact windows
  through it).

  Both surfaces read the SAME store rows, so the reconciliation court holds
  by construction: Σ usage-details cost over a window == the ActualCost
  query total for the same window.
  """

  @table :smalt_cost_usage
  @currency "USD"
  @query_type "Microsoft.CostManagement/QueryResults"
  @usage_type "Microsoft.Consumption/usageDetails"
  @charge_type "Usage"

  # Documented ActualCost column subset and charge type.
  @query_columns [
    {"Cost", "Number"},
    {"Currency", "String"},
    {"UsageDateTime", "String"},
    {"ChargeType", "String"},
    {"ResourceId", "String"},
    {"ServiceName", "String"}
  ]

  @epoch ~D[2000-01-01]

  # ---------------------------------------------------------------------------
  # Store
  # ---------------------------------------------------------------------------

  @doc "Ensures the usage-event table exists (heir to :init, node-local)."
  @spec ensure_table :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      try do
        :ets.new(@table, [
          :named_table,
          :public,
          :bag,
          {:read_concurrency, true},
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Admits caller-supplied usage events for `sub_id`. Each event needs `:date`
  (`Date` or ISO-8601 date/datetime string), `:service_name`, `:quantity`,
  `:cost`; optional `:resource_id`, `:currency`, `:tags`.
  Returns the count admitted.
  """
  @spec seed_events(String.t(), [map()]) :: non_neg_integer()
  def seed_events(sub_id, events) when is_binary(sub_id) and is_list(events) do
    ensure_table()

    Enum.each(events, fn ev ->
      true = :ets.insert(@table, {sub_id, make_key(), normalize_event(ev)})
    end)

    length(events)
  end

  @doc "Drops every usage event for `sub_id` (test isolation seam)."
  @spec reset(String.t()) :: :ok
  def reset(sub_id) do
    ensure_table()

    true = :ets.match_delete(@table, {sub_id, :_, :_})
    :ok
  end

  @doc """
  Deterministic default seed: a fixed-shape 3-event window anchored on the
  current UTC date (today-2, today-1, today; two services, constant costs).
  Idempotent per subscription — a re-seed is a no-op.
  """
  @spec seed_defaults(String.t()) :: :ok
  def seed_defaults(sub_id) do
    ensure_table()

    if events(sub_id) == [] do
      today = Date.utc_today()

      seed_events(sub_id, [
        %{
          date: Date.add(today, -2),
          service_name: "Virtual Machines",
          resource_id:
            "/subscriptions/#{sub_id}/resourceGroups/rg-seed/providers/Microsoft.Compute/virtualMachines/vm-seed",
          quantity: 24.0,
          cost: 0.96
        },
        %{
          date: Date.add(today, -1),
          service_name: "Storage",
          resource_id:
            "/subscriptions/#{sub_id}/resourceGroups/rg-seed/providers/Microsoft.Storage/storageAccounts/acc-seed",
          quantity: 12.5,
          cost: 0.29
        },
        %{
          date: today,
          service_name: "Virtual Machines",
          resource_id: "/services/vm-seed-2",
          quantity: 24.0,
          cost: 0.96
        }
      ])

      :ok
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Cost Management query (POST .../Microsoft.CostManagement/query)
  # ---------------------------------------------------------------------------

  @doc """
  Executes the documented query:
  `%{"type" => "ActualCost", "timeframe" => tf}` or
  `%{"type" => "ActualCost", "timePeriod" => %{"from" => d1, "to" => d2}}`
  (an explicit timePeriod wins, matching documented Azure semantics).
  Returns `{:ok, response_map}` or `{:error, term}` (caller renders the
  typed ARM error).
  """
  @spec query(String.t(), map()) ::
          {:ok, map()}
          | {:error, :invalid_request | :missing_time_period | :invalid_date | {:unsupported_type | :unsupported_timeframe, String.t()}}
  def query(sub_id, body) when is_binary(sub_id) and is_map(body) do
    with :ok <- check_type(body),
         {:ok, from, to} <- resolve_window(body) do
      rows =
        sub_id
        |> in_window(from, to)
        |> Enum.map(fn {_sub, _key, ev} ->
          [
            ev.cost,
            ev.currency,
            Date.to_iso8601(ev.date),
            @charge_type,
            ev.resource_id,
            ev.service_name
          ]
        end)

      name = make_key()

      {:ok,
       %{
         "id" =>
           "/subscriptions/#{sub_id}/providers/Microsoft.CostManagement/queryResults/#{name}",
         "name" => name,
         "type" => @query_type,
         "properties" => %{
           "columns" =>
             Enum.map(@query_columns, fn {name, type} -> %{"name" => name, "type" => type} end),
           "rows" => rows
         }
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Cost Management forecast (POST .../Microsoft.CostManagement/forecast)
  # ---------------------------------------------------------------------------

  @forecast_type "Microsoft.CostManagement/ForecastResults"
  @trailing_days 7

  @doc """
  Executes the documented forecast: same request grammar as `query/2`
  (`%{"type" => "ActualCost", "timeframe" | "timePeriod" => ...}`), documented
  response `{id, name, type, properties: {columns, rows}}` where the column
  list is the documented ActualCost subset plus a `Forecast` column
  (`"actual"` vs `"forecast"`).

  EMULATOR-SIMPLE projection (documented, deterministic): for each date in the
  requested window, dates carrying usage events render per-service actual
  rows (`Forecast = "actual"`); dates with no events render per-service
  projected rows (`Forecast = "forecast"`) at the service's trailing-average
  daily cost — total cost over the `#{@trailing_days}` days ending the day
  before the window start, divided by `#{@trailing_days}`. Services with no
  trailing history are not projected. Rows are aggregated per
  (date, service); ResourceId is the synthetic `/services/forecast/{service}`
  form, since the projection is service-level.
  """
  @spec forecast(String.t(), map()) ::
          {:ok, map()}
          | {:error, :invalid_request | :missing_time_period | :invalid_date | {:unsupported_type | :unsupported_timeframe, String.t()}}
  def forecast(sub_id, body) when is_binary(sub_id) and is_map(body) do
    with :ok <- check_type(body),
         {:ok, from, to} <- resolve_window(body) do
      trailing =
        sub_id
        |> in_window(Date.add(from, -@trailing_days), Date.add(from, -1))
        |> Enum.group_by(fn {_s, _k, ev} -> {ev.service_name, ev.currency} end, fn {_s, _k, ev} ->
          ev.cost
        end)

      projections =
        Map.new(trailing, fn {{service, currency}, costs} ->
          {{service, currency}, Enum.sum(costs) / @trailing_days}
        end)

      rows =
        Date.range(from, to)
        |> Enum.flat_map(fn date ->
          actuals =
            sub_id
            |> in_window(date, date)
            |> Enum.group_by(fn {_s, _k, ev} -> {ev.service_name, ev.currency} end, fn {_s, _k, ev} ->
              ev.cost
            end)

          case Map.keys(actuals) do
            [] ->
              Enum.map(Map.keys(projections), fn {service, currency} ->
                [
                  Map.fetch!(projections, {service, currency}),
                  currency,
                  Date.to_iso8601(date),
                  @charge_type,
                  "/services/forecast/#{String.replace(service, " ", "-")}",
                  service,
                  "forecast"
                ]
              end)

            keys ->
              Enum.map(Enum.sort(keys), fn {service, currency} = k ->
                [
                  Enum.sum(Map.fetch!(actuals, k)),
                  currency,
                  Date.to_iso8601(date),
                  @charge_type,
                  "/services/forecast/#{String.replace(service, " ", "-")}",
                  service,
                  "actual"
                ]
              end)
          end
        end)

      name = make_key()

      {:ok,
       %{
         "id" => "/subscriptions/#{sub_id}/providers/Microsoft.CostManagement/forecastResults/#{name}",
         "name" => name,
         "type" => @forecast_type,
         "properties" => %{
           "columns" =>
             Enum.map(@query_columns ++ [{"Forecast", "String"}], fn {cname, type} ->
               %{"name" => cname, "type" => type}
             end),
           "rows" => rows
         }
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Consumption usage details (GET .../Microsoft.Consumption/usageDetails)
  # ---------------------------------------------------------------------------

  @doc """
  Usage-details envelope for `sub_id`, filtered by `params` —
  `startDate`/`endDate` (inclusive), or the documented
  `$filter=properties/usageStart ge 'D1' and properties/usageEnd le 'D2'`.
  Each row carries the documented columns (date, serviceName, quantity,
  cost, tags).
  """
  @spec usage_details(String.t(), map()) :: map()
  def usage_details(sub_id, params) when is_binary(sub_id) and is_map(params) do
    {from, to} = window_from_params(params)

    rows =
      sub_id
      |> in_window(from, to)
      |> Enum.map(fn {sub, key, ev} ->
        %{
          "id" => "/subscriptions/#{sub}/providers/Microsoft.Consumption/usageDetails/#{key}",
          "name" => key,
          "type" => @usage_type,
          "tags" => ev.tags,
          "properties" => %{
            "date" => Date.to_iso8601(ev.date),
            "serviceName" => ev.service_name,
            "quantity" => ev.quantity,
            "cost" => ev.cost,
            "tags" => ev.tags
          }
        }
      end)

    %{"value" => rows}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp check_type(%{"type" => "ActualCost"}), do: :ok
  defp check_type(%{"type" => other}) when is_binary(other),
    do: {:error, {:unsupported_type, other}}
  defp check_type(_), do: {:error, :invalid_request}

  defp resolve_window(%{"timePeriod" => %{"from" => f, "to" => t}})
       when is_binary(f) and is_binary(t) do
    with {:ok, from} <- parse_date(f),
         {:ok, to} <- parse_date(t) do
      {:ok, from, to}
    end
  end

  defp resolve_window(%{"timeframe" => tf}) when is_binary(tf) do
    today = Date.utc_today()
    bom = Date.beginning_of_month(today)
    last_month_end = Date.add(bom, -1)

    case tf do
      "MonthToDate" -> {:ok, bom, today}
      "TheLastMonth" -> {:ok, Date.beginning_of_month(last_month_end), last_month_end}
      "WeekToDate" -> {:ok, Date.add(today, -6), today}
      other -> {:error, {:unsupported_timeframe, other}}
    end
  end

  defp resolve_window(_), do: {:error, :missing_time_period}

  defp in_window(sub_id, from, to) do
    ensure_table()

    sub_id
    |> events()
    |> Enum.filter(fn {_sub, _key, ev} ->
      Date.compare(ev.date, from) != :lt and Date.compare(ev.date, to) != :gt
    end)
    |> Enum.sort_by(fn {_sub, _key, ev} -> {ev.date, ev.resource_id} end)
  end

  defp events(sub_id) do
    ensure_table()
    :ets.lookup(@table, sub_id)
  end

  defp window_from_params(params) do
    cond do
      params["startDate"] || params["endDate"] ->
        {opt_date(params["startDate"], @epoch), opt_date(params["endDate"], Date.utc_today())}

      filter = params["$filter"] ->
        parse_arm_filter(filter)

      true ->
        {@epoch, Date.utc_today()}
    end
  end

  # Documented Consumption filter form:
  #   properties/usageStart ge '2026-10-01' and properties/usageEnd le '2026-10-31'
  defp parse_arm_filter(filter) do
    start_re = ~r/usageStart\s+ge\s+'(\d{4}-\d{2}-\d{2})'/i
    end_re = ~r/usageEnd\s+le\s+'(\d{4}-\d{2}-\d{2})'/i

    from =
      case Regex.run(start_re, filter) do
        [_, d] -> Date.from_iso8601!(d)
        _ -> @epoch
      end

    to =
      case Regex.run(end_re, filter) do
        [_, d] -> Date.from_iso8601!(d)
        _ -> Date.utc_today()
      end

    {from, to}
  end

  defp opt_date(nil, default), do: default

  defp opt_date(s, _default) do
    Date.from_iso8601!(String.slice(s, 0, 10))
  end

  defp parse_date(s) do
    case Date.from_iso8601(String.slice(s, 0, 10)) do
      {:ok, d} -> {:ok, d}
      _ -> {:error, :invalid_date}
    end
  end

  defp normalize_event(ev) do
    date =
      case Map.get(ev, :date) do
        %Date{} = d -> d
        s when is_binary(s) -> Date.from_iso8601!(String.slice(s, 0, 10))
      end

    %{
      date: date,
      service_name: Map.get(ev, :service_name, "Unknown"),
      quantity: Map.get(ev, :quantity, 1),
      cost: ev.cost * 1.0,
      currency: Map.get(ev, :currency, @currency),
      resource_id: Map.get(ev, :resource_id, "/services/unknown"),
      tags: Map.get(ev, :tags, %{})
    }
  end

  defp make_key do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      :erlang.band(c, 0x0FFF),
      :erlang.band(d, 0x3FFF) + 0x8000,
      e
    ])
    |> IO.iodata_to_binary()
  end
end
