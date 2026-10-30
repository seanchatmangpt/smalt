defmodule Smalt.Posh.Ingress.ShapeValidator.TTL do
  @moduledoc """
  Posh-shapes-specific Turtle subset parser — the
  `Smalt.GraphLaw.Validator.ShapeFile` pattern retargeted at
  `ggen-marketplace/packs/posh/shapes/ingress.ttl`.

  Understands exactly the statement forms used by the pack:

      posh:FooShape a sh:NodeShape ;
        sh:targetClass posh:Foo ;
        sh:closed true ;
        sh:ignoredProperties ( rdf:type ) ;
        sh:property [ sh:path posh:p ; sh:minCount 1 ; sh:maxCount 1 ;
                      sh:class posh:C ; sh:message "..." ] .

  Plus rdfs:seeAlso, sh:node, sh:datatype tolerated (KD-registered, NOT
  runtime-enforced). Parens lists `( ... )` are tokenized and consumed.
  ANY other constraint keyword raises `UnsupportedConstraint` — a parse
  error fails COMPILATION, not runtime (fail-closed ggen-sync guard).

  `abox/1` extracts A-box class individuals (`posh:S a posh:C`) and
  route→membraneOp bindings from the pack's instance/routes TTLs.
  """

  @punct ["[", "]", "(", ")", ",", ";", "."]

  @type token ::
          {:word, String.t()} | {:string, String.t()} | {:iri, String.t()} | {:punct, String.t()}

  @doc "Parse ingress-shapes TTL text into `%{local_name => shape_map}`. Raises on unsupported syntax."
  @spec parse!(String.t(), String.t()) :: map()
  def parse!(text, source) do
    text
    |> tokenize()
    |> split_statements()
    |> Enum.reduce(%{}, fn tokens, acc ->
      case parse_statement(tokens, source) do
        :skip -> acc
        shape -> Map.put(acc, shape.name, shape)
      end
    end)
  end

  @doc """
  Extract A-box individuals and route→op bindings from a TTL text.
  Returns `%{individuals: %{class_local => [subject_local]},
  route_ops: %{route_local => op}}`.
  """
  @spec abox(String.t()) :: %{individuals: map(), route_ops: map()}
  def abox(text) do
    text
    |> tokenize()
    |> split_statements()
    |> Enum.reduce(%{individuals: %{}, route_ops: %{}}, fn tokens, acc ->
      case tokens do
        [{:word, "posh:" <> subj}, {:word, "a"}, {:word, "posh:" <> class} | rest] ->
          acc
          |> add_individual(class, subj)
          |> add_route_op(subj, rest)

        _ ->
          acc
      end
    end)
  end

  # -- tokenizer -----------------------------------------------------------------

  defp tokenize(text) do
    text
    |> String.graphemes()
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
  defp read_string([], _char_acc), do: raise(ArgumentError, message: "unterminated string literal")

  defp read_iri([">" | rest], char_acc), do: {Enum.reverse(char_acc) |> Enum.join(), rest}
  defp read_iri([ch | rest], char_acc), do: read_iri(rest, [ch | char_acc])
  defp read_iri([], _char_acc), do: raise(ArgumentError, message: "unterminated IRI")

  # -- statement grouping ----------------------------------------------------------

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

  # -- shape statement parsing -------------------------------------------------------

  @constraint_keywords ~w(sh:path sh:minCount sh:maxCount sh:class sh:datatype sh:node sh:message)

  defp parse_statement([{:word, subject}, {:word, "a"}, {:word, "sh:NodeShape"} | rest], source) do
    name = local_name(iri(subject))
    parse_body(rest, source, empty_shape(name))
  end

  defp parse_statement(_tokens, _source), do: :skip

  defp empty_shape(name),
    do: %{name: name, target_class: nil, closed: false, ignored: [], props: []}

  defp parse_body([], _source, shape), do: shape

  defp parse_body([{:punct, ";"} | rest], source, shape),
    do: parse_body(rest, source, shape)

  defp parse_body([{:punct, ","} | rest], source, shape),
    do: parse_body(rest, source, shape)

  defp parse_body([{:word, "sh:targetClass"}, value | rest], source, shape),
    do: parse_body(rest, source, %{shape | target_class: term_local(value)})

  defp parse_body([{:word, "sh:closed"}, {:word, "true"} | rest], source, shape),
    do: parse_body(rest, source, %{shape | closed: true})

  defp parse_body([{:word, "sh:closed"}, {:word, "false"} | rest], source, shape),
    do: parse_body(rest, source, shape)

  defp parse_body(
         [{:word, "sh:ignoredProperties"}, {:punct, "("} | rest],
         source,
         shape
       ) do
    {names, rest} = read_paren_list(rest, [])
    parse_body(rest, source, %{shape | ignored: names})
  end

  defp parse_body([{:word, "rdfs:seeAlso"}, _value | rest], source, shape),
    do: parse_body(rest, source, shape)

  defp parse_body([{:word, "sh:property"} | rest], source, shape) do
    {block, rest} = read_block(rest, source)
    parse_body(rest, source, add_property(shape, block, source))
  end

  defp parse_body([{:word, kw} | _], source, _shape) do
    raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint,
      keyword: kw,
      message: "unsupported shape-level keyword (#{source})"
  end

  defp parse_body(tokens, source, _shape) do
    raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint,
      keyword: :malformed_body,
      message: "unsupported shape syntax near #{inspect(Enum.take(tokens, 6))} (#{source})"
  end

  defp read_paren_list([{:punct, ")"} | rest], acc), do: {Enum.reverse(acc), rest}
  defp read_paren_list([value | rest], acc), do: read_paren_list(rest, [term_local(value) | acc])
  defp read_paren_list([], _acc), do: raise(ArgumentError, message: "unterminated paren list")

  defp read_block([{:punct, "["} | rest], source) do
    {inner, rest} = Enum.split_while(rest, &(&1 != {:punct, "]"}))

    case rest do
      [{:punct, "]"} | rest] -> {inner, rest}
      [] -> raise Smalt.Posh.Ingress.ShapeValidator.ParseError, message: "unterminated sh:property block (#{source})"
    end
  end

  defp read_block(_, source),
    do: raise(Smalt.Posh.Ingress.ShapeValidator.ParseError, message: "expected sh:property block (#{source})")

  defp add_property(shape, block, source) do
    {prop, _last_keyword} =
      Enum.reduce(
        block,
        {%{key: nil, min: nil, max: nil, class: nil, datatype: nil}, nil},
        fn
          {:punct, _}, acc ->
            acc

          {:word, keyword}, {prop, _} when keyword in @constraint_keywords ->
            {prop, keyword}

          value, {prop, "sh:path"} ->
            {%{prop | key: term_local(value)}, nil}

          value, {prop, "sh:minCount"} ->
            {%{prop | min: parse_int(value, source)}, nil}

          value, {prop, "sh:maxCount"} ->
            {%{prop | max: parse_int(value, source)}, nil}

          value, {prop, "sh:class"} ->
            {%{prop | class: term_local(value)}, nil}

          value, {prop, "sh:datatype"} ->
            {%{prop | datatype: parse_datatype(value, source)}, nil}

          _value, {prop, "sh:node"} ->
            # KD-registered tolerance: parsed-and-skipped, never
            # runtime-enforced (KD-POSH row in gaps/44).
            {prop, nil}

          {:string, _msg}, {prop, "sh:message"} ->
            {prop, nil}

          # RDF language tag immediately after a string literal ("..."@en)
          {:word, "@" <> _lang}, acc ->
            acc

          {:word, keyword}, _acc ->
            raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint,
              keyword: keyword,
              message: "unsupported sh:property constraint (#{source})"

          value, {_prop, nil} ->
            raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint,
              keyword: :orphan_value,
              message:
                "unexpected property value #{inspect(value)} before any constraint keyword (#{source})"
        end
      )

    case prop do
      %{key: nil} ->
        raise Smalt.Posh.Ingress.ShapeValidator.ParseError,
          message: "sh:property block without sh:path (#{source})"

      prop ->
        %{shape | props: shape.props ++ [prop]}
    end
  end

  defp parse_int({:word, word}, source) do
    case Integer.parse(word) do
      {int, ""} -> int
      _ -> raise Smalt.Posh.Ingress.ShapeValidator.ParseError, message: "invalid integer value #{inspect(word)} (#{source})"
    end
  end

  defp parse_int(value, source),
    do:
      raise(Smalt.Posh.Ingress.ShapeValidator.ParseError,
        message: "invalid integer value #{inspect(value)} (#{source})"
      )

  defp parse_datatype({:word, "xsd:string"}, _source), do: :string
  defp parse_datatype({:word, "xsd:integer"}, _source), do: :integer
  defp parse_datatype({:word, "xsd:boolean"}, _source), do: :boolean

  defp parse_datatype({:word, word}, _source) do
    raise Smalt.Posh.Ingress.ShapeValidator.UnsupportedConstraint,
      keyword: word,
      message: "unsupported sh:datatype (supported: xsd:string, xsd:integer, xsd:boolean)"
  end

  defp term_local({:word, word}), do: local_name(iri(word))
  defp term_local({:iri, i}), do: local_name(i)
  defp term_local({:string, s}), do: s

  defp iri("posh:" <> local), do: "https://smalt.dev/posh/ns#" <> local
  defp iri("sh:" <> local), do: "http://www.w3.org/ns/shacl#" <> local
  defp iri("rdf:" <> local), do: "http://www.w3.org/1999/02/22-rdf-syntax-ns#" <> local
  defp iri("rdfs:" <> local), do: "http://www.w3.org/2000/01/rdf-schema#" <> local
  defp iri("xsd:" <> local), do: "http://www.w3.org/2001/XMLSchema#" <> local
  defp iri(word), do: word

  defp local_name(name), do: name |> String.split(["#", "/"]) |> List.last()

  # -- abox helpers ------------------------------------------------------------

  defp add_individual(acc, class, subj) do
    Map.update(acc, :individuals, %{class => [subj]}, fn ind ->
      Map.update(ind, class, [subj], fn names -> Enum.uniq([subj | names]) end)
    end)
  end

  defp add_route_op(acc, subj, rest) do
    case Enum.drop_while(rest, &(&1 != {:word, "posh:membraneOp"})) do
      [{:word, "posh:membraneOp"}, {:string, op} | _] ->
        Map.update(acc, :route_ops, %{subj => op}, &Map.put(&1, subj, op))

      _ ->
        acc
    end
  end
end

defmodule Smalt.Posh.Ingress.ShapeValidator do
  @moduledoc """
  Thin runtime SHACL-subset validator for POSH Port In frames (G32 Option C,
  lane 44, v26.10.30).

  Enforces {sh:minCount, sh:maxCount, sh:closed, sh:class} compiled at BUILD
  time from `ggen-marketplace/packs/posh/shapes/ingress.ttl`, per frame, in
  the admission hot path. This is the `Smalt.GraphLaw.Validator` pattern
  applied to the posh pack: the gate derives from the SAME parsed shapes the
  pack's projections read, so gate and projection cannot drift.

  Fail-closed by construction:

    * any constraint keyword outside the supported subset raises
      `UnsupportedConstraint` at BUILD time — a shape introducing
      `sh:pattern`, `sh:in`, `sh:and/or/not`, … is refused at compile,
      never silently skipped at runtime (same posture as
      `GraphLaw.Validator.ShapeFile`'s unsupported-datatype raise).
      KD-registered tolerances (parsed, recorded, NOT runtime-enforced):
      sh:node, sh:datatype, sh:message, sh:ignoredProperties, rdfs:seeAlso.
      Full KD row: docs/jira/posh/v26.10.30/gaps/44-shacl-option-c-landing.md
    * an unknown shape IRI resolves to every shape targeting
      posh:IngressRoute — never an implicit permissive empty shape.
    * class constraints resolve against A-box individuals compiled from
      ontology/routes.ttl + examples/posh_instance.ttl; a class with NO
      compiled individuals refuses every value (never a vacuous pass).

  Returns `:ok` or `{:refused, {:shape_violation, %{violations: [...]}}}` —
  the same settlement shape `Smalt.Posh.Ingress.Admission` produces.
  """

  @ingress_shapes "ggen-marketplace/packs/posh/shapes/ingress.ttl"
  @abox_files [
    "ggen-marketplace/packs/posh/ontology/routes.ttl",
    "ggen-marketplace/packs/posh/examples/posh_instance.ttl"
  ]

  @external_resource Path.expand("../../../.." <> @ingress_shapes, __DIR__)
  for f <- @abox_files, do: @external_resource(Path.expand("../../../.." <> f, __DIR__))

  @root Path.expand("../../../..", __DIR__)

  @shapes (case File.read(Path.join(@root, @ingress_shapes)) do
             {:ok, text} ->
               Smalt.Posh.Ingress.ShapeValidator.TTL.parse!(text, @ingress_shapes)

             {:error, reason} ->
               raise CompileError,
                 file: @ingress_shapes,
                 description: "cannot read posh ingress shapes: #{inspect(reason)}"
           end)

  @abox (Enum.reduce(@abox_files, %{individuals: %{}, route_ops: %{}}, fn f, acc ->
           parsed = Smalt.Posh.Ingress.ShapeValidator.TTL.abox(File.read!(Path.join(@root, f)))

           %{
             individuals:
               Map.merge(acc.individuals, parsed.individuals, fn _c, a, b -> Enum.uniq(a ++ b) end),
             route_ops: Map.merge(acc.route_ops, parsed.route_ops)
           }
         end))

  @individuals Map.new(@abox.individuals, fn {c, names} -> {c, MapSet.new(names)} end)
  @route_ops @abox.route_ops

  @ingress_route_shape (
    case Enum.find(Map.values(@shapes), &(&1.target_class == "IngressRoute" and &1.closed)) do
      nil ->
        raise CompileError,
          file: @ingress_shapes,
          description: "no closed sh:NodeShape targeting posh:IngressRoute"

      shape ->
        shape
    end
  )

  defmodule UnsupportedConstraint do
    @moduledoc """
    Raised at BUILD time when the pack's shapes introduce a constraint
    keyword outside the supported subset — the fail-closed ggen-sync guard:
    an unsupported constraint can never degrade to a silent runtime
    passthrough.
    """
    defexception [:message]

    @impl true
    def exception(opts) do
      kw = Keyword.fetch!(opts, :keyword)
      msg = Keyword.get(opts, :message)

      %__MODULE__{
        message:
          "unsupported SHACL constraint " <>
            inspect(kw) <>
            " in posh ingress shapes" <>
            (if msg, do: " — " <> msg, else: "") <>
            " (supported subset: sh:path, sh:minCount, sh:maxCount, sh:closed, sh:class" <>
            "; KD-registered tolerances: sh:node, sh:datatype, sh:message, " <>
            "sh:ignoredProperties, rdfs:seeAlso)"
      }
    end
  end

  defmodule ParseError do
    defexception [:message]

    @impl true
    def exception(opts) do
      %__MODULE__{message: "POSH ingress shapes: " <> Keyword.fetch!(opts, :message)}
    end
  end

  @doc """
  Parsed ingress shapes: `%{local_name => shape}` where each shape carries
  `:name, :target_class, :closed, :ignored, :props` and each prop carries
  `:key, :min, :max, :class, :datatype`.
  """
  def shapes, do: @shapes

  @doc "A-box individuals by class local name: `%{\"Turnstile\" => MapSet<...>}`."
  def individuals, do: @individuals

  @doc "Route -> membraneOp bindings compiled from the A-box files."
  def route_ops, do: @route_ops

  @doc "The compiled closed `posh:IngressRoute` shape (Laws 1+2 carrier)."
  def ingress_route_shape, do: @ingress_route_shape

  @doc """
  Admission policy map covering every admitted route's membraneOp, compiled
  from the SAME parsed A-box the class constraints resolve against. Compile
  with `Smalt.Posh.Ingress.Admission.compile/1`; each route spec carries
  `required`/`types` plus `:shape` — the compiled shape spec Admission
  enforces (closed, banned keys, class checks).
  """
  def admission_policy do
    # Merge every shape targeting posh:IngressRoute so the Admission spec
    # carries the closed route shape's required/class constraints AND the
    # NoBypass ban (posh:emits maxCount 0) — Laws 1+2 together.
    route_shapes = Enum.filter(Map.values(@shapes), &(&1.target_class == "IngressRoute"))

    base = shape_spec(@ingress_route_shape)

    banned =
      route_shapes
      |> Enum.flat_map(& &1.props)
      |> Enum.filter(&(&1.max == 0))
      |> Enum.map(& &1.key)
      |> MapSet.new()

    shape = Map.put(base, :banned, MapSet.union(base.banned, banned))

    Map.new(@route_ops, fn {_route, op} ->
      {op, %{required: shape.required, types: shape.types, shape: shape}}
    end)
  end

  @doc """
  Project a parsed shape into the plain spec map `Admission.compile/1`
  consumes under a route's `:shape` key:
  `%{closed: bool, allowed: MapSet<binary>, banned: MapSet<binary>,
  required: [atom], types: %{atom => :string}, class_checks: %{atom => MapSet<binary>}}`.
  """
  def shape_spec(shape) when is_map(shape) do
    props = Map.get(shape, :props, [])

    %{
      closed: Map.get(shape, :closed, false),
      allowed:
        MapSet.new(
          ["type" | Enum.map(props, & &1.key)] ++ Enum.map(Map.get(shape, :ignored, []), & &1)
        ),
      banned: MapSet.new(for(p <- props, p.max == 0, do: p.key)),
      required: for(p <- props, is_integer(p.min) and p.min >= 1, do: String.to_atom(p.key)),
      types:
        for(p <- props, p.datatype == :string, into: %{}, do: {String.to_atom(p.key), :string}),
      class_checks:
        props
        |> Enum.filter(& &1.class)
        |> Map.new(fn p ->
          # Fail-closed: a class with zero compiled individuals yields an
          # EMPTY MapSet — Admission refuses every value for it.
          {String.to_atom(p.key), MapSet.new(Map.get(@individuals, p.class) || MapSet.new())}
        end)
    }
  end

  @doc """
  Validate `frame` against the shape(s) bound to `shape_iri` (full IRI or
  local name). Unknown IRI falls back to every shape targeting
  posh:IngressRoute — fail-closed, never an implicit permissive shape.

  Returns `:ok` or `{:refused, {:shape_violation, %{violations: [...]}}}`.
  """
  def validate(shape_iri, frame) when is_binary(shape_iri) do
    case violations(shape_iri, frame) do
      [] -> :ok
      violations -> {:refused, {:shape_violation, %{violations: violations}}}
    end
  end

  @doc "Pure violation list for `shape_iri` against `frame` (test seam)."
  def violations(shape_iri, frame) when is_binary(shape_iri) do
    Enum.flat_map(shapes_for(shape_iri), &evaluate(&1, frame))
  end

  defp shapes_for(shape_iri) do
    local = shape_iri |> String.split(["#", "/"]) |> List.last()

    case Map.fetch(@shapes, local) do
      {:ok, shape} ->
        [shape]

      :error ->
        # Fail-closed fallback: the per-op shape IRIs projected from
        # routes.ttl (ResourceGroupShape, ...) carry no runtime-enforceable
        # property constraints of their own; a frame is an IngressRoute
        # individual, so the constraint-bearing closed route shape + the
        # NoBypass ban shape apply.
        @shapes
        |> Map.values()
        |> Enum.filter(&(&1.target_class == "IngressRoute"))
    end
  end

  defp evaluate(shape, frame) when is_map(frame) do
    ban_violations(shape, frame) ++
      closed_violations(shape, frame) ++
      required_violations(shape, frame) ++
      class_violations(shape, frame)
  end

  defp evaluate(_shape, frame) when not is_map(frame) do
    [%{path: "$", constraint: "closed", message: "frame_not_map"}]
  end

  # -- ban (sh:maxCount 0, ingress.ttl Law 2) ----------------------------------

  defp ban_violations(shape, frame) do
    for prop <- shape.props,
        prop.max == 0,
        key_present?(frame, prop.key) do
      %{
        path: "$.#{prop.key}",
        constraint: "maxCount",
        message:
          "#{prop.key} is banned on this subject (sh:maxCount 0); " <>
            "receipts come only from the Turnstile"
      }
    end
  end

  # -- closed (sh:closed + sh:ignoredProperties) --------------------------------

  defp closed_violations(shape, frame) do
    if shape.closed do
      allowed =
        MapSet.new(
          Enum.map(shape.props, & &1.key) ++ Enum.map(shape.ignored, & &1) ++ ["type"]
        )

      frame
      |> Map.keys()
      |> Enum.map(&key_name/1)
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(fn k ->
        %{
          path: "$.#{k}",
          constraint: "closed",
          message: "unknown property #{k} (shape #{shape.name} is sh:closed)"
        }
      end)
    else
      []
    end
  end

  # -- minCount ------------------------------------------------------------------

  defp required_violations(shape, frame) do
    for prop <- shape.props,
        is_integer(prop.min) and prop.min >= 1,
        not key_present?(frame, prop.key) do
      %{
        path: "$.#{prop.key}",
        constraint: "minCount",
        message: "required property #{prop.key} missing (sh:minCount #{prop.min})"
      }
    end
  end

  # -- class (sh:class) ----------------------------------------------------------

  defp class_violations(shape, frame) do
    for prop <- shape.props,
        prop.class,
        value = frame_value(frame, prop.key),
        value != :__posh_missing__ do
      individuals = Map.get(@individuals, prop.class) || MapSet.new()

      if is_binary(value) and MapSet.member?(individuals, local_name(value)) do
        []
      else
        [
          %{
            path: "$.#{prop.key}",
            constraint: "class",
            message:
              "#{prop.key} must name a #{prop.class} individual; got #{inspect(value)} " <>
                "(compiled individuals: #{MapSet.size(individuals)})"
          }
        ]
      end
    end
    |> List.flatten()
  end

  # -- key helpers (JSON-shaped string keys and atom keys both accepted) ----------

  defp key_present?(frame, key), do: frame_value(frame, key) != :__posh_missing__

  defp frame_value(frame, key) when is_map(frame) do
    kb = to_string(key)

    cond do
      Map.has_key?(frame, kb) -> Map.fetch!(frame, kb)
      Map.has_key?(frame, String.to_atom(kb)) -> Map.fetch!(frame, String.to_atom(kb))
      true -> :__posh_missing__
    end
  end

  defp key_name(k) when is_binary(k), do: k
  defp key_name(k), do: to_string(k)

  defp local_name(name), do: name |> String.split(["#", "/"]) |> List.last()
end
