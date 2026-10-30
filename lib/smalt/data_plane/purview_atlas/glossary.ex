defmodule Smalt.DataPlane.Purview.Glossary do
  @moduledoc """
  Atlas v2 glossary parity face — extracted verbatim from
  `Smalt.Purview` parent along the `# --- Glossary` fence (T10 tail split,
  v26.10.29 r10d). Same Store keyspace laws; the guid law and prefix scan stay
  the parent's (`Purview.guid_of/1`, `Purview.prefix_values/2`, widened
  defp->def, no behavior change).
  """

  @term_edge_type "AtlasGlossaryTerm"
  @term_prefix "GTERM:"
  @glossary_key "GLOSSARY:"

  alias Smalt.Store
  alias Smalt.DataPlane.Purview

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
         :ok <- validate_template_attrs(body),
         :ok <- validate_assignments(body) do
      assigned =
        body
        |> Map.get("assignedEntities", [])
        |> List.wrap()
        |> Enum.map(&normalize_assigned/1)

      template_attrs =
        case term_template() do
          {:ok, 200, defs} -> Map.take(body, Enum.map(defs, & &1["name"]))
          _ -> %{}
        end

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
        |> Map.merge(template_attrs)

      replace_term_edges(term)
      Store.put(:smalt_purview_entities, @term_prefix <> term["guid"], term)
      {:ok, status, term}
    end
  end

  def put_term(_body, _opts) do
    {:error, 400,
     %{"error" => %{"code" => "ATLAS-400-00-001", "message" => "glossary term requires a binary `name`"}}}
  end

  @template_types ~w(string integer boolean)

  @doc """
  PUT /glossary/term-template — stores the glossary `termTemplate` (an array of
  attribute defs `%{"name" => ..., "type" => "string"|"integer"|"boolean",
  "isOptional" => bool}`). Malformed defs (non-list, non-map element, missing
  binary `name`, unknown `type`, non-boolean `isOptional`) are a typed 400
  `ATLAS-400-GLOSSARY-TEMPLATE` with no write. `{:ok, 201, glossary}`.
  """
  def set_term_template(defs, _opts \\ %{})

  def set_term_template(defs, _opts) do
    case validate_template_defs(defs) do
      :ok ->
        Store.put(:smalt_purview_entities, @glossary_key, %{
          "guid" => glossary_guid(),
          "name" => "Glossary",
          "termTemplate" => defs
        })

        {:ok, 201, %{"termTemplate" => defs}}

      {:error, _, _} = err ->
        err
    end
  end

  @doc "GET /glossary/term-template — the stored defs, or `[]` when unset."
  def term_template(_opts \\ %{}) do
    case Store.get(:smalt_purview_entities, @glossary_key) do
      {:ok, %{"termTemplate" => defs}} -> {:ok, 200, defs}
      _ -> {:ok, 200, []}
    end
  end

  defp validate_template_defs(defs) when is_list(defs) do
    if Enum.all?(defs, &valid_template_def?/1) do
      :ok
    else
      {:error, 400, template_error("termTemplate must be an array of defs with binary `name`, type in #{inspect(@template_types)} and boolean `isOptional`")}
    end
  end

  defp validate_template_defs(_defs) do
    {:error, 400, template_error("termTemplate must be an array of attribute defs")}
  end

  defp valid_template_def?(%{"name" => name, "type" => type} = def)
       when is_binary(name) and type in @template_types do
    case def["isOptional"] do
      b when is_boolean(b) -> true
      nil -> true
      _ -> false
    end
  end

  defp valid_template_def?(_), do: false

  # Terms are validated against the glossary termTemplate: every required
  # (isOptional != true) def must be present in the PUT body with the declared
  # type; optional attrs may be omitted. Provided template attrs are carried
  # onto the stored term so GET echoes them.
  defp validate_template_attrs(body) do
    case term_template() do
      {:ok, 200, []} ->
        :ok

      {:ok, 200, defs} ->
        defs
        |> Enum.reject(& &1["isOptional"])
        |> Enum.reduce_while(:ok, fn def, :ok ->
          name = def["name"]

          cond do
            not Map.has_key?(body, name) ->
              {:halt,
               {:error, 400,
                template_error("term missing required template attribute `#{name}`")}}

            template_type_ok?(def["type"], body[name]) ->
              {:cont, :ok}

            true ->
              {:halt,
               {:error, 400,
                template_error(
                  "template attribute `#{name}` must be of type #{def["type"]}"
                )}}
          end
        end)
    end
  end

  defp template_type_ok?("string", v), do: is_binary(v)
  defp template_type_ok?("integer", v), do: is_integer(v)
  defp template_type_ok?("boolean", v), do: is_boolean(v)

  defp template_error(message) do
    %{
      "error" => %{
        "code" => "ATLAS-400-GLOSSARY-TEMPLATE",
        "message" => message
      }
    }
  end

  defp resolve_existing_term(body, _name) do
    guid = body["guid"]

    if is_binary(guid) and match?({:ok, _}, Store.get(:smalt_purview_entities, @term_prefix <> guid)) do
      {:ok, 200, term} = get_term(guid)
      {:ok, term, 200}
    else
      {:ok, %{"guid" => Purview.new_guid()}, 201}
    end
  end

  defp validate_assignments(body) do
    body
    |> Map.get("assignedEntities", [])
    |> List.wrap()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      g = Purview.guid_of(ref)

      if is_binary(g) and match?({:ok, _}, Store.get(:smalt_purview_entities, g)) do
        {:cont, :ok}
      else
        {:halt, {:error, 404, Purview.not_found(to_string(g || inspect(ref)))}}
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
    Purview.delete_term_edges(guid, :any)

    Enum.each(term["assignedEntities"], fn %{"guid" => g} ->
      Purview.put_edge(guid, g, @term_edge_type, %{
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
      Purview.delete_term_edges(guid, :from)
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
    Purview.prefix_values(:smalt_purview_entities, @term_prefix)
  end

  defp glossary_guid do
    case Store.get(:smalt_purview_entities, @glossary_key) do
      {:ok, %{"guid" => g}} ->
        g

      :error ->
        g = Purview.new_guid()
        Store.put(:smalt_purview_entities, @glossary_key, %{"guid" => g, "name" => "Glossary"})
        g
    end
  end
end
