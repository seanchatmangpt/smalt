defmodule Smalt.Telemetry.OcelEmitter do
  @moduledoc """
  OCEL 2.0 event emitter for smalt, wired ONLY via `:telemetry`:

    * `attach_many` on `[:bandit, :request, :stop]` — the event Bandit
      already emits for every HTTP request. No router is edited; the
      handler reads the metadata (`conn`) already flowing.
    * `emit/3` helper for the smalt-native event types in the closed
      vocabulary (`Smalt.Ocel.EventRegistry`).

  Every event is reshaped to the OCEL 2.0 event record the sink accepts
  (`"id"`, `"type"`, `"time"`, `"attributes"`, `"relationships"`) and
  appended through `Smalt.Telemetry.OcelNdjson.append/3`.

  ## Matter-isolation law

  Object ids are identifiers ONLY: resource id, partition key, blob path,
  queue/session/message id. NEVER payload values or bodies. Attributes
  carry verbs, statuses and durations — not matter.

  ## Fail-safe law

  A telemetry handler runs inline in the caller's process: nothing in
  `handle_event/4` may raise into it. All failures degrade to a logged
  drop.
  """

  require Logger

  alias Smalt.Ocel.EventRegistry
  alias Smalt.Telemetry.OcelNdjson

  @bandit_request_stop [:bandit, :request, :stop]

  @doc "Event names this emitter attaches to."
  @spec attached_events() :: [[atom()]]
  def attached_events, do: [@bandit_request_stop]

  @doc """
  Attaches the OCEL handler to `[:bandit, :request, :stop]`. Idempotent
  (re-attach returns `{:error, :already_exists}`, swallowed).
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(
           "smalt-ocel-emitter",
           attached_events(),
           &__MODULE__.handle_event/4,
           :ok
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc """
  Attached handler for `[:bandit, :request, :stop]`. Reshapes the request
  into a `cosmos.doc.crud` OCEL event: object = the resource id (request
  path), attributes = method/status/duration only. Never raises.
  """
  def handle_event(@bandit_request_stop, measurements, metadata, _config) do
    try do
      conn = Map.get(metadata, :conn)

      duration_ms =
        measurements |> Map.get(:duration, 0) |> System.convert_time_unit(:native, :millisecond)

      resource_id = if conn && conn.request_path, do: conn.request_path, else: "unknown"
      method = if conn && conn.method, do: conn.method, else: "UNKNOWN"

      event =
        build_event("cosmos.doc.crud", %{
          "method" => method,
          "status" => conn && conn.status,
          "duration_ms" => duration_ms
        })

      objects = [%{"id" => resource_id, "type" => "resource", "attributes" => %{}}]
      append(event, objects)
    rescue
      e ->
        Logger.error("Smalt.Telemetry.OcelEmitter: dropped bandit event: #{Exception.message(e)}")
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Emits one OCEL event of `event_type` over `objects` (`%{"id" => ..,
  "type" => ..}` maps) with `attributes`. Unknown event types are logged
  and dropped — never raised. Entries without a binary id/type are
  dropped (matter-isolation: a malformed identifier is never laundered
  into the log). Returns `{:ok, path}` | `{:ok, :dropped}` |
  `{:error, term()}`.
  """
  @spec emit(String.t(), [map()], map()) :: {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def emit(event_type, objects, attributes \\ %{})
      when is_binary(event_type) and is_list(objects) and is_map(attributes) do
    if EventRegistry.event_type?(event_type) do
      event_type
      |> build_event(attributes)
      |> append(sanitize_objects(objects))
    else
      Logger.warning(
        "Smalt.Telemetry.OcelEmitter: dropping unknown event type #{inspect(event_type)}"
      )

      {:ok, :dropped}
    end
  end

  # -- internals -------------------------------------------------------------

  defp build_event(type, attributes) do
    %{
      "id" => uuid_v7(),
      "type" => type,
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attributes" => Map.reject(attributes, fn {_k, v} -> is_nil(v) end),
      "relationships" => []
    }
  end

  defp sanitize_objects(objects) do
    for %{"id" => id, "type" => type} <- objects, is_binary(id) and is_binary(type) do
      %{"id" => id, "type" => type, "attributes" => %{}}
    end
  end

  defp append(event, objects) do
    event = %{
      event
      | "relationships" =>
          Enum.map(objects, fn %{"id" => id, "type" => type} ->
            %{"objectId" => id, "qualifier" => type}
          end)
    }

    case OcelNdjson.append(event, objects) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        Logger.error("Smalt.Telemetry.OcelEmitter: sink append failed: #{inspect(reason)}")
        err
    end
  end

  # UUIDv7 (time-ordered): 48-bit unix ms, version 7, RFC 4122 variant.
  defp uuid_v7 do
    ms = System.system_time(:millisecond)

    <<r1::unsigned-integer-size(12), r2::unsigned-integer-size(62), _::size(6)>> =
      :crypto.strong_rand_bytes(10)

    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> =
      <<ms::48, 7::4, r1::12, 2::2, r2::62>>

    [a, b, c, d, e]
    |> Enum.map(&Base.encode16(&1, case: :lower))
    |> Enum.join("-")
  end
end
