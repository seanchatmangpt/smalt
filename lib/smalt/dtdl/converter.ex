defmodule Smalt.DTDL do
  @moduledoc """
  DTDL v3 → RDF triples + SHACL shape Turtle converter (W2 lane, tier2-scout
  §2 mapping table).

      {:ok, %{ttl: ttl, triples: triples}} = Smalt.DTDL.convert(json)
      {:ok, guards} = Smalt.POWL2.LawCompiler.compile_all(ttl)
      guards["Thermostat;1"].(%{"temperature" => 21.5})   # => :ok

  Mapping (scout table, row-for-row):

    * `@id dtmi:...;1` → `<dtmi:...;1>` IRI — dtmi IRIs contain `;`, so they
      are always `<...>`-quoted, never prefixed local names.
    * `@type Interface` → `a sh:NodeShape` + `sh:targetClass`.
    * contents `Telemetry` / `Property` / `Relationship` / `Component` →
      `sh:property` blocks.
    * telemetry/property `schema` primitive → `sh:datatype xsd:<dt>`
      (the LawCompiler 6th constraint class; `string→xsd:string`,
      `dateTime→xsd:dateTime`, `double→xsd:double`, ...). Non-primitive
      schemas (object/array/map/enum/geospatial) are a typed convert
      refusal — minimal scope, fail-closed.
    * Property `writable: true` → paired `sh:minCount 1` block (required
      presence; the datatype block and the minCount block are separate
      blocks — LawCompiler admits one constraint class per block).
    * Relationship → `sh:qualifiedValueShape` block qualifying the edge
      value: the edge must be a map carrying a string `target` (the
      twin-relationship instance shape). Divergence (disclosed): the scout
      table's `sh:class`/`sh:node` target-shape reference is materialized
      as a structural inner constraint because LawCompiler has no
      cross-shape reference class; `minMultiplicity` ≥ 1 → `sh:minCount 1`.
    * Component → `sh:qualifiedValueShape` over the component schema
      interface's flattened constraint set (instance map must satisfy the
      referenced interface's shape).
    * `extends` → shape chaining materialized as constraint flattening
      (parent constraints are inlined into the child shape; the
      `dtdl:extends` triple is still emitted in the triple list).

  Returns:

    * `{:ok, %{ttl, triples, interfaces, shapes}}` — `ttl` compiles via
      `Smalt.POWL2.LawCompiler.compile_all/1`; `triples` is the RDF
      projection (`{s, p, o}` binaries).
    * `{:error, {:invalid_json, msg}}`
    * `{:error, {:missing_at_type, id}}` — malformed DTDL (typed refusal).
    * `{:error, {:missing_at_id, id}}` / `{:error, {:missing_name, id}}`
    * `{:error, {:unknown_extends, ref}}` — extends target not in document.
    * `{:error, {:circular_extends, ref}}` — cyclic or self-referential
      `extends` chain (fail-closed, never hangs).
    * `{:error, {:unsupported_schema, schema}}` — non-primitive schema.
  """

  alias Smalt.DTDL.ConvertError

  @primitives %{
    "string" => "string",
    "boolean" => "boolean",
    "dateTime" => "dateTime",
    "date" => "date",
    "time" => "time",
    "duration" => "string",
    "integer" => "integer",
    "long" => "integer",
    "float" => "double",
    "double" => "double",
    "decimal" => "decimal"
  }

  @type triple :: {String.t(), String.t(), String.t()}

  @spec convert(String.t()) ::
          {:ok, %{ttl: String.t(), triples: [triple()], interfaces: [String.t()],
                shapes: pos_integer()}}
          | {:error, term()}
  def convert(json) when is_binary(json) do
    try do
      with {:ok, doc} <- decode(json),
           {:ok, interfaces} <- collect_interfaces(doc) do
        resolved =
          Map.new(interfaces, fn iface -> {iface["@id"], resolve_iface(iface, interfaces)} end)

        {ttls, triples, names} =
          Enum.reduce(interfaces, {[], [], []}, fn iface, {ttls, trips, names} ->
            iri = iface["@id"]
            {ttl, trips2, name} = emit_shape(iri, Map.fetch!(resolved, iri), iface, resolved)
            {[ttl | ttls], trips ++ trips2, [name | names]}
          end)

        ttl =
          IO.iodata_to_binary([
            "@prefix sh: <http://www.w3.org/ns/shacl#> .\n",
            "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .\n",
            "@prefix dtdl: <dtmi:dtdl:> .\n\n",
            ttls |> Enum.reverse() |> Enum.intersperse("\n")
          ])

        {:ok, %{
          ttl: ttl,
          triples: triples,
          interfaces: Enum.map(interfaces, & &1["@id"]),
          shapes: length(names)
        }}
      end
    rescue
      e in ConvertError -> {:error, ConvertError.to_reason(e)}
    end
  end

  # -- decode + interface collection ------------------------------------------

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, doc} -> {:ok, doc}
      {:error, e} -> {:error, {:invalid_json, Exception.message(e)}}
    end
  end

  defp collect_interfaces(doc) when is_map(doc), do: collect_interfaces([doc])

  defp collect_interfaces(doc) when is_list(doc) do
    Enum.reduce_while(doc, {:ok, []}, fn node, {:ok, acc} ->
      case validate_interface(node) do
        {:ok, iface} -> {:cont, {:ok, [iface | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ifaces} -> {:ok, Enum.reverse(ifaces)}
      error -> error
    end
  end

  defp collect_interfaces(_other), do: {:error, {:missing_at_type, "<document>"}}

  defp validate_interface(%{"@type" => "Interface"} = node), do: validate_id(node)
  defp validate_interface(%{"@type" => ts} = node) when is_list(ts) do
    if "Interface" in ts,
      do: validate_id(node),
      else: {:error, {:missing_at_type, Map.get(node, "@id", "<unknown>")}}
  end

  defp validate_interface(node) when is_map(node),
    do: {:error, {:missing_at_type, Map.get(node, "@id", "<unknown>")}}

  defp validate_interface(_node), do: {:error, {:missing_at_type, "<document>"}}

  defp validate_id(%{"@id" => id} = node) when is_binary(id), do: {:ok, node}
  defp validate_id(node), do: {:error, {:missing_at_id, Map.get(node, "@id", "<unknown>")}}

  # -- extends resolution (flatten parents into child) --------------------------

  # EXPL5-T2: visited-set threaded through the extends chain — a cyclic or
  # self-referential `extends` graph raises a typed :circular_extends instead of
  # recursing forever on remote JSON input.
  defp resolve_iface(iface, interfaces, visited \\ MapSet.new()) do
    id = iface["@id"]
    visited = MapSet.put(visited, id)

    parents =
      iface
      |> Map.get("extends", [])
      |> List.wrap()
      |> Enum.map(fn ref ->
        cond do
          ref in visited ->
            raise ConvertError, reason: :circular_extends, detail: ref

          true ->
            case Enum.find(interfaces, &(&1["@id"] == ref)) do
              nil -> raise ConvertError, reason: :unknown_extends, detail: ref
              parent -> resolve_iface(parent, interfaces, visited)
            end
        end
      end)

    own = List.wrap(Map.get(iface, "contents", []))
    inherited = Enum.flat_map(parents, & &1.flattened_contents)
    %{iri: iface["@id"], flattened_contents: own ++ inherited}
  end

  # -- shape emission ------------------------------------------------------------

  defp emit_shape(iri, resolved, iface, resolved_map) do
    {blocks, triples} =
      resolved.flattened_contents
      |> Enum.with_index()
      |> Enum.flat_map_reduce([], fn {content, idx}, trips ->
        {block_texts, content_triples} =
          emit_content(resolved_map, iri, content, "#{iri}/contents#{idx}")

        {block_texts, trips ++ content_triples}
      end)

    type_triples =
      [{iri, "rdf:type", "dtdl:Interface"}] ++
        for parent <- List.wrap(Map.get(iface, "extends", [])) do
          {iri, "dtdl:extends", parent}
        end

    ttl =
      IO.iodata_to_binary([
        "<", iri, "> a sh:NodeShape ;\n",
        "  sh:targetClass <", iri, ">",
        for block <- blocks do
          " ;\n" <> block
        end,
        " .\n"
      ])

    {ttl, type_triples ++ triples, shape_name(iri)}
  end

  # One LawCompiler constraint per sh:property block (one class per block).
  # `opts[:ind]` block indent (default 1); `opts[:message]` emit sh:message
  # (inner qvs members render deeper and messageless — the outer qvs block
  # carries the diagnostic).
  defp emit_content(resolved_map, iri, content, content_iri, opts \\ %{ind: 1, message: true})

  defp emit_content(resolved_map, _iri, content, content_iri, %{ind: ind, message: msg?})
       when is_map(content) do
    unless content_type?(Map.get(content, "@type")) do
      raise ConvertError,
        reason: :missing_at_type,
        detail: Map.get(content, "@id", content_iri)
    end

    name = Map.get(content, "name")

    unless is_binary(name) do
      raise ConvertError, reason: :missing_name, detail: content_iri
    end

    base_triples = [
      {content_iri, "rdf:type", "dtdl:" <> type_name(Map.get(content, "@type"))},
      {content_iri, "dtdl:name", name}
    ]

    case type_name(Map.get(content, "@type")) do
      "Telemetry" ->
        dt = primitive_schema(content, content_iri)

        {[
           datatype_block(name, dt, ind, msg? && "telemetry #{name} must be #{dt}")
         ], base_triples ++ [{content_iri, "dtdl:schema", "xsd:" <> dt}]}

      "Property" ->
        dt = primitive_schema(content, content_iri)
        blocks = [datatype_block(name, dt, ind, msg? && "property #{name} must be #{dt}")]
        tr = base_triples ++ [{content_iri, "dtdl:schema", "xsd:" <> dt}]

        if content["writable"] == true do
          {blocks ++
             [min_count_block(name, 1, ind, msg? && "writable property #{name} is required")],
           tr ++ [{content_iri, "dtdl:writable", "true"}]}
        else
          {blocks, tr}
        end

      "Relationship" ->
        # Relationship → sh:qualifiedValueShape: the edge value must be a map
        # carrying a string `target` (disclosed structural materialization of
        # the scout table's target-shape reference; LawCompiler has no
        # cross-shape reference class).
        blocks =
          [
            qvs_block(name, [datatype_line("target", "string", ind + 2)], ind,
              msg? && "relationship #{name} edge fails the target shape")
          ] ++
            if is_integer(content["minMultiplicity"]) and content["minMultiplicity"] >= 1 do
              [min_count_block(name, 1, ind, msg? && "relationship #{name} is required")]
            else
              []
            end

        target_triples =
          if is_binary(content["target"]), do: [{content_iri, "dtdl:target", content["target"]}], else: []

        {blocks, base_triples ++ target_triples}

      "Component" ->
        schema_ref = content["schema"]

        unless is_binary(schema_ref) do
          raise ConvertError, reason: :missing_name, detail: "#{content_iri} (component schema)"
        end

        case Map.fetch(resolved_map, schema_ref) do
          :error ->
            raise ConvertError, reason: :unknown_extends, detail: schema_ref

          {:ok, schema_iface} ->
            {inner_texts, _} =
              schema_iface.flattened_contents
              |> Enum.with_index()
              |> Enum.flat_map_reduce([], fn {c, i}, trips ->
                {texts, tr} =
                  emit_content(resolved_map, schema_iface.iri, c, "#{schema_ref}/i#{i}", %{
                    ind: ind + 2,
                    message: false
                  })

                {texts, trips ++ tr}
              end)

            blocks = [
              qvs_block(name, inner_texts, ind,
                msg? && "component #{name} instance fails its schema shape")
            ]

            {blocks, base_triples ++ [{content_iri, "dtdl:schema", schema_ref}]}
        end

      "Command" ->
        # Commands are invocations, not data constraints — no guard, triple only.
        {[], base_triples}
    end
  end

  defp emit_content(_resolved_map, _iri, content, content_iri, %{ind: 1}) when is_map(content),
    do: raise(ConvertError, reason: :missing_at_type, detail: Map.get(content, "@id", content_iri))

  defp emit_content(_resolved_map, _iri, _content, content_iri, %{ind: 1}),
    do: raise(ConvertError, reason: :missing_at_type, detail: content_iri)

  defp content_type?(t) when is_binary(t), do: t in ~w(Telemetry Property Relationship Component Command)
  defp content_type?(t) when is_list(t), do: Enum.any?(t, &content_type?/1)
  defp content_type?(_), do: false

  defp type_name(t) when is_binary(t), do: t
  defp type_name(t) when is_list(t), do: Enum.find(t, &is_binary/1) || ""

  @indent2 "  "
  defp indent(n), do: String.duplicate(@indent2, n)

  defp datatype_block(path, dt, ind, message) do
    IO.iodata_to_binary([
      indent(ind), "sh:property [\n",
      indent(ind + 1), "sh:path ", path, " ;\n",
      indent(ind + 1), "sh:datatype xsd:", dt,
      message_line(message, ind + 1),
      indent(ind), "]"
    ])
  end

  defp min_count_block(path, count, ind, message) do
    IO.iodata_to_binary([
      indent(ind), "sh:property [\n",
      indent(ind + 1), "sh:path ", path, " ;\n",
      indent(ind + 1), "sh:minCount ", Integer.to_string(count),
      message_line(message, ind + 1),
      indent(ind), "]"
    ])
  end

  # sh:qualifiedValueShape block wrapping inner sh:property block texts.
  defp qvs_block(path, inner_blocks, ind, message) when is_list(inner_blocks) do
    IO.iodata_to_binary([
      indent(ind), "sh:property [\n",
      indent(ind + 1), "sh:path ", path, " ;\n",
      indent(ind + 1), "sh:qualifiedValueShape [\n",
      Enum.intersperse(inner_blocks, " ;\n"),
      "\n",
      indent(ind + 1), "] ;\n",
      message_line(message, ind + 1),
      indent(ind), "]"
    ])
  end

  defp message_line(message, _ind) when message in [nil, false], do: "\n"

  defp message_line(message, ind),
    do: " ;\n" <> indent(ind) <> "sh:message \"" <> message <> "\"\n"

  defp datatype_line(path, dt, ind) do
    IO.iodata_to_binary([
      indent(ind), "sh:property [\n",
      indent(ind + 1), "sh:path ", path, " ;\n",
      indent(ind + 1), "sh:datatype xsd:", dt, "\n",
      indent(ind), "]"
    ])
  end

  defp primitive_schema(content, content_iri) do
    schema = Map.get(content, "schema")
    dt = is_binary(schema) && @primitives[schema]

    unless is_binary(dt) do
      raise ConvertError,
        reason: :unsupported_schema,
        detail: inspect(schema || :missing) <> " at " <> content_iri
    end

    dt
  end

  defp shape_name(iri), do: iri |> String.split(":", parts: 3) |> List.last()

  defmodule ConvertError do
    defexception [:reason, :detail]

    def message(%__MODULE__{reason: reason, detail: detail}),
      do: "#{reason}:#{detail}"

    @doc false
    def to_reason(%__MODULE__{reason: reason, detail: detail}), do: {reason, detail}
  end
end
