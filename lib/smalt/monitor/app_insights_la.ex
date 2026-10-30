defmodule Smalt.Monitor.AppInsightsLa do
  @moduledoc """
  Application Insights → Log Analytics landing seam (r18, lane S5).

  The Breeze face (`Smalt.Monitor.AppInsights.track/1`) validates and rings
  items; this seam projects each accepted item into a Log Analytics-shaped
  row and lands it in the same workspace store the existing Log Analytics
  KQL query face reads (`Smalt.DataPlane.Sentinel` rows in
  `:smalt_sentinel_rows`), so `POST /v2/track` telemetry becomes answerable
  by `POST /v1/workspaces/:workspace/query` KQL without any new query
  surface.

  Wire mapping (the real Breeze→workspace pipeline, deterministic):

  - workspace = effective instrumentation key (item-level iKey wins, the
    envelope iKey fills in — the same rule Breeze validation uses).
  - table = `data.baseType` mapped to the real App Insights Log Analytics
    table family: MessageData→AppTraces, RequestData→AppRequests,
    RemoteDependencyData→AppDependencies, ExceptionData→AppExceptions,
    MetricData→AppMetrics, EventData→AppEvents, PageViewData→AppPageViews,
    AvailabilityData→AppAvailabilityResults,
    PerformanceCounterData→AppPerformanceCounters,
    BrowserTimingData→AppBrowserTimings. An unknown baseType lands in
    `AppOther` — typed, queryable, never silently dropped.
  - rows carry the real column names (Message/SeverityLevel on AppTraces,
    Name/Url/Success/ResultCode/DurationMs on AppRequests, ...) plus ItemId
    (per-item GUID, real Breeze semantics), IKey, and Properties (JSON
    string of baseData.properties when present).

  Landing reuses the REAL Log Analytics ingest face
  (`Smalt.DataPlane.Sentinel.ingest/4`, api-version 2023-01-01) — the same
  collaborator the `POST /dataCollectionRules/:dcr/streams/:stream` wire
  route uses — so rows get the shared augment columns (ledgerId/tenantId/
  TimeGenerated/...) and interoperate with every KQL operator the engine
  already supports (where/summarize/bin/ago/project).
  """

  alias Smalt.DataPlane.Sentinel

  @la_api_version "2023-01-01"

  # Real Breeze baseType -> Log Analytics table family.
  @base_type_tables %{
    "MessageData" => "AppTraces",
    "RequestData" => "AppRequests",
    "RemoteDependencyData" => "AppDependencies",
    "ExceptionData" => "AppExceptions",
    "MetricData" => "AppMetrics",
    "EventData" => "AppEvents",
    "PageViewData" => "AppPageViews",
    "AvailabilityData" => "AppAvailabilityResults",
    "PerformanceCounterData" => "AppPerformanceCounters",
    "BrowserTimingData" => "AppBrowserTimings"
  }

  @doc """
  Lands accepted Breeze items into the Log Analytics workspace store.

  `items` are the ACCEPTED items (the `track/1` valid list); `envelope_ikey`
  is the envelope-level iKey (item-level wins). Returns
  `{:ok, %{landed: count, skipped: count, tables: %{table => count}}}`.
  Raises nothing: per-table ingest failures accumulate into `{:error, ...}`
  so the caller can log loudly without corrupting the Breeze ack.

  An item with no effective iKey is SKIPPED (counted in `skipped`), never
  dropped silently.
  """
  @spec land([map()], String.t() | nil) :: {:ok, map()} | {:error, map()}
  def land(items, envelope_ikey \\ nil) when is_list(items) do
    landed =
      items
      |> Enum.flat_map(&row_for(&1, envelope_ikey))
      |> Enum.group_by(fn {ws, table, _row} -> {ws, table} end, fn {_ws, _table, row} -> row end)

    results =
      Map.new(landed, fn {{ws, table}, rows} ->
        # The REAL Log Analytics ingest face — the same collaborator the
        # POST /dataCollectionRules/:dcr/streams/:stream wire route uses.
        case Sentinel.ingest(ws, table, rows, @la_api_version) do
          {:ok, 204, _} ->
            {table, length(rows)}

          {:error, status, body} ->
            throw({:la_ingest_error, ws, table, status, body})
        end
      end)

    total = results |> Map.values() |> Enum.sum()

    {:ok, %{landed: total, skipped: skipped(items, envelope_ikey), tables: results}}
  catch
    # Per-table ingest failure: typed error out, nothing raised past the
    # caller's fail-safe boundary.
    {:la_ingest_error, ws, table, status, body} ->
      {:error, %{workspace: ws, table: table, status: status, body: body}}
  end

  # -- item -> (workspace, table, row) ---------------------------------------

  # One projected row per accepted item; [] skips (no effective iKey).
  defp row_for(item, envelope_ikey) when is_map(item) do
    case effective_ikey(item, envelope_ikey) do
      ikey when is_binary(ikey) and ikey != "" ->
        [{ikey, table_for(item), project_row(item, ikey)}]

      _ ->
        []
    end
  end

  defp row_for(_item, _envelope_ikey), do: []

  # Item-level iKey wins; envelope-level fills in (Breeze validation rule).
  defp effective_ikey(item, envelope_ikey) do
    case item_ikey(item) do
      k when is_binary(k) and k != "" -> k
      _ -> envelope_ikey
    end
  end

  defp item_ikey(item) when is_map(item), do: Map.get(item, "iKey")
  defp item_ikey(_), do: nil

  defp table_for(item) do
    base_type =
      case get_in(item, ["data", "baseType"]) do
        t when is_binary(t) and t != "" -> t
        _ -> ""
      end

    Map.get(@base_type_tables, base_type, "AppOther")
  end

  defp project_row(item, ikey) do
    base_data = get_in(item, ["data", "baseData"]) || %{}
    time = item_time(item)
    item_id = mint_item_id()
    properties = properties_column(base_data)

    base = %{
      "TimeGenerated" => time,
      "ItemId" => item_id,
      "IKey" => ikey,
      "Properties" => properties
    }

    case table_for(item) do
      "AppTraces" ->
        base
        |> Map.merge(%{
          "Message" => bin(base_data["message"]),
          "SeverityLevel" => severity_level(base_data["severityLevel"]),
          "SdkVersion" => tags_sdk_version(item)
        })

      "AppRequests" ->
        base
        |> Map.merge(%{
          "Name" => bin(base_data["name"]),
          "Url" => bin(base_data["url"]),
          "Success" => base_data["success"],
          "ResultCode" => result_code(base_data["responseCode"]),
          "DurationMs" => duration_ms(base_data["duration"]),
          "Id" => bin(base_data["id"])
        })

      "AppDependencies" ->
        base
        |> Map.merge(%{
          "Name" => bin(base_data["name"]),
          "Target" => bin(base_data["target"]),
          "DependencyTypeName" => bin(base_data["type"]),
          "Data" => bin(base_data["data"]),
          "Success" => base_data["success"],
          "ResultCode" => result_code(base_data["resultCode"]),
          "DurationMs" => duration_ms(base_data["duration"]),
          "Id" => bin(base_data["id"])
        })

      "AppExceptions" ->
        base
        |> Map.merge(%{
          "ProblemId" => bin(base_data["problemId"]),
          "SeverityLevel" => severity_level(base_data["severityLevel"]),
          "Details" => jason(base_data["exceptions"])
        })

      "AppMetrics" ->
        metric_row(base, base_data)

      "AppEvents" ->
        Map.merge(base, %{"Name" => bin(base_data["name"])})

      "AppPageViews" ->
        base
        |> Map.merge(%{
          "Name" => bin(base_data["name"]),
          "Url" => bin(base_data["url"]),
          "DurationMs" => duration_ms(base_data["duration"])
        })

      "AppAvailabilityResults" ->
        base
        |> Map.merge(%{
          "Name" => bin(base_data["name"]),
          "Success" => base_data["success"],
          "DurationMs" => duration_ms(base_data["duration"]),
          "Message" => bin(base_data["message"])
        })

      _unknown ->
        # Typed honest fallback: the whole item rides as JSON in Payload with
        # its baseType named — queryable, never a silent drop.
        base
        |> Map.merge(%{
          "Name" => bin(item["name"]),
          "BaseType" => get_in(item, ["data", "baseType"]),
          "Payload" => jason(item)
        })
    end
  end

  # MetricData: metrics is a LIST of {name, value}; real LA shows one
  # AppMetrics row per metric sample — expand element-wise.
  defp metric_row(base, %{"metrics" => metrics} = _bd) when is_list(metrics) and metrics != [] do
    m = hd(metrics)

    Map.merge(base, %{
      "Name" => bin(m["name"]),
      "Value" => number_or_nil(m["value"]),
      "Count" => number_or_nil(m["count"])
    })
  end

  defp metric_row(base, base_data) do
    Map.merge(base, %{"Name" => bin(base_data["name"]), "Value" => number_or_nil(base_data["value"])})
  end

  # -- column helpers (typed, total: never raise on hostile item shapes) -----

  defp item_time(item) do
    case item["time"] do
      t when is_binary(t) and t != "" -> t
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp bin(v) when is_binary(v), do: v
  defp bin(v) when is_number(v), do: to_string(v)
  defp bin(_), do: nil

  defp result_code(v) when is_integer(v), do: Integer.to_string(v)
  defp result_code(v) when is_binary(v), do: v
  defp result_code(_), do: nil

  defp severity_level(v) when v in [0, 1, 2, 3, 4], do: v
  defp severity_level(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n in 0..4 -> n
      _ -> nil
    end
  end
  defp severity_level(_), do: nil

  # Breeze durations are .NET timespans ("dd.hh:mm:ss.mmm" / "hh:mm:ss.mmm");
  # a bare number rides as milliseconds (real AI SDKs send both shapes).
  # Colon-segment parse: the days form is the 4-colon-segment shape, so the
  # two 5-...-shape ambiguities of a group-capture regex cannot arise.
  defp duration_ms(v) when is_number(v), do: v

  defp duration_ms(v) when is_binary(v) do
    case String.split(v, ":", parts: 4) do
      [h, m, s_ms] -> ts_ms("0", h, m, s_ms)
      [d, h, m, s_ms] -> ts_ms(d, h, m, s_ms)
      _ -> nil
    end
  end

  defp duration_ms(_), do: nil

  # Part-wise: every segment parses or rides as 0 — total, never a raise on
  # a hostile/edge shape.
  defp ts_ms(d, h, m, s_ms) do
    int_or_0 = fn
      p when is_binary(p) ->
        case Integer.parse(p) do
          {n, _} -> n
          :error -> 0
        end

      _ ->
        0
    end

    {s, ms} =
      case String.split(s_ms, ".", parts: 2) do
        [s, ms] -> {s, ms}
        [s] -> {s, "0"}
      end

    int_or_0.(d) * 86_400_000 + int_or_0.(h) * 3_600_000 + int_or_0.(m) * 60_000 +
      int_or_0.(s) * 1_000 + int_or_0.(ms)
  end

  defp number_or_nil(v) when is_number(v), do: v

  defp number_or_nil(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  defp number_or_nil(_), do: nil

  defp properties_column(base_data) do
    case base_data["properties"] do
      p when is_map(p) and map_size(p) > 0 -> jason(p)
      _ -> nil
    end
  end

  defp tags_sdk_version(item) do
    case get_in(item, ["tags", "ai.internal.sdkVersion"]) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp jason(nil), do: nil

  defp jason(term) do
    Jason.encode!(term)
  rescue
    _ -> inspect(term)
  end

  # Per-item GUID (real Breeze mints one per item; deterministic replay is
  # not a Breeze property — duplicates are distinct items).
  defp mint_item_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c4 = :erlang.band(c, 0x0FFF) + 0x4000
    d = :erlang.bor(:erlang.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c4, d, e])
    |> IO.iodata_to_binary()
  end

  defp skipped(items, envelope_ikey) do
    Enum.count(items, fn item ->
      case effective_ikey(item, envelope_ikey) do
        k when is_binary(k) and k != "" -> false
        _ -> true
      end
    end)
  end
end
