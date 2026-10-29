defmodule Smalt.Monitor.ActivityLog do
  @moduledoc """
  Azure Activity Log face over smalt's REAL telemetry stream (wave-6 lane w6ad).

  Attaches a `:telemetry` handler to the events smalt actually emits today —
  `[:smalt, :admit]/[:smalt, :refuse]` (metadata whitelist
  `[:event, :verdict, :code, :route]`, Smalt.Telemetry matter-isolation law),
  `[:smalt, :egress, :refused]`, `[:smalt, :cosmos, :analytical_sweep]`,
  `[:smalt, :event_grid, :dead_lettered]`, `[:smalt, :sentinel, :retention_sweep]` —
  plus the CONTRACTED ARM-mutation events
  `[:smalt, :arm, :resource, :write]` / `[:smalt, :arm, :resource, :delete]`
  (`%{resource_id, resource_provider, resource_type, caller, status}`), which the
  post-split router may emit per the staged router patch (see below). Nothing is
  invented: every name in `events/0` either exists in lib/ today (grep
  `:telemetry.execute`: egress_router, cosmos, event_grid, sentinel) or is the
  documented contract the post-split router emits.

  Each observed event becomes a ring record:
      %{event_timestamp: DateTime, event: [atom], resource_id: String | nil,
        operation_name: String, status: atom | integer | nil, caller: String | nil}

  in the `:smalt_activity_log` ETS ring (ordered_set, 5k cap, `:heir` 3-tuple to
  init). `list/1` filters (timeRange/resourceId/operationName, most-recent-first);
  `activity_log_result/1` renders the Azure wire shape. Handler unguarded by design
  (the `:telemetry` dispatcher isolates handler failures, same law as Smalt.Telemetry).

  ## Router patch (staged, post-split — ROUTER HOLD)

      # draft only — w6R owns egress_router.ex / arm_gateway/router.ex
      :telemetry.execute([:smalt, :arm, :resource, :write], %{count: 1}, %{
        resource_id: conn.request_path,
        resource_provider: "Microsoft.Authorization",
        resource_type: "policyDefinitions",
        caller: caller_from_auth(conn),
        status: conn.status
      })

  ## Witness replay

      MIX_BUILD_ROOT=_build-lane-w6ad mix run --no-start tmp/w6ad_witness.exs
  """

  @ring :smalt_activity_log
  @cap 5_000

  @existing_events [
    [:smalt, :admit],
    [:smalt, :refuse],
    [:smalt, :egress, :refused],
    [:cosmos_sweep, :smalt, :cosmos, :analytical_sweep] |> tl(),
    [:smalt, :event_grid, :dead_lettered],
    [:smalt, :sentinel, :retention_sweep]
  ]
  @arm_events [
    [:smalt, :arm, :resource, :write],
    [:smalt, :arm, :resource, :delete]
  ]
  @events (@existing_events ++ @arm_events) |> Enum.uniq()

  @doc "Events the handler observes (real emitters + contracted ARM events)."
  def events, do: @events

  @doc "Ring table name (census/witness use)."
  def ring_table, do: @ring

  @doc "Ring capacity."
  def cap, do: @cap

  @doc "Attach the activity-log handler (idempotent)."
  @spec attach() :: :ok
  def attach do
    ensure_ring()

    case :telemetry.attach_many(
           "smalt-activity-log",
           @events,
           &__MODULE__.handle_event/4,
           :ok
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Observed event → ring record (public for testability)."
  @spec handle_event([atom(), ...], map(), map(), term()) :: map()
  def handle_event(event, measurements, metadata, _config) do
    rec = %{
      event_timestamp: DateTime.utc_now(),
      event: event,
      resource_id: resource_id(event, metadata),
      operation_name: operation_name(event, metadata),
      status: status_of(event, metadata, measurements),
      caller: metadata[:caller]
    }

    push(rec)
    rec
  end

  @doc """
  Query: `list(%{time_range: {from, to} | nil, resource_id: s | nil,
  operation_name: s | nil})`. Most-recent-first.
  """
  @spec list(map()) :: [map()]
  def list(opts \\ %{}) do
    ensure_ring()

    {from, to} =
      case opts[:time_range] do
        {f, t} -> {f, t}
        _ -> {nil, nil}
      end

    :ets.tab2list(@ring)
    |> Enum.map(fn {_k, rec} -> rec end)
    |> Enum.sort_by(& &1.event_timestamp, {:desc, DateTime})
    |> Enum.filter(fn r ->
      time_ok =
        cond do
          from && to ->
            DateTime.compare(r.event_timestamp, from) != :lt and
              DateTime.compare(r.event_timestamp, to) != :gt

          from ->
            DateTime.compare(r.event_timestamp, from) != :lt

          true ->
            true
        end

      rid_ok =
        case opts[:resource_id] do
          nil -> true
          rid when is_binary(rid) -> is_binary(r.resource_id) and String.contains?(r.resource_id, rid)
          _ -> true
        end

      op_ok =
        case opts[:operation_name] do
          nil -> true
          op when is_binary(op) -> r.operation_name == op
          _ -> true
        end

      time_ok and rid_ok and op_ok
    end)
  end

  @doc "Number of records in the ring."
  @spec count() :: non_neg_integer()
  def count do
    ensure_ring()
    :ets.info(@ring, :size)
  end

  @doc "Azure wire shape for a record list."
  @spec activity_log_result([map()]) :: map()
  def activity_log_result(recs) do
    %{
      "value" =>
        Enum.map(recs, fn r ->
          %{
            "eventTimestamp" => DateTime.to_iso8601(r.event_timestamp),
            "id" => r.resource_id,
            "operationName" =>
              case r.operation_name do
                "smalt.arm.resource.write" -> "Microsoft.Resources/smalt/write"
                "smalt.arm.resource.delete" -> "Microsoft.Resources/smalt/delete"
                "smalt." <> rest -> "Microsoft.Smalt/" <> rest
                other -> other
              end,
            "status" =>
              case r.status do
                nil -> "Succeeded"
                s -> to_string(s)
              end
          }
        end),
      "nextLink" => nil
    }
  end

  @doc "Real-dispatcher emit helper (witness path uses this, never a mock)."
  def execute_event(event, measurements, metadata), do: :telemetry.execute(event, measurements, metadata)

  defp resource_id([:smalt, :admit] ++ _, m), do: route_id(m)
  defp resource_id([:smalt, :refuse] ++ _, m), do: route_id(m)
  defp resource_id([:smalt, :egress, :refused], m), do: m[:url]
  defp resource_id([:smalt, :cosmos, :analytical_sweep], m),
    do: if(m[:db] && m[:coll], do: "/dbs/#{m[:db]}/colls/#{m[:coll]}")
  defp resource_id([:smalt, :event_grid, :dead_lettered], m),
    do: if(m[:account] && m[:container] && m[:blob], do: "/blob/#{m[:account]}/#{m[:container]}/#{m[:blob]}")
  defp resource_id([:smalt, :sentinel, :retention_sweep], m),
    do: if(m[:dcr] && m[:stream], do: "/sentinel/#{m[:dcr]}/#{m[:stream]}")
  defp resource_id([:smalt, :arm, :resource, _], m), do: m[:resource_id]
  defp resource_id(_, _), do: nil

  defp route_id(m) do
    case m[:route] do
      r when is_binary(r) -> r
      _ -> nil
      end
  end

  defp operation_name([:smalt, :arm, :resource, kind], m) do
    ns = m[:resource_provider] || "Microsoft.Resources"
    type = m[:resource_type] || "smalt"
    verb = if kind == :write, do: "write", else: "delete"
    "#{ns}/#{type}/#{verb}"
  end

  defp operation_name(event, _m), do: Enum.join(Enum.map(event, &to_string/1), ".")

  defp status_of([:smalt, :refuse], m, _), do: m[:code] || :refused
  defp status_of([:smalt, :admit], m, _), do: m[:verdict] || :admitted
  defp status_of([:smalt, :egress, :refused], m, _), do: m[:reason]
  defp status_of([:smalt, :cosmos, :analytical_sweep], _m, meas), do: meas[:expired]
  defp status_of([:smalt, :sentinel, :retention_sweep], _m, meas), do: meas[:dropped]
  defp status_of([:smalt, :arm, :resource, _], m, _), do: m[:status]
  defp status_of(_, _, _), do: nil

  defp push(rec) do
    ensure_ring()
    k = :erlang.unique_integer([:positive, :monotonic])
    :ets.insert(@ring, {k, rec})

    if :ets.info(@ring, :size) > @cap do
      first = :ets.first(@ring)
      if first != :"$end_of_table", do: :ets.delete(@ring, first)
      :ok
    else
      :ok
    end
  end

  defp ensure_ring do
    case :ets.info(@ring) do
      :undefined ->
        :ets.new(@ring, [
          :named_table,
          :ordered_set,
          :public, {:heir, Process.whereis(:init), []}, {:read_concurrency, true}
        ])
        :ok

      _ ->
        :ok
    end
  end
end
