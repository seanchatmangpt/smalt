defmodule Smalt.Telemetry.OcelEmitter do
  @moduledoc """
  OCEL 2.0 event emitter for smalt, wired ONLY via `:telemetry`:

    * `attach_many` on `[:bandit, :request, :stop]` — the event Bandit
      emits for every HTTP request. No router is edited; the handler reads
      the metadata (`conn`) already flowing.
    * `emit/3` helper for the smalt-native event types in the closed
      vocabulary (`Smalt.Ocel.EventRegistry`).

  Every event is reshaped to the OCEL 2.0 event record the sink accepts
  (`"id"`, `"type"`, `"time"`, `"attributes"`, `"relationships"`) and
  appended through `Smalt.Telemetry.OcelNdjson.append/3`.

  ## Journal sink (SJ-4, config-gated, default OFF)

  When `config :smalt, :journal_sink_dir` is set, every journaled event
  ALSO appends one operator-format frame through SJ-1's durable sink
  (`Smalt.Storage.JournalSink.append/6`; the sink assigns the monotonic
  SeqID and owns the segment files; `Smalt.Application` starts the named
  sink child iff the config is set). Unset → byte-identical current
  behavior: no `JournalSink` call is ever made, and the OCEL ndjson path
  is untouched.

  Frame format (operator EventType map, matter-isolation: object ids
  only, never payloads):

    * cosmos put    => 0x0001 (`cosmos.doc.crud`, method != DELETE)
    * cosmos delete => 0x0002 (`cosmos.doc.crud`, method == DELETE)
    * blob commit   => 0x0003 (`blob.custody.transition`)
    * msg enqueue   => 0x0004 (`amqp.delivery.settled`)

  Event types outside the map are OCEL-only (no journal frame) — the
  map is closed, like the event registry. Frame fields on the wire:
  EventType = the 16-bit operator code; TableID = 0 (telemetry plane);
  Key = the primary object id; Payload = tiny JSON
  `%{"ocel_event_id" => ..., "time" => ...}` — ids and codes only
  (matter-isolation law).

  ## Matter-isolation law

  Object ids are identifiers ONLY: resource id, partition key, blob path,
  queue/session/message id. NEVER payload values or bodies. Attributes
  carry verbs, statuses and durations — not matter. The journal frame
  carries ids and codes only.

  ## Fail-safe law

  A telemetry handler runs inline in the caller's process: nothing in
  `handle_event/4` may raise into it. All failures degrade to a logged
  drop — including a missing/mismatched `JournalSink` under the ON
  configuration (logged drop, OCEL path unaffected).
  """

  require Logger

  alias Smalt.Ocel.EventRegistry
  alias Smalt.Storage.JournalSink
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
  into a `cosmos.doc.crud` OCEL event and — when the journal sink is
  configured — a 0x0001/0x0002 journal frame.
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

      objects = [%{"id" => resource_id, "type" => "resource"}]
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

  @doc """
  Operator journal EventType map (closed): returns the 16-bit frame code
  for an OCEL event type + attributes, or `nil` when the type is OCEL-only.
  """
  @spec journal_event_code(String.t(), map()) :: non_neg_integer() | nil
  def journal_event_code("cosmos.doc.crud", %{"method" => "DELETE"}), do: 0x0002
  def journal_event_code("cosmos.doc.crud", _attrs), do: 0x0001
  def journal_event_code("blob.custody.transition", _attrs), do: 0x0003
  def journal_event_code("amqp.delivery.settled", _attrs), do: 0x0004
  def journal_event_code(_type, _attrs), do: nil

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

    result =
      case OcelNdjson.append(event, objects) do
        {:ok, _} = ok ->
          ok

        {:error, reason} = err ->
          Logger.error("Smalt.Telemetry.OcelEmitter: sink append failed: #{inspect(reason)}")
          err
      end

    journal_append(event, objects)
    result
  end

  # SJ-4: journal sink is config-gated (default OFF → this function is a
  # no-op — byte-identical to pre-diff behavior). Under ON, one frame per
  # journaled event, appended through SJ-1's durable sink
  # (Smalt.Storage.JournalSink, named process started by the Application
  # iff the config is set; the sink assigns the monotonic SeqID). All
  # failures — including the sink process not running — degrade to a
  # logged drop (fail-safe law); the OCEL path is never affected.
  defp journal_append(event, objects) do
    case Application.get_env(:smalt, :journal_sink_dir) do
      nil ->
        :ok

      _dir ->
        case journal_event_code(event["type"], event["attributes"]) do
          nil ->
            :ok

          code ->
            key =
              case objects do
                [%{"id" => id} | _] -> id
                _ -> "unknown"
              end

            payload =
              Jason.encode!(%{"ocel_event_id" => emitter_event_id(event), "time" => event["time"]})

            {:ok, _seq} = JournalSink.append(JournalSink, code, 0, key, payload)
        end
    end
  rescue
    e ->
      Logger.error("Smalt.Telemetry.OcelEmitter: journal frame dropped: #{Exception.message(e)}")
      :ok
  end

  defp emitter_event_id(event), do: Map.get(event, "id")

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
