defmodule Smalt.Monitor.Metrics do
  @moduledoc """
  Telemetry→Azure-Monitor accumulator (wave-6 lane w6q, v26.10.20).

  Aggregates REAL smalt `:telemetry` events into per-minute
  `{count, sum, max}` aggregates per {resource, metric, minute-bucket}, in a
  dedicated ETS table `:smalt_monitor_metrics` owned by this GenServer with a
  3-tuple `:heir` (`{:heir, Process.whereis(:init), []}`) so the table
  survives GenServer death (the lazy-ETS silent-disarm class fixed across
  v26.10.19 waves).

  Events wired (all real emit sites in lib/):
    * `[:bandit, :request, :stop]` — every HTTP request smalt serves.
      Attributed to the ARM resource id parsed from `conn.request_path`
      when the path parses as `/subscriptions/{s}/resourceGroups/{rg}/
      providers/{ns}/{type}/{name}` (case-insensitive; `resourcegroups`
      accepted); otherwise the platform pseudo-resource
      `subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/
      providers/Smalt.Monitor/platform` (metadata/endpoints, discovery,
      non-ARM faces). Metrics: `Requests` (per-request count) and
      `RequestDuration` (per-request duration in ms).
    * `[:smalt, :egress, :refused]` → `EgressRefused` on the platform
      pseudo-resource (real emit site: `lib/smalt/egress_router.ex` `refuse/2`).
    * `[:smalt, :sentinel, :retention_sweep]` → `SentinelDropped` /
      `SentinelKept` on the platform pseudo-resource (real emit site:
      `lib/smalt/data_plane/sentinel.ex` retention sweep).

  Response face: served through the EXISTING
  `/subscriptions/:sub/resourceGroups/:rg/providers/:ns/:type/:name/
  providers/microsoft.insights/metrics` GET (`arm_gateway/router.ex`
  `handle_metrics/5`), which consults this module when the resource has
  accumulator rows — one additive router hook, no new route family.

  Bucket law: raw rows are per-minute (`bucket = ts - rem(ts, 60_000)`);
  the query face re-buckets to the requested interval (clamped to >= PT1M,
  matching real Azure Monitor's minimum interval) by summing counts,
  summing sums, maxing maxes. Prune: rows older than 24h are dropped on a
  `Process.send_after` tick (SLEEP-CLASS: SCHEDULING — the process
  genuinely has nothing to do until then).
  """

  use GenServer

  @table :smalt_monitor_metrics
  @handler_id "smalt-monitor-metrics"
  @platform_resource "subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/providers/Smalt.Monitor/platform"
  @minute 60_000
  @retention_ms :timer.hours(24)

  @request_metrics ["Requests", "RequestDuration"]

  # Single source of truth for the wired telemetry events (real emit sites in
  # lib/, per the moduledoc); consumed by init/1's attach_many and events().
  @events [
    {[:bandit, :request, :stop], &__MODULE__.handle_event/4},
    {[:smalt, :egress, :refused], &__MODULE__.handle_event/4},
    {[:smalt, :sentinel, :retention_sweep], &__MODULE__.handle_event/4}
  ]
  @typedoc false
  @type row_key :: {resource :: String.t(), metric :: String.t(), bucket :: integer()}

  @doc "Platform pseudo-resource id for non-ARM-shaped traffic and platform events."
  @spec platform_resource() :: String.t()
  def platform_resource, do: @platform_resource

  @doc "Metric names the accumulator produces for `[:bandit, :request, :stop]`."
  @spec request_metrics() :: [String.t()]
  def request_metrics, do: @request_metrics

  @doc "ETS table name backing the accumulator."
  @spec table() :: atom()
  def table, do: @table

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- query face ----------------------------------------------------------------

  @doc """
  Bucketed timeseries envelope for `resource_id` (any casing) over
  `[start_ms, end_ms]` with `interval_ms` clamped to >= 60_000. Same
  envelope as `Smalt.Metrics.query/5` plus `maximum` per bucket. Empty
  window → dense empty buckets (timeStamp-only), matching the zero-fill
  law of `Smalt.Metrics.query/5`.
  """
  @spec series(binary, binary, integer, integer, pos_integer) :: map
  def series(resource_id, metric, start_ms, end_ms, interval_ms)
      when is_binary(resource_id) and is_binary(metric) and is_integer(interval_ms) and
             interval_ms > 0 do
    interval = max(interval_ms, @minute)
    wanted = String.downcase(resource_id)

    rows =
      @table
      |> table_rows()
      # Rows are {{resource, metric, bucket}, count, sum, max} (record/4
      # insert shape); flatten to the {r, m, b} key face for bucketing.
      # r is the downcased resource id (nothing after it) — exact downcased
      # equality, not a pipe-continuation prefix (BK-MON3-F1,
      # bkmon3r-deadjoin-fix: the "|" idiom belongs to Smalt.Metrics'
      # string-keyed table).
      |> Enum.flat_map(fn
        {{r, m, b}, _c, _s, _mx}
        when b + @minute > start_ms and b <= end_ms + @minute ->
          if r == wanted and m == metric, do: [{r, m, b}], else: []

        _row_out_of_window ->
          []
      end)
      |> Enum.group_by(fn {_r, _m, b} -> b - rem(b, interval) end)

    # Dense zero-fill over the requested interval grid.
    first_bucket = start_ms - rem(start_ms, interval)

    data =
      first_bucket
      |> Stream.iterate(&(&1 + interval))
      |> Enum.take_while(&(&1 <= end_ms))
      |> Enum.map(fn bucket ->
        case Map.get(rows, bucket) do
          nil ->
            %{"timeStamp" => iso8601(bucket)}

          keys ->
            {c, s, mx} =
              Enum.reduce(keys, {0, 0, 0}, fn k, {c, s, mx} ->
                case :ets.lookup(@table, k) do
                  [{_, rc, rs, rm}] -> {c + rc, s + rs, max(mx, rm)}
                  _ -> {c, s, mx}
                end
              end)

            %{
              "timeStamp" => iso8601(bucket),
              "total" => s,
              "average" => if(c > 0, do: s / c, else: 0.0),
              "maximum" => mx
            }
        end
      end)

    unit = if metric == "RequestDuration", do: "MilliSeconds", else: "Count"

    %{
      "name" => %{"value" => metric, "localizedValue" => metric},
      "unit" => unit,
      "timeseries" => [%{"data" => data}]
    }
  end

  @doc """
  Test/observation hook: all raw per-minute rows as
  `%{{resource, metric, bucket} => {count, sum, max}}`.
  """
  @spec raw_rows() :: %{{String.t(), String.t(), integer()} => {integer(), number(), number()}}
  def raw_rows do
    @table
    |> table_rows()
    |> Map.new(fn {{r, m, b}, c, s, mx} -> {{r, m, b}, {c, s, mx}} end)
  end

  # -- telemetry handler ---------------------------------------------------------

  @doc """
  Attached `:telemetry` handler. Unguarded by design (the `:telemetry`
  library isolates handler failures from emitters — same failure law as
  `Smalt.Telemetry.handle_event/4`).

  `[:bandit, :request, :stop]` → attributes `Requests` + `RequestDuration`
  to the ARM resource parsed from the request path (platform pseudo-resource
  otherwise). `[:smalt, :egress, :refused]` and
  `[:smalt, :sentinel, :retention_sweep]` land on the platform
  pseudo-resource; the sweep's `dropped`/`kept` measurements seed
  `SentinelDropped`/`SentinelKept` totals.
  """
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:bandit, :request, :stop], measurements, metadata, _config) do
    duration_ms =
      Map.get(measurements, :duration, 0)
      |> System.convert_time_unit(:native, :millisecond)

    conn = Map.get(metadata, :conn)
    path = if conn, do: Map.get(conn, :request_path), else: nil
    ts = now_ms()

    resource = resource_from_path(path) || @platform_resource

    record(resource, "Requests", 1.0, ts)
    record(resource, "RequestDuration", duration_ms * 1.0, ts)
    :ok
  end

  def handle_event([:smalt, :egress, :refused], _measurements, _metadata, _config) do
    record(@platform_resource, "EgressRefused", 1.0, now_ms())
    :ok
  end

  def handle_event([:smalt, :sentinel, :retention_sweep], measurements, _metadata, _config) do
    ts = now_ms()
    record(@platform_resource, "SentinelDropped", Map.get(measurements, :dropped, 0) * 1.0, ts)
    record(@platform_resource, "SentinelKept", Map.get(measurements, :kept, 0) * 1.0, ts)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # -- internals -----------------------------------------------------------------

  defp record(resource, metric, value, ts) do
    bucket = ts - rem(ts, @minute)
    key = {String.downcase(resource), metric, bucket}

    try do
      case :ets.lookup(@table, key) do
        [] ->
          # insert_new: two concurrent first-hits for the same bucket — one
          # wins, the loser falls through to update (never double-insert).
          case :ets.insert_new(@table, {key, 1, value, value}) do
            true -> :ok
            false -> merge(key, value)
          end

        [{_, _c, _s, _m}] ->
          merge(key, value)
      end
    rescue
      # Post-boot table loss must never kill a request process (log-and-drop,
      # same law as RollingCounters post-boot).
      ArgumentError ->
        require Logger

        Logger.warning(
          "Monitor.Metrics table missing post-boot; dropping metric sample " <>
            "(resource=#{resource} metric=#{metric})"
        )

        :ok
    end
  end

  defp merge(key, value) do
    # Read-modify-write (max is not expressible as an update_counter op).
    # Contention window is one row per {resource, metric, minute}; at
    # emulator scale a lost update here is bounded to a single sample of
    # max/count drift and self-corrects next sample — documented, not
    # hidden.
    try do
      case :ets.lookup(@table, key) do
        [{_, c, s, m}] ->
          :ets.insert(@table, {key, c + 1, s + value, max(m, value)})

        [] ->
          case :ets.insert_new(@table, {key, 1, value, value}) do
            true -> :ok
            false -> merge(key, value)
          end
      end

      :ok
    rescue
      # Same log-and-drop law as record/4 — never silent (BK-ARM4).
      ArgumentError ->
        require Logger

        Logger.warning(
          "Monitor.Metrics table missing post-boot; dropping merged sample " <>
            "(resource=#{elem(key, 0)} metric=#{elem(key, 1)})"
        )

        :ok
    end
  end

  # ARM resource-id parse: /subscriptions/{s}/resourceGroups/{rg}/providers/{ns}/{type}/{name}
  # (case-insensitive; "resourcegroups" accepted). Returns the canonical
  # ARM id string, or nil when the path is not an ARM resource path.
  @spec resource_from_path(String.t() | nil) :: String.t() | nil
  defp resource_from_path(path) when is_binary(path) do
    case Regex.run(
          ~r"^/subscriptions/([^/]+)/resource[gG]roups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)(?:/|$)"i,
           path,
           capture: :all_but_first
         ) do
      [s, rg, ns, type, name] ->
        "/subscriptions/#{s}/resourceGroups/#{rg}/providers/#{ns}/#{type}/#{name}"

      _ ->
        nil
    end
  end

  defp resource_from_path(_), do: nil

  defp table_rows(table) do
    try do
      :ets.tab2list(table)
    rescue
      ArgumentError -> []
    end
  end

  @spec iso8601(integer()) :: String.t()
  defp iso8601(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp now_ms, do: System.system_time(:millisecond)

  # -- GenServer: table ownership + prune tick -----------------------------------

  @impl true
  def init(_opts) do
    # 3-tuple :heir form (keyword form raises ArgumentError) — table survives
    # GenServer death, owned by init: the v26.10.19 silent-disarm fix class.
    # BK-33 (warm-restart rebind defect): heir-to-init also survives
    # System.restart/0 (init persists; the table transfers to <0.0.0> at the
    # old owner's death), so an unguarded :ets.new here crashed the restarted
    # app with "table name already exists" and the VM halted with zero
    # listeners rebound. Delete the stale table before re-creating.
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table)
    end

    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        {:heir, Process.whereis(:init), []}
      ])

    :telemetry.attach_many(
      @handler_id,
      Enum.map(@events, &elem(&1, 0)),
      &__MODULE__.handle_event/4,
      :none
    )

    schedule_prune()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now_ms() - @retention_ms

    for {{_r, _m, b}, _c, _s, _mx} = row <- table_rows(@table), b < cutoff do
      try do
        :ets.delete(@table, elem(row, 0))
      rescue
        ArgumentError -> :ok
      end
    end

    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @retention_ms)

  # -- compile-time event audit --------------------------------------------------

  @doc "Telemetry events the accumulator is wired to (audit/dump face)."
  @spec events() :: [[atom()]]
  def events do
    Enum.map(@events, fn {name, _} -> name end)
  end
end
