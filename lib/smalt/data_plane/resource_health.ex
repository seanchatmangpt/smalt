defmodule Smalt.DataPlane.ResourceHealth do
  @moduledoc """
  T-14 engine for `Microsoft.ResourceHealth` — availability statuses +
  service-health events with a chaos-coupled incident lifecycle.

  ## State law

  Every availability record is keyed by the DOWNCASED resource id in the
  `:smalt_resource_health` ETS shadow table (lazy `:ets.new`, `:heir` to
  `:init` — the same shadow-table law `Smalt.Arm.ResourceHealth` and
  `Smalt.Telemetry.RollingCounters` follow; the table survives its creator
  and needs no supervisor child). Event rows live in the same table under
  `{:event, event_id}` keys.

  Read precedence for `status/1` (first match wins):

  1. an explicit transition record (`set_unavailable/2` / `set_available/1`)
     — the explicit API is the PRIMARY chaos coupling for the integration
     tier (T-12's injector flags call it; smalt never edits T-12's files),
  2. the documented chaos marker: the app-env key
     `config :smalt, :resource_health_unavailable` naming resource ids
     (list of id strings, or a map `%{id => reason}`) — derived-on-read,
     no restart required, never persisted,
  3. Store presence in `:smalt_resources` — a provisioned resource is
     `Available` by default (synthetic-Available law, same vocabulary as
     `Smalt.Arm.ResourceHealth`: reasonType `EmulatorSynthetic`, epoch
     `occurredTime` — a derived row is not a transition),
  4. otherwise `:error` (the router renders 404 — never a fabricated row).

  Explicit transitions ALWAYS win over the marker (step 1 before 2), so
  `set_available/1` restores a resource even while a marker still names it.

  ## Event lifecycle

  `set_unavailable/2` mints (or refreshes) ONE Active service-health event
  per resource; `set_available/1` resolves it. Each transition is
  timestamped (`occurred_time`/`reported_time`/`event_timestamp`, ISO8601
  UTC) — the poll-based available→unavailable→available receipt needs no
  sleeps, only reads.

  Every explicit transition also emits the raw `:telemetry` event
  `[:smalt, :resource_health, :availability]` with metadata `%{state: ...,
  reason: ...}` — codes only, never resource ids (the matter-isolation law
  of `Smalt.Telemetry`). This is the alerting hook: production alert code
  parses the events wire shape below; local tooling can attach to the
  telemetry name.

  ## Marker details

  `:resource_health_unavailable` accepts a list of resource-id binaries or
  a map of `%{resource_id => reason}` (reason = code binary or
  `%{"reasonCode" => ..., "summary" => ...}`). Matching is downcased-exact.
  Marker-derived Unavailable rows carry a read-instant `occurred_time` and
  a derived Active event with a DETERMINISTIC id (`chaos-<sha256-8>`), so
  repeated polls observe the same event id while the flag is up.
  """

  @table :smalt_resource_health

  @epoch "1970-01-01T00:00:00Z"
  @default_reason "CustomerInitiated"
  @default_subscription "00000000-0000-0000-0000-000000000000"

  @transition_event [:smalt, :resource_health, :availability]

  @type availability_record :: %{
          required("resource_id") => String.t(),
          required("resource_id_display") => String.t(),
          required("state") => String.t(),
          required("reason_code") => String.t(),
          required("summary") => String.t(),
          required("occurred_time") => String.t(),
          required("reported_time") => String.t()
        }

  @type event_record :: %{
          required("id") => String.t(),
          required("resource_id") => String.t(),
          required("resource_id_display") => String.t(),
          required("level") => String.t(),
          required("status") => String.t(),
          required("event_timestamp") => String.t(),
          required("title") => String.t(),
          required("summary") => String.t(),
          required("reason_code") => String.t()
        }

  # -- explicit transitions (the primary chaos coupling) -----------------------

  @doc """
  Marks `resource_id` Unavailable with a real reason code
  (`CustomerInitiated` | `PlatformInitiated` | `HighAvailability` |
  `Unplanned` classes; any binary accepted, nil -> #{@default_reason}).

  `reason` may be a binary code, or a map/keyword carrying
  `"reasonCode"`/`:reason_code` and optional `"summary"`/`:summary`.

  Persists the availability record, mints-or-refreshes the single Active
  service-health event for the resource, emits the transition telemetry,
  and returns `{:ok, availability_record, event_record}`.
  """
  @spec set_unavailable(String.t(), term()) ::
          {:ok, availability_record(), event_record()}
  def set_unavailable(resource_id, reason \\ @default_reason) when is_binary(resource_id) do
    {code, summary} = normalize_reason(reason)
    now = now_iso()

    rec = %{
      "resource_id" => down(resource_id),
      "resource_id_display" => resource_id,
      "state" => "Unavailable",
      "reason_code" => code,
      "summary" => summary || "The resource is unavailable (chaos injection; reason: #{code}).",
      "occurred_time" => now,
      "reported_time" => now
    }

    event_id = active_event_id(resource_id)

    event =
      case lookup_event(event_id) do
        {:ok, existing} ->
          # Repeat injections of the same incident refresh the Active row —
          # one incident, one event, latest evidence timestamped.
          %{existing | "reason_code" => code, "summary" => rec["summary"], "event_timestamp" => now}

        :error ->
          %{
            "id" => mint_event_id(),
            "resource_id" => down(resource_id),
            "resource_id_display" => resource_id,
            "level" => "Warning",
            "status" => "Active",
            "event_timestamp" => now,
            "title" => "Resource unavailable: #{leaf(resource_id)}",
            "summary" => rec["summary"],
            "reason_code" => code
          }
      end

    ensure_table()
    :ets.insert(@table, {{:availability, down(resource_id)}, rec, resource_id})
    :ets.insert(@table, {{:event, event_id}, event, resource_id})

    emit_transition(rec)
    {:ok, rec, event}
  end

  @doc """
  Restores `resource_id` to Available: persists the (timestamped) Available
  record and resolves every Active service-health event for the resource.
  Returns `{:ok, availability_record, event_record | nil}` — nil when there
  was no Active event to resolve.
  """
  @spec set_available(String.t()) :: {:ok, availability_record(), event_record() | nil}
  def set_available(resource_id) when is_binary(resource_id) do
    now = now_iso()

    rec = %{
      "resource_id" => down(resource_id),
      "resource_id_display" => resource_id,
      "state" => "Available",
      "reason_code" => "EmulatorSynthetic",
      "summary" => "Emulated resource is healthy (chaos cleared; synthetic-Available).",
      "occurred_time" => now,
      "reported_time" => now
    }

    ensure_table()
    :ets.insert(@table, {{:availability, down(resource_id)}, rec, resource_id})

    event =
      case lookup_event(active_event_id(resource_id)) do
        {:ok, active} ->
          resolved = %{
            active
            | "status" => "Resolved",
              "level" => "Informational",
              "title" => "Resource availability restored: #{leaf(resource_id)}",
              "event_timestamp" => now
          }

          :ets.insert(@table, {{:event, active["id"]}, resolved, resource_id})
          resolved

        :error ->
          nil
      end

    emit_transition(rec)
    {:ok, rec, event}
  end

  # -- reads -------------------------------------------------------------------

  @doc """
  Full read law (see moduledoc): explicit record -> chaos marker -> Store
  presence -> `:error`. `{:ok, availability_record}` otherwise.
  """
  @spec status(String.t()) :: {:ok, availability_record()} | :error
  def status(resource_id) when is_binary(resource_id) do
    case chaos_status(resource_id) do
      {:ok, rec} -> {:ok, rec}
      :error -> derived_status(resource_id)
    end
  end

  @doc """
    Chaos-owned read: `{:ok, rec}` iff an explicit transition record OR the
  `:resource_health_unavailable` marker covers `resource_id`, else `:error`.
  The ARM pass-through router uses this probe so chaos-free resources keep
  the pre-existing computed-health law (recorded `:smalt_arm_health`
  transitions stay visible) — the engine never shadows that lane.
  """
  @spec chaos_status(String.t()) :: {:ok, availability_record()} | :error
  def chaos_status(resource_id) when is_binary(resource_id) do
    case lookup_availability(resource_id) do
      {:ok, rec} ->
        {:ok, rec}

      :error ->
        case Map.fetch(config_markers(), down(resource_id)) do
          {:ok, reason} -> {:ok, derived_unavailable(resource_id, reason)}
          :error -> :error
        end
    end
  end

  @doc """
  Availability records for every resource whose id carries `scope_prefix`
  (downcased, so RG and subscription prefixes work as-is): Store rows drive
  the default (synthetic-Available) listing, chaos records/markers flip
  their rows, and ids with a record but no Store row are included too (an
  explicit chaos mark is observable). Sorted by id, deterministic.
  """
  @spec list(String.t()) :: [availability_record()]
  def list(scope_prefix) when is_binary(scope_prefix) do
    prefix = down(scope_prefix)

    prefix
    |> scope_ids()
    |> Enum.flat_map(fn id ->
      case status(id) do
        {:ok, rec} -> [{id, rec}]
        :error -> []
      end
    end)
    # sort by display id (the first tuple member) for a stable wire order
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Enum.map(fn {_id, rec} -> rec end)
  end

  @doc """
  Service-health event records whose resource id carries `scope_prefix`
  (downcased), newest first: stored Active/Resolved rows plus derived Active
  rows for `:resource_health_unavailable` markers under the prefix that do
  not already have a stored Active row (no duplicate incidents when the
  explicit API and the marker are both used).
  """
  @spec events(String.t()) :: [event_record()]
  def events(scope_prefix) when is_binary(scope_prefix) do
    prefix = down(scope_prefix)

    stored =
      @table
      |> table_rows()
      |> Enum.filter(fn
        {{:event, _}, _rec, _rid} -> true
        _ -> false
      end)
      |> Enum.map(fn {_k, rec, _rid} -> rec end)
      |> Enum.filter(fn rec -> String.starts_with?(rec["resource_id"], prefix) end)

    derived =
      prefix
      |> marker_ids_under()
      |> Enum.reject(fn id -> Enum.any?(stored, &(&1["resource_id"] == id and &1["status"] == "Active")) end)
      |> Enum.map(&derived_marker_event/1)

    Enum.sort_by(stored ++ derived, & &1["event_timestamp"], :desc)
  end

  # -- wire shapes -------------------------------------------------------------

  @doc """
  Documented availabilityStatus wire shape (same envelope law as the
  V9 `Smalt.ArmGateway.ResourceHealth` seam): id/name/type at top level,
  state vocabulary under `properties`.
  """
  @spec availability_wire(availability_record()) :: map()
  def availability_wire(rec) do
    id = rec["resource_id_display"]

    %{
      "id" => "#{id}/providers/Microsoft.ResourceHealth/availabilityStatuses/current",
      "name" => "#{leaf(id)}/current",
      "type" => "Microsoft.ResourceHealth/availabilityStatuses",
      "properties" => %{
        "availabilityState" => rec["state"],
        "summary" => rec["summary"],
        "reasonType" => rec["reason_code"],
        "occurredTime" => rec["occurred_time"],
        "reportedTime" => rec["reported_time"]
      }
    }
  end

  @doc """
  Documented service-health event wire shape: ARM-shaped id at the
  subscription scope, `properties` carrying the fields alerting code parses
  (status Active/Resolved, level, title, eventTimestamp, reasonCode).
  """
  @spec event_wire(event_record()) :: map()
  def event_wire(rec) do
    %{
      "id" =>
        "/subscriptions/#{subscription_of(rec["resource_id_display"])}/providers/Microsoft.ResourceHealth/events/#{rec["id"]}",
      "name" => rec["id"],
      "type" => "Microsoft.ResourceHealth/events",
      "properties" => %{
        "eventSource" => "ResourceHealth",
        "status" => rec["status"],
        "level" => rec["level"],
        "title" => rec["title"],
        "summary" => rec["summary"],
        "eventTimestamp" => rec["event_timestamp"],
        "reasonCode" => rec["reason_code"],
        "resourceId" => rec["resource_id_display"]
      }
    }
  end

  # -- internals: table law ------------------------------------------------------

  defp ensure_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:heir, Process.whereis(:init), []},
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp table_rows(table) do
    ensure_table()

    case :ets.tab2list(table) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  rescue
    # Post-boot table loss must not kill a request process (same log-free
    # degrade law as the telemetry counters): an empty read is honest.
    ArgumentError -> []
  end

  defp lookup_availability(resource_id) do
    ensure_table()

    case :ets.lookup(@table, {:availability, down(resource_id)}) do
      [{_k, rec, _rid}] when is_map(rec) -> {:ok, rec}
      _ -> :error
    end
  end

  defp lookup_event(event_id) do
    ensure_table()

    case :ets.lookup(@table, {:event, event_id}) do
      [{_k, rec, _rid}] when is_map(rec) -> {:ok, rec}
      _ -> :error
    end
  end

  defp active_event_id(resource_id) do
    "chaos-" <> Base.encode16(binary_part(:crypto.hash(:sha256, down(resource_id)), 0, 8), case: :lower)
  end

  defp mint_event_id do
    @event_bytes = :crypto.strong_rand_bytes(16)
    Base.encode16(@event_bytes, case: :lower)
  end

  # -- internals: read-law derivation -------------------------------------------

  defp derived_status(resource_id) do
    if store_row_exists?(resource_id) do
      {:ok, derived_available(resource_id)}
    else
      :error
    end
  end

  defp store_row_exists?(resource_id) do
    downcased = down(resource_id)

    Smalt.Store.list(:smalt_resources)
    |> Enum.any?(fn row ->
      is_map(row) and is_binary(row["id"]) and down(row["id"]) == downcased
    end)
  rescue
    # Store not booted yet: no row is provable, so no fabricated health.
    ArgumentError -> false
  end

  defp derived_available(resource_id) do
    %{
      "resource_id" => down(resource_id),
      "resource_id_display" => resource_id,
      "state" => "Available",
      "reason_code" => "EmulatorSynthetic",
      "summary" => "Emulated resource is healthy (synthetic-Available).",
      "occurred_time" => @epoch,
      "reported_time" => @epoch
    }
  end

  defp derived_unavailable(resource_id, {code, summary}) do
    now = now_iso()

    %{
      "resource_id" => down(resource_id),
      "resource_id_display" => resource_id,
      "state" => "Unavailable",
      "reason_code" => code,
      "summary" => summary || "The resource is unavailable (:resource_health_unavailable chaos marker; reason: #{code}).",
      "occurred_time" => now,
      "reported_time" => now
    }
  end

  defp derived_marker_event(resource_id) do
    {code, summary} = normalize_reason(marker_reason(resource_id))
    id = active_event_id(resource_id)

    %{
      "id" => id,
      "resource_id" => down(resource_id),
      "resource_id_display" => resource_id,
      "level" => "Warning",
      "status" => "Active",
      "event_timestamp" => now_iso(),
      "title" => "Resource unavailable: #{leaf(resource_id)}",
      "summary" => summary || "The resource is unavailable (:resource_health_unavailable chaos marker; reason: #{code}).",
      "reason_code" => code
    }
  end

  # -- internals: scopes ---------------------------------------------------------

  defp scope_ids(prefix) do
    store_ids =
      Smalt.Store.list(:smalt_resources)
      |> Enum.flat_map(fn row ->
        case row do
          %{"id" => id} when is_binary(id) ->
            if String.starts_with?(down(id), prefix), do: [id], else: []

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(&down/1)

    record_ids =
      @table
      |> table_rows()
      |> Enum.flat_map(fn
        {{:availability, rid}, _rec, display} ->
          if String.starts_with?(rid, prefix), do: [display || rid], else: []

        _ ->
          []
      end)

    (store_ids ++ record_ids) |> Enum.uniq_by(&down/1) |> Enum.sort_by(&String.downcase/1)
  rescue
    # Store not booted: records-only listing (still honest, never a crash).
    ArgumentError -> record_ids_from_table_only(prefix)
  end

  defp record_ids_from_table_only(prefix) do
    @table
    |> table_rows()
    |> Enum.flat_map(fn
      {{:availability, rid}, _rec, display} ->
        if String.starts_with?(rid, prefix), do: [display || rid], else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(&down/1)
    |> Enum.sort_by(&String.downcase/1)
  end

  defp marker_ids_under(prefix) do
    config_markers()
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end

  defp marker_reason(resource_id) do
    Map.get(config_markers(), down(resource_id), @default_reason)
  end

  @doc """
  The documented `:resource_health_unavailable` chaos-marker contract
  (T-12 flags may name resource ids here): a list of resource-id binaries
  (default reason #{@default_reason}), a list of `{id, reason}` tuples, or
  a map `%{downcased_id => reason}`. Anything else is ignored — reads never
  crash on a malformed flag.
  """
  def config_markers do
    case Application.get_env(:smalt, :resource_health_unavailable, []) do
      ids when is_list(ids) -> markers_from_list(ids, %{})
      %{} = map -> markers_from_map(map, %{})
      _ -> %{}
    end
  end

  defp markers_from_list([id | rest], acc) when is_binary(id) do
    markers_from_list(rest, Map.put(acc, down(id), @default_reason))
  end

  defp markers_from_list([{id, reason} | rest], acc)
       when is_binary(id) and (is_binary(reason) or is_map(reason) or reason == nil) do
    {code, summary} = normalize_reason(reason)
    markers_from_list(rest, Map.put(acc, down(id), {code, summary}))
  end

  defp markers_from_list([_other | rest], acc), do: markers_from_list(rest, acc)
  defp markers_from_list([], acc), do: acc

  defp markers_from_map(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn
      {id, reason}, acc when is_binary(id) ->
        {code, summary} = normalize_reason(reason)
        Map.put(acc, down(id), {code, summary})

      _other, acc ->
        acc
    end)
  end

  # -- internals: reason + time helpers -------------------------------------------

  defp normalize_reason(nil), do: {@default_reason, nil}

  defp normalize_reason(reason) when is_binary(reason) do
    {reason, "The resource is unavailable (chaos injection; reason: #{reason})."}
  end

  defp normalize_reason(reason) when is_map(reason) or is_list(reason) do
    code =
      get_reason_key(reason, "reasonCode") || get_reason_key(reason, :reason_code) ||
        get_reason_key(reason, "reason") || get_reason_key(reason, :reason) ||
        @default_reason

    code = if is_binary(code), do: code, else: @default_reason
    summary = get_reason_key(reason, "summary") || get_reason_key(reason, :summary)
    {code, if(is_binary(summary), do: summary, else: nil)}
  end

  defp normalize_reason(_other), do: {@default_reason, nil}

  defp get_reason_key(map, key) when is_map(map) and (is_atom(key) or is_binary(key)) do
    if is_atom(key) and not is_binary(key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    else
      Map.get(map, key) || Map.get(map, safe_atom(key))
    end
  end

  defp get_reason_key(list, key) when is_list(list) do
    case List.keyfind(list, key, 0) do
      {_k, v} -> v
      nil -> nil
    end
  end

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp emit_transition(rec) do
    # Codes only — never the resource id (matter-isolation law). Raw
    # :telemetry (not the Smalt.Telemetry semconv gate): the alerting hook
    # name is new this ticket; attaching handlers cannot break emitters
    # (:telemetry isolates handler failures).
    :telemetry.execute(@transition_event, %{}, %{state: rec["state"], reason: rec["reason_code"]})
    :ok
  end

  defp subscription_of(resource_id) when is_binary(resource_id) do
    case String.split(resource_id, "/") do
      ["", "subscriptions", sub | _] when is_binary(sub) and sub != "" -> sub
      _ -> @default_subscription
    end
  end

  defp leaf(id), do: id |> String.split("/") |> Enum.reject(&(&1 == "")) |> List.last()

  defp down(v) when is_binary(v), do: String.downcase(v)

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
