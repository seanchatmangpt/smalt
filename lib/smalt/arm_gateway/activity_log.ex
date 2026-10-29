defmodule Smalt.ArmGateway.ActivityLog do
  @moduledoc """
  ARM control-plane activity log (AZURE-FIDELITY lane 5).

  Every successful generic-resource mutation (PUT/PATCH/DELETE through
  `Smalt.ArmGateway.Router`) records one activity-log event into a
  lightweight ETS ring (`:smalt_arm_activity_log`, ordered_set, 5k cap,
  heir to :init — same ring law as `Smalt.Monitor.ActivityLog`), and
  re-emits the CONTRACTED `[:smalt, :arm, :resource, :write|:delete]`
  telemetry events so `Smalt.Monitor.ActivityLog`'s ring is fed too
  (the w6ad "staged router patch" emitter side, now landed).

  The Azure face is served by the router route
  `GET /subscriptions/{sub}/providers/microsoft.insights/eventtypes/management/values`
  (`handle_query/3`), whose event schema is the documented
  microsoft.insights eventtypes/management shape:

      eventDataId, operationName{value,localizedValue}, caller,
      eventTimestamp, submissionTimestamp, resourceId, status{value,...},
      correlationId, level, operationId, resourceProvider, resourceGroup

  `$filter` grammar subset supported (and-combined):
  `eventTimestamp ge/le '<iso>'`, `resourceId eq '<id>'`,
  `operationName eq '<name>'`.

  Fail-safe law (KD-124 POST-STORE SIDEBAND class): `record/4` never
  raises into the mutation path — any failure is logged and dropped, the
  mutation response is never altered.
  """

  require Logger

  @ring :smalt_arm_activity_log
  @cap 5_000
  @supported_api_versions ["2015-04-01"]

  @typedoc "Mutation action: a control-plane write or a delete."
  @type action :: :write | :delete

  # -- record (hook side, called from the router mutation paths) ---------------

  @doc """
  Records one Succeeded activity-log event for a completed mutation.
  `caller` is the bearer JWT's `appid` claim (decoded from the request's
  Authorization header, fail-safe — verified upstream by the Bearer plug);
  `correlation_id` is the request's `x-ms-request-id` when present (the
  router stashes it at `conn.private[:arm_request_id]`), else a fresh
  UUID. Also emits the contracted `[:smalt, :arm, :resource, ...]`
  telemetry. Returns the record; never raises.
  """
  @spec record(Plug.Conn.t(), action(), String.t(), String.t()) :: map()
  def record(conn, action, resource_id, resource_group) do
    record =
      %{
        event_data_id: generate_uuid(),
        operation_name: operation_name(resource_id, action),
        caller: caller_from_conn(conn),
        event_timestamp: DateTime.utc_now(),
        submission_timestamp: DateTime.utc_now(),
        resource_id: resource_id,
        resource_group: resource_group,
        status: "Succeeded",
        correlation_id: correlation_id(conn),
        operation_id: generate_uuid(),
        level: "Informational"
      }

    push(record)
    emit_telemetry(record, action)
    record
  rescue
    e ->
      Logger.warning(
        "Smalt.ArmGateway.ActivityLog: record dropped (fail-safe): #{Exception.message(e)}"
      )

      %{}
  end

  @doc "Caller extraction: `appid` claim of the request's bearer JWT, else nil."
  @spec caller_from_conn(Plug.Conn.t()) :: String.t() | nil
  def caller_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        appid_from_jwt(token)

      [token] when is_binary(token) and token != "" ->
        appid_from_jwt(token)

      _ ->
        nil
    end
  end

  defp appid_from_jwt(token) do
    case String.split(token, ".") do
      [_h, payload, _s | _] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, %{"appid" => appid}} when is_binary(appid) and appid != "" -> appid
              _ -> nil
            end

          :error ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp correlation_id(conn) do
    case conn.private[:arm_request_id] do
      id when is_binary(id) and id != "" -> id
      _ -> generate_uuid()
    end
  end

  # operation_name from the resource id: the last /providers/NS/TYPE/NAME
  # segment pair, e.g. "/subscriptions/s/resourceGroups/r/providers/
  # Microsoft.Storage/storageAccounts/acct" -> "Microsoft.Storage/storageAccounts/write".
  defp operation_name(resource_id, action) when is_binary(resource_id) do
    case split_providers(resource_id) do
      [ns, type] ->
        verb = if action == :delete, do: "delete", else: "write"
        "#{ns}/#{type}/#{verb}"

      _ ->
        rg_or_default(resource_id, action)
    end
  end

# An RG id carries no /providers/ segment (".../resourceGroups/{name}") — the
# documented operationName for a resource-group write is
# Microsoft.Resources/resourceGroups/{verb} (V7 lane). Everything else without
# a provider segment keeps the Microsoft.Resources/resource fallback.
  defp rg_or_default(resource_id, action) do
    verb = if action == :delete, do: "delete", else: "write"

    if resource_id =~ ~r{/resourcegroups?/}i do
      "Microsoft.Resources/resourceGroups/#{verb}"
    else
      "Microsoft.Resources/resource/#{verb}"
    end
  end

  defp split_providers(resource_id) do
    case String.split(resource_id, "/providers/", parts: 2) do
      [_head, rest] ->
        case String.split(rest, "/", parts: 3) do
          [ns, type | _] -> [ns, type]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # -- query (Azure face) -------------------------------------------------------

  @doc """
  Serves `GET .../providers/microsoft.insights/eventtypes/management/values`.
  Parses the documented `$filter` subset, renders the Azure envelope.
  Returns `{:ok, status, body_json}`.
  """
  @spec handle_query(Plug.Conn.t(), String.t()) :: {:ok, pos_integer(), String.t()}
  def handle_query(conn, _sub_id) do
    api_version = conn.query_params["api-version"]

    if is_binary(api_version) and api_version in @supported_api_versions do
      filter = parse_filter(conn.query_params["$filter"] || conn.query_params["$filter"])

      events =
        list_records()
        |> Enum.filter(&matches?(filter, &1))
        |> Enum.map(&render_event/1)

      {:ok, 200, Jason.encode!(%{"value" => events, "nextLink" => nil})}
    else
      {:ok, 400,
       Jason.encode!(%{
         error: %{
           code: "InvalidApiVersionParameter",
           message:
             "The api-version '#{api_version}' is invalid. The supported api-version for 'microsoft.insights/eventtypes' is '#{@supported_api_versions |> hd()}'"
         }
       })}
    end
  end

  @doc "All records, most-recent-first."
  @spec list_records() :: [map()]
  def list_records do
    ensure_ring()

    :ets.tab2list(@ring)
    |> Enum.map(fn {_k, rec} -> rec end)
    |> Enum.sort_by(& &1.event_timestamp, {:desc, DateTime})
  end

  @doc "Number of records (witness/census use)."
  @spec count() :: non_neg_integer()
  def count do
    ensure_ring()
    :ets.info(@ring, :size)
  end

  @doc "Test/census reset: drops every record. Returns the prior count."
  @spec reset() :: non_neg_integer()
  def reset do
    ensure_ring()
    n = :ets.info(@ring, :size)

    if n > 0, do: :ets.delete_all_objects(@ring)

    n
  end

  # -- $filter subset (documented grammar) --------------------------------------

  defp parse_filter(nil), do: %{}
  defp parse_filter(""), do: %{}

  defp parse_filter(filter) when is_binary(filter) do
    filter
    |> String.split(" and ")
    |> Enum.reduce(%{}, fn clause, acc ->
      case parse_clause(String.trim(clause)) do
        nil -> acc
        {key, op, value} -> Map.put(acc, key, {op, value})
      end
    end)
  end

  defp parse_clause(clause) do
    case String.split(clause, " ", parts: 3) do
      [field, op, value] ->
        value = value |> String.trim("\"") |> String.trim("'")
        {String.downcase(field), String.downcase(op), value}

      _ ->
        nil
    end
  end

  defp matches?(filter, rec) do
    Enum.all?(filter, fn
      {"eventtimestamp", {"ge", iso}} -> timestamp_cmp(rec.event_timestamp, iso) != :lt
      {"eventtimestamp", {"le", iso}} -> timestamp_cmp(rec.event_timestamp, iso) != :gt
      {"resourceid", {"eq", rid}} ->
        is_binary(rec.resource_id) and String.downcase(rec.resource_id) == String.downcase(rid)

      {"operationname", {"eq", op}} ->
        String.downcase(rec.operation_name) == String.downcase(op)

      {_, {_, _}} ->
        false
    end)
  end

  defp timestamp_cmp(rec_ts, iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.compare(rec_ts, dt)
      {:error, _} -> :lt
    end
  end

  # -- Azure wire shape ----------------------------------------------------------

  defp render_event(rec) do
    %{
      "eventDataId" => rec.event_data_id,
      "operationName" => localize(rec.operation_name),
      "caller" => rec.caller,
      "eventTimestamp" => DateTime.to_iso8601(rec.event_timestamp),
      "submissionTimestamp" => DateTime.to_iso8601(rec.submission_timestamp),
      "resourceId" => rec.resource_id,
      "resourceGroup" => rec.resource_group,
      "status" => localize(rec.status),
      "correlationId" => rec.correlation_id,
      "operationId" => rec.operation_id,
      "level" => rec.level,
      "resourceProvider" => rec |> operation_provider() |> localize()
    }
  end

  defp localize(v), do: %{"value" => v, "localizedValue" => v}

  defp operation_provider(rec) do
    case String.split(rec.operation_name, "/") do
      [ns, _type, _verb] -> ns
      _ -> "Microsoft.Resources"
    end
  end

  # -- ring -----------------------------------------------------------------------

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
          :public,
          {:heir, Process.whereis(:init), []},
          {:read_concurrency, true}
        ])

        :ok

      _ ->
        :ok
    end
  end

  defp emit_telemetry(rec, action) do
    kind = if action == :delete, do: :delete, else: :write

    {ns, type} =
      case String.split(rec.operation_name, "/") do
        [ns, type, _verb] -> {ns, type}
        _ -> {"Microsoft.Resources", "resource"}
      end

    :telemetry.execute(
      [:smalt, :arm, :resource, kind],
      %{count: 1},
      %{
        resource_id: rec.resource_id,
        resource_provider: ns,
        resource_type: type,
        caller: rec.caller,
        status: rec.status
      }
    )

    :ok
  end

  defp generate_uuid do
    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> =
      :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.map(&Base.encode16(&1, case: :lower))
    |> Enum.join("-")
  end
end
