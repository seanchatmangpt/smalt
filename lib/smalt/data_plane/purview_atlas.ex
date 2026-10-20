defmodule Smalt.DataPlane.Purview do
  @moduledoc """
  Microsoft Purview Catalog (Atlas v2) entity + lineage engine over the Store.

  Wire surface (route handlers in `EgressRouter` mount on 8443):
  - `POST /atlas/v2/entity`                       -> `create_entity/2`
  - `POST /atlas/v2/entity/bulk`                  -> `bulk_entities/2`
  - `GET  /atlas/v2/entity/guid/:guid`            -> `get_entity/2`
  - `GET  /atlas/v2/lineage/:direction/:guid?depth=N` -> `lineage/3`

  v26.10.19 ERRC-RAISE (lane C15) fidelity additions:

  - type validation against registered typedefs (unknown `typeName` -> typed
    `ATLAS-400-CLASS` 400, like real Atlas' `Invalid type name`)
  - classification attachment (`add_classifications/3`, `bulk_classification/2`
    — POST /entity/guid/classifications and POST /entity/bulk/classification
    shapes), classDefs validated against the same registry
  - Process entities: `relationshipAttributes` input/output lists mint
    lineage edges (`Process.Input` / `Process.Output`) at create AND update
  - `update_entities/2` (PUT /entity/bulk semantics: merge by guid)
  - typedef/classDef registry: `register_typedef/2`, `register_classdef/2`,
    `registered_type?/1`, `list_typedefs/0`

  Glossary surface (Atlas v2 glossary parity, lane W4H):

  - `glossary/1`                -> GET /glossary            (glossary record + terms)
  - `list_terms/1`              -> GET /glossary/terms      (all terms, full maps)
  - `put_term/2`                -> PUT /glossary/term       (create 201 / update 200)
  - `get_term/2`                -> GET /glossary/terms/:guid
  - `delete_term/2`             -> DELETE /glossary/terms/:guid (204)

  A term's `assignedEntities` attach the term to entities: each attachment
  mints a real lineage edge (termGuid -> entityGuid, `AtlasGlossaryTerm`), so
  GET /atlas/v2/lineage/{direction}/{guid} shows the term link. DELETE of the
  term removes its edges (the link disappears from lineage).

  UNSUPPORTED (honest per-field): the substrate has no full Atlas type system
  — supertype/attributeDefs are stored but NOT enforced (only the type NAME is
  validated); glossary categories/term templates are stored, not enforced.
  """

  alias Smalt.Store

  @max_bulk 100
  @directions ~w(input output both)

  # Glossary storage: terms live under `GTERM:<guid>` keys and the glossary
  # record under `GLOSSARY:` (both in :smalt_purview_entities; the binary
  # prefix keeps them out of the guid-keyed entity namespace). Term->entity
  # attachments ride :smalt_purview_edges as `AtlasGlossaryTerm` edges, so the
  # existing lineage BFS sees them with zero lineage-code changes.
  @term_prefix "GTERM:"
  @glossary_key "GLOSSARY:"
  @term_edge_type "AtlasGlossaryTerm"

  # Types always admitted without registration: Atlas structural base types
  # plus the emulator's own pinned surface types (runtime contract tests use
  # `smalt_table`; lineage placeholders use `Unknown`).
  @builtin_types ~w(
    Referenceable Asset DataSet Process Deployment Database Table Column View
    smalt_table Unknown
  )

  # ---------------------------------------------------------------------------
  # Typedef / classDef registry (Store keyspace `TYPEDEF:` / `CLASSDEF:` under
  # :smalt_purview_entities — guid keys never collide with those prefixes)
  # ---------------------------------------------------------------------------

  @doc "Registers an entity typedef `%{\"name\" => name, ...}`. Idempotent overwrite."
  @spec register_typedef(map(), map()) :: {:ok, 201, map()}
  def register_typedef(body, _opts \\ %{})

  def register_typedef(%{"name" => name} = body, _opts) when is_binary(name) do
    typedef = Map.merge(%{"category" => "ENTITY", "name" => name}, body)
    Store.put(:smalt_purview_entities, "TYPEDEF:" <> name, typedef)
    {:ok, 201, typedef}
  end

  def register_typedef(_body, _opts) do
    {:error, 400, class_error("typedef requires a binary `name`")}
  end

  @doc "Registers a classification classDef `%{\"name\" => name, ...}`."
  @spec register_classdef(map(), map()) :: {:ok, 201, map()}
  def register_classdef(body, _opts \\ %{})

  def register_classdef(%{"name" => name} = body, _opts) when is_binary(name) do
    classdef = Map.merge(%{"category" => "CLASSIFICATION", "name" => name}, body)
    Store.put(:smalt_purview_entities, "CLASSDEF:" <> name, classdef)
    {:ok, 201, classdef}
  end

  def register_classdef(_body, _opts) do
    {:error, 400, class_error("classDef requires a binary `name`")}
  end

  @doc "Lists all registered typedefs and classDefs (Atlas `GET /types/typedefs` face)."
  def list_typedefs(opts \\ %{}) do
    prefix = opts[:prefix]

    defs = prefix_values(:smalt_purview_entities, "TYPEDEF:")

    classdefs = prefix_values(:smalt_purview_entities, "CLASSDEF:")

    defs =
      if prefix,
        do: Enum.filter(defs, &String.starts_with?(&1["name"] || "", prefix)),
        else: defs

    {:ok, 200, %{"entityDefs" => defs, "classificationDefs" => classdefs}}
  end

  @doc "True when `name` is a builtin or registered entity type."
  def registered_type?(name) when is_binary(name) do
    name in @builtin_types or match?({:ok, _}, Store.get(:smalt_purview_entities, "TYPEDEF:" <> name))
  end

  def registered_type?(_), do: false

  # Store.list/1 returns VALUES only (the {k, v} shape would raise on maps);
  # prefix-scoped enumeration goes through Store.keys/1 + Store.get/2.
  defp prefix_values(table, prefix) do
    table
    |> Store.keys()
    |> Enum.filter(&is_binary(&1) and String.starts_with?(&1, prefix))
    |> Enum.map(fn k -> {:ok, v} = Store.get(table, k); v end)
  end

  # Term-edge cleanup: enumerate edge keys, delete only this term's
  # AtlasGlossaryTerm edges. `side` is :from (edges minted FROM the term) or
  # :any (both endpoints).
  defp delete_term_edges(guid, side) do
    :smalt_purview_edges
    |> Store.keys()
    |> Enum.each(fn k ->
      case Store.get(:smalt_purview_edges, k) do
        {:ok, %{"typeName" => t, "fromEntityId" => f, "toEntityId" => to}} ->
          delete? =
            t == @term_edge_type and
              cond do
                side == :from -> f == guid
                side == :any -> f == guid or to == guid
              end

          if delete?, do: Store.delete(:smalt_purview_edges, k)

        _ ->
          :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Entities
  # ---------------------------------------------------------------------------

  @doc "Creates a single entity. `{:ok, 201, entity}` (guid assigned when absent)."
  def create_entity(body, opts \\ %{})

  # A non-map `entity` (or bare non-map body) is a 400, not a BadMapError 500.
  # Note the envelope body is a map, so the bare-map clause must not
  # catch `{"entity" => "x"}` — hence the explicit non-map-entity refusal here.
  def create_entity(%{"entity" => entity}, _opts) when not is_map(entity) do
    {:error, 400, entity_body_error()}
  end

  def create_entity(%{"entity" => entity}, opts) when is_map(entity),
    do: validate_and_create(entity, opts)

  def create_entity(entity, opts) when is_map(entity), do: validate_and_create(entity, opts)

  def create_entity(_body, _opts) do
    {:error, 400, entity_body_error()}
  end

  defp entity_body_error do
    %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entity body required"}}
  end

  defp validate_and_create(entity, opts) do
    with :ok <- validate_type(entity) do
      do_create(entity, opts)
    end
  end

  # Unknown (or missing) typeName -> typed 400 ATLAS-400-CLASS, like real
  # Atlas refusing to mint an entity of an unknown type.
  defp validate_type(%{"typeName" => name}) when is_binary(name) do
    if registered_type?(name), do: :ok, else: {:error, 400, class_error("typeName `#{name}` is not a registered typedef")}
  end

  defp validate_type(_entity) do
    {:error, 400, class_error("entity requires a binary `typeName`")}
  end

  defp do_create(entity, _opts) do
    entity = Map.put_new(entity, "guid", new_guid())
    Store.put(:smalt_purview_entities, entity["guid"], entity)
    mint_process_edges(entity)
    {:ok, 201, entity}
  end

  # ---------------------------------------------------------------------------
  # Bulk entities
  # ---------------------------------------------------------------------------

  @doc """
  Creates up to #{@max_bulk} entities atomically. More than #{@max_bulk} ->
  `{:error, 400, atlas_error}` with no partial insert.
  """
  def bulk_entities(body, opts \\ %{})

  def bulk_entities(%{"entities" => entities}, _opts) when is_list(entities) do
    # Atomic: over-limit, non-map element, OR unknown typeName -> 400 with no
    # partial insert. Validate the whole list before any Store.put.
    cond do
      length(entities) > @max_bulk ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "ATLAS-400-00-001",
             "message" => "bulk is limited to #{@max_bulk} entities, got #{length(entities)}"
           }
         }}

      not Enum.all?(entities, &is_map/1) ->
        {:error, 400, entity_body_error()}

      true ->
        case validate_all_types(entities) do
          {:error, _, _} = err ->
            err

          :ok ->
            created =
              Enum.map(entities, fn e ->
                e = Map.put_new(e, "guid", new_guid())
                Store.put(:smalt_purview_entities, e["guid"], e)
                mint_process_edges(e)
                e
              end)

            {:ok, 201,
             %{
               "guidAssignments" => Map.new(created, fn e -> {e["guid"], e["guid"]} end),
               "mutatedEntities" => %{"CREATE" => created}
             }}
        end
    end
  end

  def bulk_entities(_body, _opts) do
    {:error, 400,
     %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entities array required"}}}
  end

  defp validate_all_types(entities) do
    Enum.reduce_while(entities, :ok, fn e, :ok ->
      case validate_type(e) do
        :ok -> {:cont, :ok}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
  end

  # PUT /entity/bulk semantics: only validate a typeName the patch actually
  # carries; absence inherits the stored entity's registered type.
  defp validate_patch_types(entities) do
    entities
    |> Enum.filter(&Map.has_key?(&1, "typeName"))
    |> validate_all_types()
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
  Attaches classifications (Atlas `POST /entity/guid/classifications` — the
  body is a LIST of classification maps, each with a registered `typeName`).
  Updates the stored entity's `classifications` list. `{:ok, 204, nil}`.
  """
  def add_classifications(guid, classifications, _opts \\ %{})

  def add_classifications(guid, classifications, _opts) when is_list(classifications) do
    with {:ok, entity} <- fetch_entity(guid),
         :ok <- validate_classdefs(classifications) do
      entity = attach_classifications(entity, classifications)
      Store.put(:smalt_purview_entities, entity["guid"], entity)
      {:ok, 204, nil}
    end
  end

  def add_classifications(_guid, _classifications, _opts) do
    {:error, 400, class_error("classifications body must be an array of classification maps")}
  end

  @doc """
  Bulk classification (Atlas `POST /entity/bulk/classification`):
  `%{"classification" => classification, "entityGuids" => [guid, ...]}` ->
  `{:ok, 201, nil}` with no partial attach on any invalid guid/classDef.
  """
  def bulk_classification(body, _opts \\ %{})

  def bulk_classification(
        %{"classification" => classification, "entityGuids" => guids} = body,
        _opts
      )
      when is_map(classification) and is_list(guids) do
    if is_map_key(body, "entityGuids") and Enum.all?(guids, &is_binary/1) do
      with {:ok, entities} <- fetch_entities(guids),
           :ok <- validate_classdefs([classification]) do
        Enum.each(entities, fn entity ->
          entity = attach_classifications(entity, [classification])
          Store.put(:smalt_purview_entities, entity["guid"], entity)
        end)

        {:ok, 201, nil}
      end
    else
      {:error, 400, class_error("entityGuids must be an array of guid strings")}
    end
  end

  def bulk_classification(_body, _opts) do
    {:error, 400,
     %{
       "error" => %{
         "code" => "ATLAS-400-00-001",
         "message" => "bulk classification requires `classification` + `entityGuids`"
       }
     }}
  end

  @doc """
  PUT /entity/bulk semantics: merge attributes into existing entities by guid,
  re-validating typeName and re-minting Process lineage edges. Unknown guid ->
  404 `ATLAS-404-00-005` with no partial update.
  """
  def update_entities(body, opts \\ %{})

  def update_entities(%{"entities" => entities}, _opts) when is_list(entities) do
    cond do
      length(entities) > @max_bulk ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "ATLAS-400-00-001",
             "message" => "bulk is limited to #{@max_bulk} entities, got #{length(entities)}"
           }
         }}

      not Enum.all?(entities, &is_map/1) ->
        {:error, 400, entity_body_error()}

      true ->
        # PUT patches may omit `typeName` (inherits the stored entity's type);
        # a patch that CARRIES one still gets it validated.
        with :ok <- validate_patch_types(entities),
             {:ok, existing} <- fetch_entities(Enum.map(entities, & &1["guid"])) do
          updated =
            Enum.zip(entities, existing)
            |> Enum.map(fn {patch, entity} ->
              merged = deep_merge(entity, patch)
              Store.put(:smalt_purview_entities, merged["guid"], merged)
              mint_process_edges(merged)
              merged
            end)

          {:ok, 200,
           %{
             "guidAssignments" => Map.new(updated, fn e -> {e["guid"], e["guid"]} end),
             "mutatedEntities" => %{"UPDATE" => updated}
           }}
        end
    end
  end

  def update_entities(_body, _opts) do
    {:error, 400,
     %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "entities array required"}}}
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  defp fetch_entity(guid) do
    case Store.get(:smalt_purview_entities, guid) do
      {:ok, entity} -> {:ok, entity}
      :error -> {:error, 404, not_found(guid)}
    end
  end

  defp fetch_entities(guids) do
    # Missing guid anywhere -> 404 with no partial attach/update.
    {ok, missing} =
      Enum.split_with(guids, fn g ->
        match?({:ok, _}, Store.get(:smalt_purview_entities, g))
      end)

    if length(ok) == length(guids) do
      {:ok, Enum.map(guids, fn g -> {:ok, e} = Store.get(:smalt_purview_entities, g); e end)}
    else
      {:error, 404, not_found(List.first(missing))}
    end
  end

  defp not_found(guid) do
    %{"error" => %{"code" => "ATLAS-404-00-005", "message" => "entity #{guid} not found"}}
  end

  defp validate_classdefs(classifications) do
    Enum.reduce_while(classifications, :ok, fn c, :ok ->
      name = if is_map(c), do: c["typeName"], else: nil

      cond do
        not is_map(c) ->
          {:halt, {:error, 400, class_error("classification must be a map")}}

        not is_binary(name) ->
          {:halt, {:error, 400, class_error("classification requires a binary `typeName`")}}

        match?({:ok, _}, Store.get(:smalt_purview_entities, "CLASSDEF:" <> name)) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, 400, class_error("classification `#{name}` is not a registered classDef")}}
      end
    end)
  end

  defp attach_classifications(entity, classifications) do
    existing = List.wrap(entity["classifications"])
    merged = existing ++ List.wrap(classifications)
    Map.put(entity, "classifications", merged)
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
  # Glossary (Atlas v2 glossary parity)
  # ---------------------------------------------------------------------------

  @doc """
  GET /glossary — the glossary record with its term summary list
  (`termGuid` + `displayText` per term). The glossary guid is minted once and
  stored, so it is stable across calls.
  """
  def glossary(_opts \\ %{}) do
    terms =
      list_terms_raw()
      |> Enum.sort_by(& &1["name"])

    {:ok, 200,
     %{
       "guid" => glossary_guid(),
       "name" => "Glossary",
       "qualifiedName" => "Glossary",
       "language" => "en",
       "terms" => Enum.map(terms, &%{"termGuid" => &1["guid"], "displayText" => &1["name"]})
     }}
  end

  @doc "GET /glossary/terms — every term as a full map, sorted by name."
  def list_terms(_opts \\ %{}) do
    {:ok, 200, list_terms_raw() |> Enum.sort_by(& &1["name"])}
  end

  @doc """
  PUT /glossary/term — create (201) or update (200) a glossary term.
  `%{"name" => ..., "definition" => ..., "abbreviation" => ...,
     "seeAlso" => [termGuid...], "relatedTerms" => [termGuid...],
     "assignedEntities" => [entityGuid | %{"guid" => ...}]}`.

  Every `assignedEntities` guid is validated against the entity store BEFORE
  any write (unknown guid -> 404 `ATLAS-404-00-005`, no partial attach).
  Attachments mint real `AtlasGlossaryTerm` lineage edges; an update replaces
  the term's attachment set.
  """
  def put_term(body, _opts \\ %{})

  def put_term(%{"name" => name} = body, _opts) when is_binary(name) do
    with {:ok, term, status} <- resolve_existing_term(body, name),
         :ok <- validate_assignments(body) do
      assigned =
        body
        |> Map.get("assignedEntities", [])
        |> List.wrap()
        |> Enum.map(&normalize_assigned/1)

      term =
        term
        |> Map.merge(%{
          "name" => name,
          "definition" => body["definition"],
          "abbreviation" => body["abbreviation"],
          "status" => body["status"] || "Approved",
          "seeAlso" => List.wrap(body["seeAlso"] || []),
          "relatedTerms" => List.wrap(body["relatedTerms"] || []),
          "assignedEntities" => assigned,
          "qualifiedName" => name
        })

      replace_term_edges(term)
      Store.put(:smalt_purview_entities, @term_prefix <> term["guid"], term)
      {:ok, status, term}
    end
  end

  def put_term(_body, _opts) do
    {:error, 400,
     %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "glossary term requires a binary `name`"}}}
  end

  defp resolve_existing_term(body, _name) do
    guid = body["guid"]

    if is_binary(guid) and match?({:ok, _}, Store.get(:smalt_purview_entities, @term_prefix <> guid)) do
      {:ok, 200, term} = get_term(guid)
      {:ok, term, 200}
    else
      {:ok, %{"guid" => new_guid()}, 201}
    end
  end

  defp validate_assignments(body) do
    body
    |> Map.get("assignedEntities", [])
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      g = guid_of(ref)

      if is_binary(g) and match?({:ok, _}, Store.get(:smalt_purview_entities, g)) do
        {:cont, :ok}
      else
        {:halt, {:error, 404, not_found(to_string(g || inspect(ref)))}}
      end
    end)
  end

  defp normalize_assigned(%{"guid" => g} = m), do: %{"guid" => g, "typeName" => m["typeName"] || entity_type_of(g)}
  defp normalize_assigned(g) when is_binary(g), do: %{"guid" => g, "typeName" => entity_type_of(g)}
  defp normalize_assigned(other), do: %{"guid" => to_string(other)}

  defp entity_type_of(g) do
    case Store.get(:smalt_purview_entities, g) do
      {:ok, %{"typeName" => t}} -> t
      _ -> "Unknown"
    end
  end

  # Removes the term's previous AtlasGlossaryTerm edges, then mints one edge
  # per assigned entity. Keyed "from/to/type" — idempotent overwrite.
  defp replace_term_edges(term) do
    guid = term["guid"]
    delete_term_edges(guid, :any)

    Enum.each(term["assignedEntities"], fn %{"guid" => g} ->
      put_edge(guid, g, @term_edge_type, %{
        "relationshipId" => "#{guid}->#{g}:#{@term_edge_type}"
      })
    end)
  end

  @doc "GET /glossary/terms/:guid — the term map, or 404 `ATLAS-404-GLOSSARY-TERM`."
  def get_term(guid, _opts \\ %{}) do
    case Store.get(:smalt_purview_entities, @term_prefix <> guid) do
      {:ok, term} ->
        {:ok, 200, term}

      :error ->
        {:error, 404,
         %{
           "error" => %{
             "code" => "ATLAS-404-GLOSSARY-TERM",
             "message" => "glossary term #{guid} not found"
           }
         }}
    end
  end

  @doc """
  DELETE /glossary/terms/:guid — removes the term AND its `AtlasGlossaryTerm`
  lineage edges (the link disappears from lineage). 204.
  """
  def delete_term(guid, _opts \\ %{}) do
    with {:ok, _term} <- fetch_term(guid) do
      Store.delete(:smalt_purview_entities, @term_prefix <> guid)
      delete_term_edges(guid, :from)
      {:ok, 204, nil}
    end
  end

  defp fetch_term(guid) do
    case Store.get(:smalt_purview_entities, @term_prefix <> guid) do
      {:ok, term} -> {:ok, term}
      :error -> {:error, 404, term_not_found(guid)}
    end
  end

  defp term_not_found(guid) do
    %{"error" => %{"code" => "ATLAS-404-GLOSSARY-TERM", "message" => "glossary term #{guid} not found"}}
  end

  defp list_terms_raw do
    prefix_values(:smalt_purview_entities, @term_prefix)
  end

  defp glossary_guid do
    case Store.get(:smalt_purview_entities, @glossary_key) do
      {:ok, %{"guid" => g}} ->
        g

      :error ->
        g = new_guid()
        Store.put(:smalt_purview_entities, @glossary_key, %{"guid" => g, "name" => "Glossary"})
        g
    end
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

    {relations, visited} =
      walk(MapSet.new([base]), MapSet.new([base]), direction, depth, edges, MapSet.new())

    guid_entity_map =
      Map.new(visited, fn g ->
        case Store.get(:smalt_purview_entities, g) do
          {:ok, entity} ->
            {g, entity}

          :error ->
            case Store.get(:smalt_purview_entities, @term_prefix <> g) do
              {:ok, term} -> {g, term}
              :error -> {g, %{"guid" => g, "typeName" => "Unknown"}}
            end
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
            "input" ->
              if to == guid and not MapSet.member?(visited, from), do: [from], else: []

            "output" ->
              if from == guid and not MapSet.member?(visited, to), do: [to], else: []

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

  # ---------------------------------------------------------------------------
  # Process entities -> lineage edges
  # ---------------------------------------------------------------------------

  # A Process entity's `relationshipAttributes` input/output lists (Atlas wire
  # shape: %{"guid" => g} or bare guid strings) mint real lineage edges:
  #   input  --Process.Input-->  process  --Process.Output-->  output
  # so GET /atlas/v2/lineage/{direction}/{guid} sees both hops. Unknown guids
  # in the lists are minted as edges anyway (Atlas allows dangling process
  # endpoints at PUT time; lineage renders them as "Unknown" entities).
  defp mint_process_edges(%{"typeName" => "Process", "guid" => guid} = entity) do
    attrs = entity["relationshipAttributes"] || %{}

    inputs = guid_list(attrs["input"])
    outputs = guid_list(attrs["output"])

    Enum.each(inputs, &put_edge(&1, guid, "Process.Input"))
    Enum.each(outputs, &put_edge(guid, &1, "Process.Output"))
  end

  defp mint_process_edges(_entity), do: :ok

  defp guid_list(list) when is_list(list) do
    for item <- list, g = guid_of(item), is_binary(g), do: g
  end

  defp guid_list(_), do: []

  defp guid_of(%{"guid" => g}) when is_binary(g), do: g
  defp guid_of(%{"id" => g}) when is_binary(g), do: g
  defp guid_of(g) when is_binary(g), do: g
  defp guid_of(_), do: nil

  defp class_error(message) do
    %{"error" => %{"code" => "ATLAS-400-CLASS", "message" => message}}
  end

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
