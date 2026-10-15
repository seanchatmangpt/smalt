defmodule Smalt.DataPlane.Purview do
  @moduledoc """
  Microsoft Purview Catalog (Atlas v2) entity + lineage engine over the Store.

  Wire surface (route handlers in `EgressRouter` mount on 8443):
  - `POST /atlas/v2/entity`                       -> `create_entity/2`
  - `POST /atlas/v2/entity/bulk`                  -> `bulk_entities/2`
  - `GET  /atlas/v2/entity/guid/:guid`            -> `get_entity/2`
  - `GET  /atlas/v2/lineage/:direction/:guid?depth=N` -> `lineage/3`
  """

  alias Smalt.Store

  @max_bulk 100
  @directions ~w(input output both)

  # ---------------------------------------------------------------------------
  # Entities
  # ---------------------------------------------------------------------------

  @doc "Creates a single entity. `{:ok, 201, entity}` (guid assigned when absent)."
  def create_entity(body, opts \\ %{})

  # A non-map `entity` (or bare non-map body) is a 400, not a BadMapError 500.
  # Note the envelope body itself is a map, so the bare-map clause must not
  # catch `{"entity" => "x"}` — hence the explicit non-map-entity refusal here.
  def create_entity(%{"entity" => entity}, _opts) when not is_map(entity) do
    {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entity body required"}}}
  end

  def create_entity(%{"entity" => entity}, opts) when is_map(entity), do: do_create(entity, opts)

  def create_entity(entity, opts) when is_map(entity), do: do_create(entity, opts)

  def create_entity(_body, _opts) do
    {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entity body required"}}}
  end

  defp do_create(entity, _opts) do
    entity = Map.put_new(entity, "guid", new_guid())

    Store.put(:smalt_purview_entities, entity["guid"], entity)

    {:ok, 201, entity}
  end

  @doc """
  Creates up to #{@max_bulk} entities atomically. More than #{@max_bulk} ->
  `{:error, 400, atlas_error}` with no partial insert.
  """
  def bulk_entities(body, opts \\ %{})

  def bulk_entities(%{"entities" => entities}, _opts) when is_list(entities) do
    # Atomic: over-limit OR any non-map element -> 400 with no partial insert.
    if length(entities) <= @max_bulk and Enum.all?(entities, &is_map/1) do
      entities =
        Enum.map(entities, fn e ->
          e = Map.put_new(e, "guid", new_guid())
          Store.put(:smalt_purview_entities, e["guid"], e)
          e
        end)

      {:ok, 201,
       %{
         "guidAssignments" => Map.new(entities, fn e -> {e["guid"], e["guid"]} end),
         "mutatedEntities" => %{"CREATE" => entities}
       }}
    else
      {:error, 400,
       %{
         "error" => %{
           "code" => "ATLAS-400-00-001",
           "message" => "bulk is limited to #{@max_bulk} entities, got #{length(entities)}"
         }
       }}
    end
  end

  def bulk_entities(_body, _opts) do
    {:error, 400, %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entities array required"}}}
  end

  @doc "Fetches an entity by guid. `{:ok, 200, entity}` | `{:error, 404, body}`."
  def get_entity(guid, _opts \\ %{}) do
    case Store.get(:smalt_purview_entities, guid) do
      {:ok, entity} ->
        {:ok, 200, entity}

      :error ->
        {:error, 404,
         %{"error" => %{"code" => "ATLAS-404-00-005", "message" => "entity #{guid} not found"}}}
    end
  end

  @doc """
  Stores a lineage edge (route/test helper). Keyed `"from/to/type"` so the
  binary-prefix `Store.list/1` walk enumerates it.
  """
  def put_edge(from, to, type_name, details \\ %{}) do
    edge =
      Map.merge(
        %{
          "fromEntityId" => from,
          "toEntityId" => to,
          "relationshipId" => details["relationshipId"] || "#{from}->#{to}:#{type_name}",
          "typeName" => type_name
        },
        details
      )

    Store.put(:smalt_purview_edges, "#{from}/#{to}/#{type_name}", edge)
    edge
  end

  # ---------------------------------------------------------------------------
  # Lineage
  # ---------------------------------------------------------------------------

  @doc """
  BFS lineage for `guid` over `:smalt_purview_edges`, honoring `direction`
  (`input | output | both`) and `depth` (default 1; bad direction -> 400).

  Response: `{"baseEntityGuid", "guidEntityMap", "relations"}` where relations are
  `%{"fromEntityId", "toEntityId", "relationshipId"}`.
  """
  def lineage(guid, direction, depth)

  def lineage(guid, direction, depth) when direction in @directions do
    base = to_string(guid)
    depth = parse_depth(depth)

    edges = Store.list(:smalt_purview_edges)

    {relations, visited} = walk(MapSet.new([base]), MapSet.new([base]), direction, depth, edges, MapSet.new())

    guid_entity_map =
      Map.new(visited, fn g ->
        case Store.get(:smalt_purview_entities, g) do
          {:ok, entity} -> {g, entity}
          :error -> {g, %{"guid" => g, "typeName" => "Unknown"}}
        end
      end)

    {:ok, 200,
     %{
       "baseEntityGuid" => base,
       "guidEntityMap" => guid_entity_map,
       "relations" => MapSet.to_list(relations) |> Enum.sort_by(& &1["relationshipId"])
     }}
  end

  def lineage(_guid, _direction, _depth) do
    {:error, 400,
     %{
       "error" => %{
         "code" => "ATLAS-400-00-001",
         "message" => "direction must be one of input, output, both"
       }
     }}
  end

  # frontier: nodes at the current depth; visited: all nodes reached so far
  defp walk(_frontier, visited, _dir, 0, _edges, relations), do: {relations, visited}

  defp walk(frontier, visited, dir, depth, edges, relations) do
    next_nodes =
      frontier
      |> Enum.flat_map(fn guid ->
        edges
        |> Enum.flat_map(fn edge ->
          from = edge["fromEntityId"]
          to = edge["toEntityId"]

          case dir do
            "input" -> if to == guid and not MapSet.member?(visited, from), do: [from], else: []
            "output" -> if from == guid and not MapSet.member?(visited, to), do: [to], else: []
            "both" ->
              cond do
                from == guid and to == guid -> []
                from == guid and not MapSet.member?(visited, to) -> [to]
                to == guid and not MapSet.member?(visited, from) -> [from]
                true -> []
              end
          end
        end)
      end)
      |> MapSet.new()

    # Relations include EVERY edge incident to a frontier node whose other
    # endpoint is reachable (visited or newly discovered) — not only the edge
    # that first discovered a node. The previous next_nodes-only version
    # silently dropped back-edges in cyclic lineage graphs (a 2-cycle returned
    # one of its two real relations). Cycle safety is unaffected: the walk
    # still expands only through `next_nodes` (never re-expands visited nodes),
    # so it terminates; only the relation REPORTING is edge-complete.
    reachable = MapSet.union(visited, next_nodes)

    relations =
      for guid <- frontier,
          edge <- edges,
          other <- [other_endpoint(edge, guid, dir)],
          other != nil and other != guid and MapSet.member?(reachable, other),
          reduce: relations do
        acc ->
          {from, to} = ordered(edge, guid, other, dir)

          MapSet.put(acc, %{
            "fromEntityId" => from,
            "toEntityId" => to,
            "relationshipId" => edge["relationshipId"] || "#{from}->#{to}"
          })
      end

    unvisited = MapSet.difference(next_nodes, visited)
    visited = MapSet.union(visited, unvisited)

    walk(unvisited, visited, dir, depth - 1, edges, relations)
  end

  # The node on the other side of `edge` from `guid`, honoring `direction`.
  # nil when the edge does not touch `guid` in the direction, or when it is a
  # self-loop (`from == to == guid`, excluded in every direction).
  defp other_endpoint(edge, guid, "input") do
    if edge["toEntityId"] == guid and edge["fromEntityId"] != guid, do: edge["fromEntityId"]
  end

  defp other_endpoint(edge, guid, "output") do
    if edge["fromEntityId"] == guid and edge["toEntityId"] != guid, do: edge["toEntityId"]
  end

  defp other_endpoint(edge, guid, "both") do
    from = edge["fromEntityId"]
    to = edge["toEntityId"]

    cond do
      from == guid and to != guid -> to
      to == guid and from != guid -> from
      true -> nil
    end
  end

  defp ordered(edge, _guid, _node, "output"), do: {edge["fromEntityId"], edge["toEntityId"]}
  defp ordered(_edge, guid, node, "input"), do: {node, guid}
  defp ordered(edge, _guid, _node, "both"), do: {edge["fromEntityId"], edge["toEntityId"]}

  defp parse_depth(nil), do: 1

  defp parse_depth(d) when is_integer(d) and d >= 0, do: d

  defp parse_depth(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, ""} when n >= 0 -> n
      _ -> 1
    end
  end

  defp parse_depth(_), do: 1

  defp new_guid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn h ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = h

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
