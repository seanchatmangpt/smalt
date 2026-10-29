defmodule Smalt.Ocel do
  @moduledoc """
  Stateless OCEL 2.0 query + envelope functions over plain maps.

  No storage of its own — the caller assembles event/object lists (e.g.
  from `Smalt.Telemetry.OcelNdjson.read_document/1`) and passes them in.
  Shapes (plain maps, the OCEL 2.0 JSON subset the sink emits):

    * event: `%{"id" => binary, "type" => binary, "time" => ISO8601 binary,
      "attributes" => map, "relationships" => [%{"objectId" => binary,
      "qualifier" => binary}]}`
    * object: `%{"id" => binary, "type" => binary, "attributes" => map}`
    * attribute record: `%{"objectId" => binary, "attribute" => binary,
      "value" => term, "recordedAt" => ISO8601 binary}`
  """

  @type event :: map()
  @type object :: map()
  @type attribute_record :: map()

  @doc """
  Time-ordered (by `"time"`, ties by `"id"`) events whose relationships
  touch `object_id`.
  """
  @spec object_trace([event()], String.t()) :: [event()]
  def object_trace(events, object_id) when is_list(events) and is_binary(object_id) do
    events
    |> Enum.filter(fn %{"relationships" => rels} ->
      Enum.any?(rels, fn %{"objectId" => oid} -> oid == object_id end)
    end)
    |> Enum.sort_by(&{&1["time"], &1["id"]})
  end

  @doc """
  Chronological (by `"recordedAt"`, stable for identical timestamps) history
  of one object's dynamic attribute observations.
  """
  @spec attribute_history([attribute_record()]) :: [attribute_record()]
  def attribute_history(records) when is_list(records) do
    Enum.sort_by(records, & &1["recordedAt"])
  end

  @doc """
  Referential integrity over one envelope: every relationship `objectId`
  must name an object present in `objects`. Returns `:ok` or
  `{:error, {:dangling_relationships, [{owner_id, dangling_object_id}]}}`.
  """
  @spec validate_envelope([event()], [object()]) ::
          :ok | {:error, {:dangling_relationships, [{String.t(), String.t()}]}}
  def validate_envelope(events, objects) when is_list(events) and is_list(objects) do
    known = MapSet.new(objects, & &1["id"])

    dangling =
      Enum.flat_map(events, fn %{"id" => eid, "relationships" => rels} ->
        for %{"objectId" => oid} <- rels, not MapSet.member?(known, oid), do: {eid, oid}
      end)

    case dangling do
      [] -> :ok
      dangling -> {:error, {:dangling_relationships, dangling}}
    end
  end

  @doc """
  Encode events + objects into a complete OCEL 2.0 JSON envelope (four
  top-level keys). Type declarations are the sorted union of every type
  used — assembly can never manufacture a used-but-undeclared type. An
  event or object WITHOUT a binary `"type"` fails closed
  (`{:error, {:missing_type, id}}`) — a blank type is never laundered
  into a declaration row.
  """
  @spec encode(events: [event()], objects: [object()]) :: {:ok, String.t()} | {:error, term()}
  def encode(opts) when is_list(opts) do
    events = Keyword.get(opts, :events, [])
    objects = Keyword.get(opts, :objects, [])

    with :ok <- require_types(events),
         :ok <- require_types(objects) do
      event_types = events |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()
      object_types = objects |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()

      envelope = %{
        "ocel:eventTypes" => Enum.map(event_types, &%{"name" => &1}),
        "ocel:objectTypes" => Enum.map(object_types, &%{"name" => &1}),
        "ocel:events" => events,
        "ocel:objects" => objects
      }

      {:ok, Jason.encode!(envelope)}
    end
  rescue
    e -> {:error, {:encode_failed, Exception.message(e)}}
  end

  defp require_types(records) do
    case Enum.find(records, &(not is_binary(Map.get(&1, "type")))) do
      nil -> :ok
      bad -> {:error, {:missing_type, Map.get(bad, "id")}}
    end
  end

  @doc """
  Decode an OCEL 2.0 JSON envelope (as produced by `encode/1`) back into
  `{:ok, %{events: [...], objects: [...]}}`. Fails closed on a missing
  top-level key, malformed JSON, or a used-but-undeclared type (the
  encode-side closure law holds on the way back in).
  """
  @spec decode(String.t()) ::
          {:ok, %{events: [event()], objects: [object()]}} | {:error, term()}
  def decode(json) when is_binary(json) do
    doc = Jason.decode!(json)

    with %{
           "ocel:events" => events,
           "ocel:objects" => objects,
           "ocel:eventTypes" => ets,
           "ocel:objectTypes" => ots
         }
         when is_list(events) and is_list(objects) and is_list(ets) and is_list(ots) <- doc do
      with :ok <- check_closure(events, declared_names(ets), "event"),
           :ok <- check_closure(objects, declared_names(ots), "object") do
        {:ok, %{events: events, objects: objects}}
      else
        {:error, _} = err -> err
      end
    else
      _ -> {:error, {:invalid_envelope, :missing_ocel_2_top_level_keys}}
    end
  rescue
    e -> {:error, {:decode_failed, Exception.message(e)}}
  end

  defp declared_names(names) when is_list(names) do
    for %{"name" => n} <- names, is_binary(n), do: n
  end


  defp check_closure(records, declared, kind) do
    used = records |> Enum.map(& &1["type"]) |> Enum.uniq()

    case Enum.find(used, &(is_binary(&1) and &1 not in declared)) do
      nil -> :ok
      bad -> {:error, {:invalid_envelope, {:used_type_not_declared, kind, bad}}}
    end
  end
end
