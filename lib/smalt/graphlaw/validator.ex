defmodule Smalt.GraphLaw.Validator.ShapeFile do
  @moduledoc """
  Shape-file-specific Turtle subset parser for
  `priv/shacl/smalt-shapes.ttl`.

  Understands exactly the statement forms used by that file:

      smalt:FooShape a sh:NodeShape ;
          sh:targetClass smalt:Foo ;
          sh:closed true ;
          sh:property [ sh:path smalt:p ; sh:minCount 1 ; sh:message "..." ; ] ,
                      [ ... ] .

  Plus `sh:description "..."` at body level and the pack's doubled-bracket
  multi-block form `]    ] , [`. Quote-aware `#` comments, prefixed names,
  `<IRI>`s, string literals, integers, punctuation `. ; , [ ]`. Anything else
  raises — a parse error fails COMPILATION, not runtime.

  Returns:

      %{shape_name => %{target_class: String.t() | nil, closed: boolean(),
        required: [%{path: String.t(), min_count: pos_integer(),
                    datatype: :string | :integer | :boolean | nil,
                    message: String.t() | nil}]}}
  """

  @punct ["[", "]", ",", ";", "."]

  def parse!(text, source) do
    text
    |> tokenize()
    |> split_statements()
    |> Enum.reduce(%{}, fn tokens, acc ->
      case parse_statement(tokens, source) do
        :skip -> acc
        {name, shape} -> Map.put(acc, name, shape)
      end
    end)
  end

  # -- tokenizer -----------------------------------------------------------------

  defp tokenize(text) do
    String.graphemes(text)
    |> tokenize([], [])
    |> Enum.reverse()
  end

  defp tokenize(["\"" | rest], tokens, acc) do
    {string, rest} = read_string(rest, [])
    tokenize(rest, [{:string, string} | flush(acc, tokens)], [])
  end

  defp tokenize([ch | rest], tokens, acc) do
    cond do
      ch in [" ", "\t", "\n", "\r"] ->
        tokenize(rest, flush(acc, tokens), [])

      ch == "#" ->
        tokenize(Enum.drop_while(rest, &(&1 != "\n")), flush(acc, tokens), [])

      ch == "<" ->
        {iri, rest} = read_iri(rest, [])
        tokenize(rest, [{:iri, iri} | flush(acc, tokens)], [])

      ch in @punct ->
        tokenize(rest, [{:punct, ch} | flush(acc, tokens)], [])

      true ->
        tokenize(rest, tokens, [ch | acc])
    end
  end

  defp tokenize([], tokens, acc), do: flush(acc, tokens)

  defp flush([], tokens), do: tokens

  defp flush(acc, tokens), do: [{:word, Enum.reverse(acc) |> Enum.join()} | tokens]

  defp read_string(["\\", escaped | rest], char_acc), do: read_string(rest, [escaped | char_acc])
  defp read_string(["\"" | rest], char_acc), do: {Enum.reverse(char_acc) |> Enum.join(), rest}
  defp read_string([ch | rest], char_acc), do: read_string(rest, [ch | char_acc])

  defp read_string([], _char_acc) do
    raise CompileError, file: "smalt-shapes.ttl", description: "unterminated string literal"
  end

  defp read_iri([">" | rest], char_acc), do: {Enum.reverse(char_acc) |> Enum.join(), rest}
  defp read_iri([ch | rest], char_acc), do: read_iri(rest, [ch | char_acc])

  defp read_iri([], _char_acc) do
    raise CompileError, file: "smalt-shapes.ttl", description: "unterminated IRI"
  end

  # -- statement grouping -----------------------------------------------------------

  defp split_statements([]), do: []

  defp split_statements(tokens) do
    {statement, rest} = Enum.split_while(tokens, &(&1 != {:punct, "."}))
    rest = Enum.drop(rest, 1)

    if statement == [] do
      split_statements(rest)
    else
      [statement | split_statements(rest)]
    end
  end

  # -- statement parsing -------------------------------------------------------------

  defp parse_statement([{:word, subject}, {:word, "a"}, {:word, "sh:NodeShape"} | rest], source) do
    {subject |> full_iri() |> local_name(), parse_body(rest, source, empty_shape())}
  end

  defp parse_statement(_tokens, _source), do: :skip

  defp empty_shape, do: %{target_class: nil, closed: false, required: []}

  @datatype_keywords ~w(sh:path sh:minCount sh:maxCount sh:datatype sh:message)

  defp parse_body([], _source, shape), do: shape

  defp parse_body([{:punct, ";"} | rest], source, shape), do: parse_body(rest, source, shape)

  # The pack's shapes file writes multi-block shapes as `]    ] , [` (a
  # doubled closing bracket). Tolerate the stray body-level `]` and a
  # following `, [ ... ]` block.

  defp parse_body([{:punct, "]"} | rest], source, shape), do: parse_body(rest, source, shape)

  defp parse_body([{:punct, ","}, {:punct, "["} | rest], source, shape) do
    {block, rest} = read_block([{:punct, "["} | rest], source)
    parse_body(rest, source, add_property(shape, block, source))
  end

  defp parse_body([{:punct, ","} | rest], source, shape), do: parse_body(rest, source, shape)

  defp parse_body([{:word, "sh:targetClass"}, value | rest], source, shape) do
    parse_body(rest, source, %{shape | target_class: term_value(value)})
  end

  defp parse_body([{:word, "sh:closed"}, {:word, "true"} | rest], source, shape) do
    parse_body(rest, source, %{shape | closed: true})
  end

  defp parse_body([{:word, "sh:closed"}, {:word, "false"} | rest], source, shape) do
    parse_body(rest, source, shape)
  end

  defp parse_body([{:word, "sh:description"}, _value | rest], source, shape) do
    parse_body(rest, source, shape)
  end

  defp parse_body([{:word, "sh:property"} | rest], source, shape) do
    {block, rest} = read_block(rest, source)
    parse_body(rest, source, add_property(shape, block, source))
  end

  defp parse_body(tokens, source, _shape) do
    raise CompileError,
      file: source,
      description: "unsupported shape statement syntax near #{inspect(Enum.take(tokens, 6))}"
  end

  defp read_block([{:punct, "["} | rest], source) do
    {inner, rest} = Enum.split_while(rest, &(&1 != {:punct, "]"}))

    case rest do
      [{:punct, "]"} | rest] -> {inner, rest}
      [] -> raise CompileError, file: source, description: "unterminated sh:property block"
    end
  end

  defp read_block(_, source) do
    raise CompileError, file: source, description: "expected sh:property block"
  end

  defp add_property(shape, block, source) do
    {prop, _last_keyword} =
      Enum.reduce(block, {%{path: nil, min_count: nil, max_count: nil, datatype: nil, message: nil}, nil}, fn
        {:punct, _}, acc ->
          acc

        # value tokens arrive bound to the keyword that preceded them
        {:word, keyword}, {prop, _}
        when keyword in @datatype_keywords ->
          {prop, keyword}

        value, {prop, "sh:path"} ->
          {%{prop | path: term_value(value)}, nil}

        value, {prop, "sh:minCount"} ->
          {%{prop | min_count: parse_int(value, "sh:minCount", source)}, nil}

        value, {prop, "sh:maxCount"} ->
          {%{prop | max_count: parse_int(value, "sh:maxCount", source)}, nil}

        value, {prop, "sh:datatype"} ->
          {%{prop | datatype: parse_datatype(value, source)}, nil}

        {:string, msg}, {prop, "sh:message"} ->
          {%{prop | message: msg}, nil}

        # unknown keyword: the error names the actual offending keyword,
        # never a misrouted sh:minCount parse failure
        {:word, keyword}, _acc ->
          raise CompileError,
            file: source,
            description: "unsupported sh:property constraint #{inspect(keyword)}"

        value, {_prop, nil} ->
          raise CompileError,
            file: source,
            description: "unexpected property value #{inspect(value)} before any constraint keyword"
      end)

    case prop do
      %{path: nil} ->
        raise CompileError, file: source, description: "sh:property block without sh:path"

      prop ->
        # store paths as local names: evaluation resolves "location" top-level
        # and everything else under "properties.<local>"
        path = local_name(prop.path)

        %{
          shape
          | required:
              shape.required ++
                [%{path: path, min_count: prop.min_count || 1,
                   max_count: prop.max_count, datatype: prop.datatype,
                   message: prop.message}]
        }
    end
  end

  defp parse_int({:word, word}, _keyword, source) do
    case Integer.parse(word) do
      {int, ""} -> int
      _ -> raise CompileError, file: source, description: "invalid integer value #{inspect(word)}"
    end
  end

  defp parse_int(value, keyword, source) do
    raise CompileError, file: source, description: "invalid #{keyword} value #{inspect(value)}"
  end

  defp parse_datatype({:word, "xsd:string"}, _source), do: :string
  defp parse_datatype({:word, "xsd:integer"}, _source), do: :integer
  defp parse_datatype({:word, "xsd:boolean"}, _source), do: :boolean

  defp parse_datatype({:word, word}, source) do
    raise CompileError,
      file: source,
      description: "unsupported sh:datatype #{inspect(word)} " <>
        "(supported: xsd:string, xsd:integer, xsd:boolean)"
  end

  defp parse_datatype(value, source) do
    raise CompileError,
      file: source,
      description: "unsupported sh:datatype #{inspect(value)} " <>
        "(supported: xsd:string, xsd:integer, xsd:boolean)"
  end

  defp term_value({:string, s}), do: s
  defp term_value({:iri, iri}), do: iri
  defp term_value({:word, word}), do: full_iri(word)

  defp full_iri("sh:" <> local), do: "http://www.w3.org/ns/shacl#" <> local
  defp full_iri("smalt:" <> local), do: "https://ggen.io/ontology/smalt#" <> local
  defp full_iri("rdf:" <> local), do: "http://www.w3.org/1999/02/22-rdf-syntax-ns#" <> local
  defp full_iri("rdfs:" <> local), do: "http://www.w3.org/2000/01/rdf-schema#" <> local
  defp full_iri("xsd:" <> local), do: "http://www.w3.org/2001/XMLSchema#" <> local
  defp full_iri(word), do: word

  defp local_name(name) do
    name
    |> String.split(["#", "/"])
    |> List.last()
  end
end

defmodule Smalt.GraphLaw.Validator do
  @moduledoc """
  Hard-crash admission gate for resource payloads (pure-Elixir SHACL-subset
  evaluator, per the pinned engine decision).

  `priv/shacl/smalt-shapes.ttl` is parsed at COMPILE time
  (`@external_resource` + `File.read!` via
  `Smalt.GraphLaw.Validator.ShapeFile`); per shape we extract:

    * required properties (`sh:minCount`) with path + message
    * optional `sh:datatype` per property (`xsd:string` -> binary,
      `xsd:integer` -> integer, `xsd:boolean` -> boolean)
    * the `sh:closed` flag: a closed shape refuses unknown payload property
      paths (any top-level key other than the declared paths or the
      `properties` container, and any key inside `properties` other than the
      declared local paths) with `constraint: "closed"` violations

  Evaluation resolves each required `sh:path` local name against the payload:
  `"location"` is read top-level; every other path is read at the dotted path
  `"properties.<local>"` (a shape path containing dots is used verbatim; the
  bare local name at top level is accepted as a fallback for non-`location`
  paths — a missing-everywhere check can only refuse, never falsely reject).

  Optional wasm fast-path: when `Application.get_env(:smalt, :graphlaw_engine)
  == :ash_graphlaw` and `AshGraphLaw` is loadable and exports
  `validate_resource/2`, validation delegates to the engine. Any engine
  failure collapses to `{:refused, :engine_unavailable}` (router maps to 503).

  NO payload is ever admitted without a verdict: unknown types are refused,
  and admitted types with no shape in the shapes file are refused.
  """

  @shapes_path "priv/shacl/smalt-shapes.ttl"
  @external_resource Path.expand("../../../" <> @shapes_path, __DIR__)

  @shapes (case File.read(Path.expand("../../../" <> @shapes_path, __DIR__)) do
             {:ok, text} ->
               Smalt.GraphLaw.Validator.ShapeFile.parse!(text, @shapes_path)

             {:error, reason} ->
               raise CompileError,
                 file: @shapes_path,
                 description: "cannot read shapes file: #{inspect(reason)}"
           end)

  @doc """
  Parsed shapes: `%{shape_name => %{target_class: String.t() | nil,
  closed: boolean(), required: [%{path: String.t(), min_count: pos_integer(),
  datatype: :string | :integer | :boolean | nil,
  message: String.t() | nil}]}}`.
  """
  def shapes, do: @shapes

  @doc """
  Resolve `type`'s registry shape binding to a compiled shape map, or `nil`
  when the registry names a shape absent from the compiled shapes file
  (registry/shapes drift). `validate_local/2` refuses `{:refused, :no_shape}`
  on `nil` — the fail-closed law: an admitted type with no compiled shape is
  never validated against an implicit empty (permissive) shape.
  """
  def shape_for_type(type) do
    resolve_shape(@shapes, shape_name(type) || "")
  end

  @doc """
  Pure shape resolution over an explicit shapes map: exact name, then
  `name <> "Shape"`, then trimmed suffix, then targetClass match. Returns
  `nil` when nothing resolves — `validate_local/2` REFUSES on `nil`
  (fail-closed: an admitted type with no compiled shape must never be
  validated against an implicit empty, permissive shape).
  """
  def resolve_shape(shapes, name) when is_map(shapes) and is_binary(name) do
    Map.get(shapes, name) ||
      Map.get(shapes, name <> "Shape") ||
      Map.get(shapes, String.trim_trailing(name, "Shape")) ||
      shape_by_target_class(shapes, name)
  end

  @doc """
  Validate `payload` against an explicit parsed `shape` (no registry lookup,
  no engine fast-path). Lets tests exercise closed and datatype semantics for
  shapes beyond the compiled shapes file.
  """
  def validate_shape(shape, payload) when is_map(shape) and is_map(payload) do
    case evaluate(shape, payload) do
      [] -> {:ok}
      violations -> {:invalid, violations}
    end
  end

  @doc """
  Validate a resource payload for `type`.

  Returns:

    * `{:ok}` — conforming
    * `{:invalid, [%{path: String.t(),
        constraint: "minCount" | "closed" | "datatype", message: String.t()}]}`
    * `{:refused, :type_not_admitted}` — `type` not in `Smalt.Registry`
    * `{:refused, :no_shape}` — admitted but no shape in the shapes file
    * `{:refused, :engine_unavailable}` — engine configured but failed/unavailable
  """
  def validate_resource(type, payload) when is_binary(type) and is_map(payload) do
    case engine_verdict(type, payload) do
      :no_engine -> validate_local(type, payload)
      other -> other
    end
  end

  # -- engine fast-path -------------------------------------------------------

  defp engine_verdict(type, payload) do
    if Application.get_env(:smalt, :graphlaw_engine) == :ash_graphlaw do
      if Code.ensure_loaded?(AshGraphLaw) and
           function_exported?(AshGraphLaw, :validate_resource, 2) do
        try do
          # apply/3 to avoid an undefined-module warning when the optional
          # ash_graphlaw dependency is not compiled in.
          apply(AshGraphLaw, :validate_resource, [type, payload])
        rescue
          _ -> {:refused, :engine_unavailable}
        catch
          _, _ -> {:refused, :engine_unavailable}
        end
      else
        {:refused, :engine_unavailable}
      end
    else
      :no_engine
    end
  end

  defp validate_local(type, payload) do
    cond do
      not Smalt.Registry.admitted?(type) ->
        {:refused, :type_not_admitted}

      is_nil(shape_name(type)) ->
        {:refused, :no_shape}

      true ->
        # Fail closed: a registry shape binding with NO matching compiled shape
        # (drift between Smalt.Registry and priv/shacl/smalt-shapes.ttl) must
        # refuse, never fall through to an empty permissive shape.
        case shape_for_type(type) do
          nil ->
            {:refused, :no_shape}

          shape ->
            violations = evaluate(shape, payload)

            if violations == [] do
              {:ok}
            else
              {:invalid, violations}
            end
        end
    end
  end

  # -- evaluation -------------------------------------------------------------

  defp evaluate(shape, payload) do
    min_count_violations(shape, payload) ++
      datatype_violations(shape, payload) ++
      closed_violations(shape, payload)
  end

  defp min_count_violations(shape, payload) do
    Enum.flat_map(shape.required, fn prop ->
      present? = Enum.any?(payload_paths(prop.path), &present?(payload, &1))

      if present? do
        []
      else
        [
          %{
            path: prop.path,
            constraint: "minCount",
            message: prop.message || "required property " <> prop.path <> " missing (sh:minCount)"
          }
        ]
      end
    end)
  end

  defp datatype_violations(shape, payload) do
    Enum.flat_map(shape.required, fn
      %{datatype: nil} ->
        []

      %{datatype: datatype, path: path} = _prop ->
        case present_value(payload, path) do
          :absent ->
            []

          value ->
            if datatype_matches?(datatype, value) do
              []
            else
              [
                %{
                  path: path,
                  constraint: "datatype",
                  message:
                    "property " <> path <> " must be a JSON " <> Atom.to_string(datatype) <>
                      " (sh:datatype xsd:" <> Atom.to_string(datatype) <> ")"
                }
              ]
            end
        end
    end)
  end

  defp present_value(payload, path) do
    payload_paths(path)
    |> Enum.map(&dotted_get(payload, &1))
    |> Enum.find(:absent, fn
      :absent -> false
      nil -> false
      _ -> true
    end)
  end

  defp datatype_matches?(:string, value) when is_binary(value), do: true
  defp datatype_matches?(:integer, value) when is_integer(value), do: true
  defp datatype_matches?(:boolean, value) when is_boolean(value), do: true
  defp datatype_matches?(_datatype, _value), do: false

  # Closed semantics: for a shape with sh:closed true, any payload property
  # path NOT declared in the shape's properties is a violation. The
  # "properties" key is a namespace container, not a property path. For JSON
  # payloads nothing extra is ignored (no rdf:type/rdfs:comment equivalents).
  defp closed_violations(shape, payload) do
    if Map.get(shape, :closed, false) do
      unknown_property_violations(shape, payload)
    else
      []
    end
  end

  defp unknown_property_violations(%{required: props}, payload) do
    allowed = MapSet.new(props, & &1.path)

    top_extra =
      payload
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed or &1 == "properties"))
      |> Enum.map(&closed_violation(&1))

    properties_extra =
      case Map.get(payload, "properties") do
        props_map when is_map(props_map) ->
          props_map
          |> Map.keys()
          |> Enum.reject(&(&1 in allowed))
          |> Enum.map(&closed_violation("properties." <> &1))

        _ ->
          []
      end

    top_extra ++ properties_extra
  end

  defp closed_violation(path) do
    # Fail closed on malformed payload keys: a non-binary key (atom, integer,
    # tuple — hostile or buggy client) is itself an unknown property and must
    # yield a `closed` violation, never an ArgumentError from binary concat.
    # The echoed path is capped: a megabyte-scale hostile key must not bloat
    # the refusal envelope or flood logs.
    path_str =
      path
      |> to_path_string()
      |> String.slice(0, 200)

    %{
      path: path_str,
      constraint: "closed",
      message: "unknown property path " <> path_str <> " (shape is sh:closed)"
    }
  end

  defp to_path_string(path) when is_binary(path), do: path
  defp to_path_string(path), do: inspect(path)

  defp present?(payload, path) do
    case dotted_get(payload, path) do
      :absent -> false
      nil -> false
      _ -> true
    end
  end

  defp payload_paths("location"), do: ["location"]

  defp payload_paths(path) do
    local = last_segment(path)

    if path != local do
      [path]
    else
      ["properties." <> local, local]
    end
  end

  defp last_segment(path), do: path |> String.split(".") |> List.last()

  defp dotted_get(value, ""), do: value

  defp dotted_get(payload, path) when is_map(payload) do
    [head | rest] = String.split(path, ".")
    tail = Enum.join(rest, ".")

    case Map.get(payload, head, :absent) do
      :absent -> :absent
      value -> dotted_get(value, tail)
    end
  end

  defp dotted_get(nil, _rest), do: :absent
  defp dotted_get(_non_map, _rest), do: :absent

  # -- shape lookup -------------------------------------------------------------

  defp shape_name(type) do
    case Smalt.Registry.shape_for(type) do
      {:ok, name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp shape_by_target_class(shapes, local) do
    Enum.find(Map.values(shapes), fn shape ->
      shape.target_class && last_segment(shape.target_class) == last_segment(local)
    end)
  end
end
