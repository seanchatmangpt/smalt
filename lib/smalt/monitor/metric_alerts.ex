defmodule Smalt.Monitor.MetricAlerts do
  @moduledoc """
  Azure Monitor metric alert rules (wave-6 lane w6ap, v26.10.20).

  CRUD over alert-rule records at the ARM shape
  `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Insights/metricAlerts/{name}`,
  stored in heir'd ETS `:smalt_metric_alerts` (`{:heir, Process.whereis(:init),
  []}` 3-tuple — the v26.10.19 silent-disarm law; no GenServer: the table is
  created lazily and inherited by init on creator death).

  Evaluation (`evaluate/1,2`) reads the REAL telemetry accumulator
  `Smalt.Monitor.Metrics` (per-minute `{count, sum, max}` aggregates) and
  compares the window aggregate against the rule criteria. On breach it fires
  a typed `[:smalt, :monitor, :alert_fired]` event through the real
  `:telemetry` dispatcher — `measurements: %{observed: value}`,
  `metadata: %{rule: name, metric: metric, threshold: threshold, resource:
  resource_id}` — deduplicated to ONE firing per rule per evaluation window
  (the last-fired window bucket is persisted on the rule; a NEW window
  re-fires, a breach that stops does not fire).

  The metric source is injectable for observation
  (`evaluate/2` `:source` fun `(metric, window_ms, resource_id) -> number`);
  the default is `default_source/3` over `Smalt.Monitor.Metrics.series/5`.

  Wire exposure rides a dedicated plug (post-router-split mount; the draft
  route clauses live in this module's moduledoc tail and `wire helpers`).
  """

  @table :smalt_metric_alerts

  @operators ~w(GreaterThan LessThan Equals)
  @windows ~w(PT1M PT5M PT15M PT1H)
  @window_ms %{"PT1M" => 60_000, "PT5M" => 300_000, "PT15M" => 900_000, "PT1H" => 3_600_000}

  @typedoc "Validation failure: typed atom, one per malformed field."
  @type validation_error() ::
          :bad_body
          | :bad_operator
          | :bad_threshold
          | :bad_severity
          | :bad_window
          | :bad_metric_name
          | :bad_frequency

  # -- CRUD ----------------------------------------------------------------------

  @doc "PUT an alert rule (create or full replace). Returns `{:ok, wire}` or `{:error, validation_error()}`."
  @spec put_alert(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, validation_error()}
  def put_alert(sub, rg, name, body) when is_binary(sub) and is_binary(rg) and is_binary(name) do
    with :ok <- validate(body) do
      rule = %{
        key: {String.downcase(sub), String.downcase(rg), name},
        sub: sub,
        rg: rg,
        name: name,
        criteria: body["criteria"],
        window_size: body["windowSize"],
        frequency: body["frequency"],
        severity: body["severity"],
        enabled: Map.get(body, "enabled", true),
        resource_id: Map.get(body, "resourceId") || Smalt.Monitor.Metrics.platform_resource(),
        last_fired_bucket: nil,
        last_updated: System.system_time(:millisecond)
      }

      ensure_table()
      :ets.insert(@table, {rule.key, rule})
      {:ok, alert_wire(rule)}
    end
  end

  def put_alert(_s, _r, _n, _b), do: {:error, :bad_body}

  @doc "GET an alert rule. `{:ok, wire}` | `{:error, :not_found}`."
  @spec get_alert(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_alert(sub, rg, name) do
    ensure_table()

    case :ets.lookup(@table, {String.downcase(sub), String.downcase(rg), name}) do
      [{_k, rule}] -> {:ok, alert_wire(rule)}
      [] -> {:error, :not_found}
    end
  end

  @doc "LIST alert rules in a resource group (most-recently-updated last)."
  @spec list_alerts(String.t(), String.t()) :: [map()]
  def list_alerts(sub, rg) do
    ensure_table()

    @table
    |> table_rows()
    |> Enum.filter(fn {_k, r} ->
      elem(r.key, 0) == String.downcase(sub) and elem(r.key, 1) == String.downcase(rg)
    end)
    |> Enum.sort_by(fn {_k, r} -> r.last_updated end)
    |> Enum.map(fn {_k, r} -> alert_wire(r) end)
  end

  @doc "DELETE an alert rule. `:ok` | `{:error, :not_found}`."
  @spec delete_alert(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_alert(sub, rg, name) do
    ensure_table()

    case :ets.take(@table, {String.downcase(sub), String.downcase(rg), name}) do
      [] -> {:error, :not_found}
      [_taken] -> :ok
    end
  end

  # -- evaluation ------------------------------------------------------------------

  @doc """
  Evaluate ALL enabled rules with the default metric source. Returns
  `{fired, evaluated}` where `fired` is the list of wire maps for rules that
  breached AND were not already fired in this window.
  """
  @spec evaluate(now_ms :: integer()) :: {fired :: [map()], evaluated :: non_neg_integer()}
  def evaluate(now_ms), do: evaluate(now_ms, [])

  @doc """
  Evaluate all enabled rules with an injectable metric source
  (`:source` — `(metric, window_ms, resource_id) -> number`; defaults to the
  real accumulator). Dedup law: one firing per rule per window bucket.
  """
  @spec evaluate(integer(), keyword()) :: {[map()], non_neg_integer()}
  def evaluate(now_ms, opts) when is_integer(now_ms) and is_list(opts) do
    source = Keyword.get(opts, :source, &default_source/3)
    ensure_table()

    rules =
      @table
      |> table_rows()
      |> Enum.map(fn {_k, r} -> r end)
      |> Enum.filter(& &1.enabled)

    Enum.map_reduce(rules, 0, fn rule, acc ->
      window_ms = Map.fetch!(@window_ms, rule.window_size)
      observed = source.(rule.criteria["metricName"], window_ms, rule.resource_id)
      breached? = compare(observed, rule.criteria["operator"], rule.criteria["threshold"])
      bucket = window_bucket(now_ms, window_ms)

      cond do
        breached? and rule.last_fired_bucket != bucket ->
          :telemetry.execute(
            [:smalt, :monitor, :alert_fired],
            %{observed: observed},
            %{rule: rule.name, metric: rule.criteria["metricName"], threshold: rule.criteria["threshold"], resource: rule.resource_id}
          )

          :ets.insert(@table, {rule.key, %{rule | last_fired_bucket: bucket}})
          {fired_wire(rule, observed), acc + 1}

        true ->
          {nil, acc + 1}
      end
    end)
    |> then(fn {fired, evaluated} -> {Enum.reject(fired, &is_nil/1), evaluated} end)
  end

  @doc "Records of rules that have fired (fired wire face) — observation helper."
  @spec fired_rules() :: [map()]
  def fired_rules do
    ensure_table()

    @table
    |> table_rows()
    |> Enum.filter(fn {_k, r} -> r.last_fired_bucket != nil end)
    |> Enum.map(fn {_k, r} -> alert_wire(r) end)
  end

  @doc "Table name (audit face)."
  @spec table() :: atom()
  def table, do: @table

  # -- internals -------------------------------------------------------------------

  defp compare(observed, "GreaterThan", threshold), do: observed > threshold
  defp compare(observed, "LessThan", threshold), do: observed < threshold
  defp compare(observed, "Equals", threshold), do: observed == threshold

  defp window_bucket(now_ms, window_ms), do: now_ms - rem(now_ms, window_ms)

  # Real default source: window aggregate (total) from the telemetry
  # accumulator over [now-window, now].
  defp default_source(metric, window_ms, resource_id) do
    now = System.system_time(:millisecond)

    case Smalt.Monitor.Metrics.series(resource_id, metric, now - window_ms, now, window_ms) do
      %{"timeseries" => [%{"data" => data}]} ->
        data
        |> Enum.filter(fn d -> Map.has_key?(d, "total") end)
        |> Enum.map(fn d -> d["total"] * 1.0 end)
        |> case do
          [] -> 0.0
          totals -> Enum.max(totals)
        end

      _ ->
        0.0
    end
  end

  defp validate(body) when is_map(body) do
    with %{} = criteria <- Map.get(body, "criteria") || {:error, :bad_body},
         :ok <- check(criteria["metricName"], :metric, &is_binary/1, :bad_metric_name),
         :ok <- check(criteria["operator"], :op, &(&1 in @operators), :bad_operator),
         :ok <- check(criteria["threshold"], :threshold, &is_number/1, :bad_threshold),
         :ok <- check(body["windowSize"], :window, &(&1 in @windows), :bad_window),
         :ok <- check(body["frequency"], :freq, &is_binary/1, :bad_frequency),
         :ok <- check(body["severity"], :severity, &(&1 in 0..4), :bad_severity) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_body}
    end
  end

  defp validate(_), do: {:error, :bad_body}

  defp check(value, _tag, pred, err) do
    if pred.(value), do: :ok, else: {:error, err}
  end

  defp alert_wire(rule) do
    %{
      "id" =>
        "/subscriptions/#{rule.sub}/resourceGroups/#{rule.rg}/providers/Microsoft.Insights/metricAlerts/#{rule.name}",
      "name" => rule.name,
      "type" => "Microsoft.Insights/metricAlerts",
      "location" => "global",
      "properties" => %{
        "criteria" => rule.criteria,
        "windowSize" => rule.window_size,
        "frequency" => rule.frequency,
        "severity" => rule.severity,
        "enabled" => rule.enabled,
        "resourceId" => rule.resource_id,
        "lastUpdatedTime" => iso8601(rule.last_updated)
      }
    }
  end

  defp fired_wire(rule, observed) do
    alert_wire(rule)
    |> put_in(~w(properties firedObservedValue), observed)
    |> put_in(~w(properties firedWindowBucket), rule.last_fired_bucket || window_bucket(System.system_time(:millisecond), Map.fetch!(@window_ms, rule.window_size)))
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # 3-tuple :heir form (keyword form raises ArgumentError): table
        # survives the creating process — silent-disarm law.
        try do
          :ets.new(@table, [:set, :named_table, :public, {:heir, Process.whereis(:init), []}])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp table_rows(t) do
    try do
      :ets.tab2list(t)
    rescue
      ArgumentError -> []
    end
  end

  defp iso8601(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
