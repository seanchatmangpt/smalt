defmodule Smalt.Telemetry.OcelNdjson do
  @moduledoc """
  Append-only NDJSON sink for smalt OCEL 2.0 events: one complete,
  individually-conformant OCEL 2.0 JSON log per line (four top-level
  keys), written to `tmp/ocel/events.ndjson` (gitignored — under the
  repo's existing `/tmp/` ignore).

  ## Assembly law (deterministic, order-preserving, fail-closed)

  `assemble_document/1` assembles lines into ONE aggregated OCEL 2.0
  document:

    * Blank lines are skipped.
    * Each non-blank line must decode as JSON and carry ALL FOUR OCEL 2.0
      top-level keys as arrays. Anything else is one typed violation and
      the whole assembly fails closed.
    * `"ocel:events"`: concatenated in file order. Duplicate event ids are
      NOT merged — downstream adjudication owns them.
    * `"ocel:objects"`: deduplicated by string `"id"`, first occurrence
      wins. Objects without a usable id are kept for adjudication.
    * `"ocel:eventTypes"` / `"ocel:objectTypes"`: union of declared names
      plus every type actually used — assembly can never manufacture a
      used-but-undeclared type.
    * Object-reference closure: every relationship `objectId` must
      reference an object present in the SAME assembled document — a
      dangling reference is a typed refusal, never a silent admit.
  """

  require Logger

  @line_keys ~w(ocel:objectTypes ocel:eventTypes ocel:events ocel:objects)
  @default_dir Path.join("tmp", "ocel")
  @default_file "events.ndjson"

  @doc "Default sink directory (`tmp/ocel`)."
  def default_dir, do: @default_dir

  @doc """
  Appends one event (+ the objects its relationships reference) as ONE
  complete OCEL 2.0 document line. Gates the event type through
  `Smalt.Ocel.EventRegistry` — unknown types are logged and dropped
  (`{:ok, :dropped}`), never raised. Returns `{:ok, path}` on append.
  """
  @spec append(map(), [map()], keyword()) :: {:ok, String.t()} | {:ok, :dropped} | {:error, term()}
  def append(event, objects \\ [], opts \\ []) when is_map(event) and is_list(objects) do
    type = Map.get(event, "type")

    if Smalt.Ocel.EventRegistry.event_type?(type) do
      dir = Keyword.get(opts, :dir) || Application.get_env(:smalt, :ocel_dir, @default_dir)
      path = Path.join(dir, Keyword.get(opts, :file, @default_file))

      line =
        %{
          "ocel:eventTypes" => [%{"name" => type}],
          "ocel:objectTypes" => objects |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.map(&%{"name" => &1}),
          "ocel:events" => [event],
          "ocel:objects" => objects
        }
        |> Jason.encode!()

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(path, line <> "\n", [:append]) do
        {:ok, path}
      end
    else
      Logger.warning("Smalt.Telemetry.OcelNdjson: dropping unknown event type #{inspect(type)}")
      {:ok, :dropped}
    end
  rescue
    e -> {:error, {:append_failed, Exception.message(e)}}
  end

  @doc """
  Assembles lines (enumerable of strings) into `{:ok, document}` |
  `{:error, violations}`. See the assembly law in the moduledoc.
  """
  @spec assemble_document(Enumerable.t()) :: {:ok, map()} | {:error, [map()]}
  def assemble_document(lines) do
    lines
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.reduce_while(
      {:ok, %{events: [], objects: [], object_ids: MapSet.new(), event_types: MapSet.new(), object_types: MapSet.new()}},
      fn line, {:ok, acc} ->
        case ingest_line(line, acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, violations} -> {:halt, {:error, violations}}
        end
      end
    )
    |> case do
      {:error, violations} -> {:error, violations}
      {:ok, acc} -> closure_check(acc)
    end
  end

  # Closure law (object-reference side, mirroring the used-but-undeclared
  # type law): every relationship `objectId` in the assembled document
  # must reference an object id present in the SAME assembled document.
  # Fail closed with one typed violation per dangling reference.
  defp closure_check(acc) do
    dangling =
      for event <- acc.events,
          %{"objectId" => oid} <- event["relationships"] || [],
          oid not in acc.object_ids do
        %{path: "$.ocel:events[id:#{Map.get(event, "id")}].relationships", reason: "references unknown object id: #{inspect(oid)}"}
      end

    case dangling do
      [] -> {:ok, finalize(acc)}
      violations -> {:error, violations}
    end
  end

  @doc "Same as `assemble_document/1`, from a file path."
  @spec read_document(term()) :: {:ok, map()} | {:error, [map()]}
  def read_document(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> assemble_document(String.split(body, "\n"))
      {:error, reason} -> {:error, [%{path: "$", reason: "cannot read file: #{inspect(reason)}"}]}
    end
  end

  def read_document(path),
    do: {:error, [%{path: "$", reason: "path must be a string, got: #{inspect(path)}"}]}

  # -- per-line ingestion ---------------------------------------------------

  defp ingest_line(line, acc) do
    case Jason.decode(line) do
      {:ok, %{} = doc} ->
        violations =
          for key <- @line_keys,
              not is_list(Map.get(doc, key)) do
            %{path: "$.#{key}", reason: "must be an array, got: #{inspect(Map.get(doc, key))}"}
          end

        case violations do
          [] -> merge_doc(doc, acc)
          violations -> {:error, violations}
        end

      {:ok, other} ->
        {:error, [%{path: "$", reason: "not an OCEL 2.0 document: #{inspect(other)}"}]}

      {:error, e} ->
        {:error, [%{path: "$", reason: "malformed JSON: #{Exception.message(e)}"}]}
    end
  end

  defp merge_doc(doc, acc) do
    events = Map.fetch!(doc, "ocel:events")
    objects = Map.fetch!(doc, "ocel:objects")

    {new_objects, object_ids} =
      Enum.reduce(objects, {acc.objects, acc.object_ids}, fn
        %{"id" => id} = object, {objs, ids} when is_binary(id) ->
          if MapSet.member?(ids, id) do
            {objs, ids}
          else
            {objs ++ [object], MapSet.put(ids, id)}
          end

        object, {objs, ids} ->
          # Kept for adjudication — assembly never drops evidence.
          {objs ++ [object], ids}
      end)

    used_event_types = for %{"type" => t} <- events, is_binary(t), t != "", do: t
    used_object_types = for %{"type" => t} <- objects, is_binary(t), t != "", do: t

    {:ok,
     %{
       acc
       | events: acc.events ++ events,
         objects: new_objects,
         object_ids: object_ids,
         event_types:
           MapSet.union(acc.event_types, MapSet.new(declared_names(doc, "ocel:eventTypes") ++ used_event_types)),
         object_types:
           MapSet.union(acc.object_types, MapSet.new(declared_names(doc, "ocel:objectTypes") ++ used_object_types))
     }}
  end

  defp declared_names(doc, key) do
    doc
    |> Map.get(key, [])
    |> Enum.map(fn
      name when is_binary(name) -> name
      %{"name" => name} -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp finalize(acc) do
    %{
      "ocel:objectTypes" => acc.object_types |> Enum.sort() |> Enum.map(&%{"name" => &1}),
      "ocel:eventTypes" => acc.event_types |> Enum.sort() |> Enum.map(&%{"name" => &1}),
      "ocel:events" => acc.events,
      "ocel:objects" => acc.objects
    }
  end
end
