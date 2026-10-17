defmodule Smalt.Metrics do
  @moduledoc """
  Azure Monitor metrics surface (microsoft.insights/metrics) — time-series
  metric points recorded per resource, emitted on resource lifecycle events
  (PUT create/update, DELETE) and via custom-metric POSTs to
  `.../providers/microsoft.insights/metrics`.

  Storage: `:smalt_metrics` ETS table (Smalt.Store), append-only point rows
  keyed `"<lowercased resource id>|<metric>|<ts_ms>|<unique seq>"` so writes
  are race-free (no read-modify-write) and scans are deterministic ordered
  prefix walks.

  Envelope parity: GET returns the real Azure Monitor response shape —
  `{value: [{name: {value, localizedValue}, unit, timeseries:
  [{data: [{timeStamp, total, count, average}]}]}]}` — with coarse
  timespan/interval bucketing (ISO duration PTnS/nM/nH) and zero-filled
  buckets for timeseries continuity (a real Azure Monitor GET also returns
  dense buckets; empty buckets carry only `timeStamp`).
  """

  alias Smalt.Store

  @table :smalt_metrics
  @latest_api_version "2024-02-01"
  @default_metric "Requests"

  def latest_api_version, do: @latest_api_version
  def default_metric, do: @default_metric

  @doc """
  Monotonic api-version admission for the metrics family: any well-formed
  `YYYY-MM-DD[-suffix]` version <= the family latest is accepted; newer,
  malformed, or missing versions are refused.
  """
  def version_admitted?(version) when is_binary(version) do
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})(?:-.*)?$/, version, capture: :all_but_first) do
      [y, m, d] ->
        with {yi, ""} <- Integer.parse(y),
             {mi, ""} <- Integer.parse(m),
             {di, ""} <- Integer.parse(d),
             {:ok, v_date} <- Date.new(yi, mi, di),
             {:ok, l_date} <- Date.from_iso8601(@latest_api_version) do
          Date.compare(v_date, l_date) in [:lt, :eq]
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def version_admitted?(_), do: false

  # -- write side --------------------------------------------------------------

  @doc """
  Records one metric point for `resource_id` (any casing; keys are stored
  lowercased). `ts_ms` is unix epoch milliseconds. Returns :ok.
  """
  def emit(resource_id, metric, value, ts_ms \\ now_ms(), unit \\ "Count")

  def emit(resource_id, metric, value, ts_ms, unit)
      when is_binary(resource_id) and is_binary(metric) and is_number(value) and
             is_integer(ts_ms) and is_binary(unit) do
    key =
      "#{String.downcase(resource_id)}|#{metric}|#{ts_ms}|" <>
        String.pad_leading(
          Integer.to_string(System.unique_integer([:monotonic, :positive])),
          20,
          "0"
        )

    Store.put(@table, key, %{"value" => value * 1.0, "unit" => unit, "ts" => ts_ms})
    :ok
  end

  @doc """
  Drops every datapoint of `resource_id`'s series (all metrics). Cascade
  law: a resource DELETE removes its own metrics rows — a deleted resource
  never leaves residue in :smalt_metrics (enclave destroy residue gate).
  """
  def drop(resource_id) when is_binary(resource_id) do
    prefix = String.downcase(resource_id) <> "|"

    for key <- Store.prefix_keys(@table, prefix) do
      Store.delete(@table, key)
    end

    :ok
  end

  # -- read side ---------------------------------------------------------------

  @doc """
  ARM-shaped single-metric timeseries for `resource_id`, bucketed by
  `interval_ms` over the inclusive range `[start_ms, end_ms]`. Buckets are
  dense (zero-filled): every interval step in the timespan is present, empty
  buckets carry only `timeStamp`, non-empty buckets carry
  `{timeStamp, total, count, average}`.
  """
  @spec query(binary, binary, integer, integer, pos_integer) :: map
  def query(resource_id, metric, start_ms, end_ms, interval_ms)
      when is_binary(resource_id) and is_binary(metric) and is_integer(interval_ms) and
             interval_ms > 0 do
    prefix = "#{String.downcase(resource_id)}|#{metric}|"

    points = Store.list_prefix(@table, prefix)

    unit =
      case points do
        [%{"unit" => u} | _] when is_binary(u) -> u
        _ -> "Count"
      end

    first_bucket = start_ms - rem(start_ms, interval_ms)

    by_bucket = Enum.group_by(points, fn p -> p["ts"] - rem(p["ts"], interval_ms) end)

    data =
      first_bucket
      |> Stream.iterate(&(&1 + interval_ms))
      |> Enum.take_while(&(&1 <= end_ms))
      |> Enum.map(fn bucket ->
        case Map.get(by_bucket, bucket, []) do
          [] ->
            %{"timeStamp" => iso8601(bucket)}

          pts ->
            total = pts |> Enum.map(& &1["value"]) |> Enum.sum()
            n = length(pts)

            %{
              "timeStamp" => iso8601(bucket),
              "total" => total,
              "count" => n,
              "average" => total / n
            }
        end
      end)

    %{
      "name" => %{"value" => metric, "localizedValue" => metric},
      "unit" => unit,
      "timeseries" => [%{"data" => data}]
    }
  end

  # -- parsers (exported for the Router; pure, unit-testable) ------------------

  @doc """
  Parses a real-Azure timespan query parameter `"start/end"` (ISO8601) into
  `{start_ms, end_ms}`. Unparseable halves degrade to `nil` and the caller
  applies defaults (day-back window to now).
  """
  def parse_timespan(nil), do: {default_start_ms(), now_ms()}

  def parse_timespan(raw) when is_binary(raw) do
    case String.split(raw, "/", parts: 2) do
      [start_s, end_s] ->
        {to_ms_or_nil(start_s) || default_start_ms(), to_ms_or_nil(end_s) || now_ms()}

      _ ->
        {default_start_ms(), now_ms()}
    end
  end

  @doc """
  Parses an ISO8601 duration (`PT1M`, `PT5M`, `PT1H`, `P1D`, ...) into
  milliseconds. Returns `{:ok, ms}` or `:error`. Coarse: seconds/minutes/
  hours/days components only.
  """
  def parse_interval(nil), do: {:ok, 60_000}

  def parse_interval(raw) when is_binary(raw) do
    case Regex.named_captures(
           ~r/^P(?:(?<d>\d+)D)?(?:T(?:(?<h>\d+)H)?(?:(?<m>\d+)M)?(?:(?<s>\d+(?:\.\d+)?)S)?)?$/,
           raw
         ) do
      %{"d" => d, "h" => h, "m" => m, "s" => s} ->
        ms =
          trunc(
            parse_num(d) * 86_400_000 + parse_num(h) * 3_600_000 + parse_num(m) * 60_000 +
              parse_num(s) * 1000
          )

        if ms > 0, do: {:ok, ms}, else: :error

      _ ->
        :error
    end
  end

  defp parse_num(""), do: 0
  defp parse_num(nil), do: 0

  defp parse_num(s) do
    if String.contains?(s, ".") do
      String.to_float(s)
    else
      String.to_integer(s)
    end
  end

  @doc false
  def now_ms, do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

  defp default_start_ms, do: now_ms() - 86_400_000

  defp to_ms_or_nil(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp iso8601(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
