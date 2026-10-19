defmodule Smalt.Health do
  @moduledoc """
  Phase-4 adaptive readiness/liveness probes (milestone v26.10.19).

  The ARD's point: probes must NOT fail under high compute saturation.
  Readiness degrades ONLY on structural failure (Store down / tables missing /
  memory past bounds); scheduler load is reported as metrics, never fatal.
  Liveness is process/scheduler-only and never fails on load.

  Bounds are read via `Application.get_env(:smalt, Smalt.Health)` (config.ex is
  a generated file — bounds are configured in runtime config, not by editing
  the generated module). Defaults:

      config :smalt, Smalt.Health,
        ets_memory_high_water_bytes: 512 * 1024 * 1024,
        probes_memory_high_water_bytes: 2 * 1024 * 1024 * 1024
  """

  @defaults [
    ets_memory_high_water_bytes: 512 * 1024 * 1024,
    processes_memory_high_water_bytes: 2 * 1024 * 1024 * 1024
  ]

  @typedoc "Aggregate verdict: ready | degraded."
  @type status :: :ready | :degraded

  @doc "Full readiness check. `{:ready, checks}` | `{:degraded, checks}`."
  @spec readiness() :: {status(), map()}
  def readiness do
    checks = %{
      scheduler: scheduler_capacity(),
      store: store_integrity(),
      memory: memory_high_water(),
      cluster: cluster_status()
    }

    # Structural failures only: store/tables/memory bounds. Scheduler load and
    # cluster-disabled are metrics, not verdicts (adaptive-probe law).
    degraded? =
      checks.store != :ok or checks.memory != :ok or
        match?(%{verdict: :degraded}, checks.cluster)

    if degraded?, do: {:degraded, checks}, else: {:ready, checks}
  end

  @doc "Liveness check — process/scheduler-only, never fails on load."
  @spec liveness() :: :alive
  def liveness, do: :alive

  @doc """
  Scheduler reduction capacity (non-blocking). If `:scheduler_wall_time` is
  enabled, utilization is measured over a bounded 100 ms window; otherwise
  per-scheduler run-queue lengths (`:erlang.statistics(:run_queue)`) are
  reported. Load is METRIC output, never a verdict input.
  """
  @spec scheduler_capacity() :: map()
  def scheduler_capacity do
    schedulers = :erlang.system_info(:schedulers_online)

    case :erlang.statistics(:scheduler_wall_time) do
      t0 when is_list(t0) ->
        t1 = sample_after_window(t0)

        util = scheduler_utilization(t0, t1)

        %{
          schedulers_online: schedulers,
          mode: :scheduler_wall_time,
          total_utilization: total_utilization(util),
          per_scheduler: util
        }

      _disabled ->
        # scheduler_wall_time not enabled — non-invasive fallback: report
        # run-queue lengths. We do NOT flip the VM-wide system_flag here.
        run_queues = :erlang.statistics(:run_queue)

        %{
          schedulers_online: schedulers,
          mode: :run_queue,
          total_run_queue: run_queues,
          per_scheduler_avg: run_queues / max(schedulers, 1)
        }

      t0 ->
        t1 = sample_after_window(t0)

        util = scheduler_utilization(t0, t1)

        %{
          schedulers_online: schedulers,
          mode: :scheduler_wall_time,
          total_utilization: total_utilization(util),
          per_scheduler: util
        }
    end
  end

  # Bounded scheduler_wall_time sampling window (measurement interval, not
  # coordination; the runtime schedules the process away while counters
  # accumulate).
  defp sample_after_window(_t0) do
    # SLEEP-CLASS: SCHEDULING — measurement interval, not coordination
    Process.sleep(100)
    :erlang.statistics(:scheduler_wall_time)
  end

  defp scheduler_utilization(t0, t1) do
    for {id0, act0, tot0} <- t0,
        {id, act1, tot1} <- t1,
        id == id0,
        tot1 > tot0 do
      {id, Float.round((act1 - act0) / (tot1 - tot0), 4)}
    end
    |> Enum.sort()
  end

  defp total_utilization([]), do: nil

  defp total_utilization(util) do
    (Enum.sum(Enum.map(util, fn {_, act} -> act end)) / length(util))
    |> Float.round(4)
  end

  @doc "State-engine integrity: Store alive + presence of every StoreTables table."
  @spec store_integrity() :: :ok | {:error, term()}
  def store_integrity do
    with :ok <- store_alive?(),
         :ok <- tables_present?() do
      :ok
    end
  end

  defp store_alive? do
    case Process.whereis(Smalt.Store) do
      nil -> {:error, :store_not_alive}
      pid -> if Process.alive?(pid), do: :ok, else: {:error, :store_dead}
    end
  end

  defp tables_present? do
    missing = Enum.filter(Smalt.StoreTables.table_names(), fn t -> :ets.info(t) == :undefined end)

    case missing do
      [] -> :ok
      _ -> {:error, {:tables_missing, missing}}
    end
  end

  @doc """
  Memory high-water: `:erlang.memory(:ets)` and `(:processes)` vs configured
  bounds (Application env `:smalt, Smalt.Health`). Exceeding a bound is
  STRUCTURAL degradation, not load.
  """
  @spec memory_high_water() :: :ok | {:error, term()}
  def memory_high_water do
    bounds = get_bounds()

    ets = :erlang.memory(:ets)
    procs = :erlang.memory(:processes)

    cond do
      ets > bounds.ets ->
        {:error, {:ets_memory_over_high_water, ets, bounds.ets}}

      procs > bounds.processes ->
        {:error, {:processes_memory_over_high_water, procs, bounds.processes}}

      true ->
        :ok
    end
  end

  defp get_bounds do
    cfg = Application.get_env(:smalt, __MODULE__, [])

    %{
      ets: cfg[:ets_memory_high_water_bytes] || @defaults[:ets_memory_high_water_bytes],
      processes:
        cfg[:processes_memory_high_water_bytes] || @defaults[:processes_memory_high_water_bytes]
    }
  end

  @doc """
  Cluster status — `Smalt.Cluster.cluster_status/0` when the module exists,
  otherwise `%{enabled: false}` (metric, non-fatal).
  """
  @spec cluster_status() :: map()
  def cluster_status do
    if Code.ensure_loaded?(Smalt.Cluster) do
      Smalt.Cluster.cluster_status()
    else
      %{enabled: false}
    end
  end

  @doc "Render a readiness tuple as a JSON-ready map: %{\"status\" => ..., \"checks\" => ...}"
  @spec to_json_map({status(), map()}) :: %{:status => String.t(), optional(atom()) => map()}
  def to_json_map({status, checks}) do
    %{status: to_string(status), checks: serialize_checks(checks)}
  end

  defp serialize_checks(%{} = m) do
    Map.new(m, fn
      {k, :ok} -> {k, "ok"}
      {k, {:error, reason}} -> {k, %{error: inspect(reason)}}
      {k, v} when is_map(v) -> {k, v}
    end)
  end

  @doc "HTTP status for a readiness tuple: 200 ready / 503 degraded."
  @spec http_status({status(), map()}) :: integer()
  def http_status({:ready, _}), do: 200
  def http_status({:degraded, _}), do: 503
end
