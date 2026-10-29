defmodule Smalt.POWL2.LawCompiler do
  @moduledoc """
  Shape → guard compiler for the GL-1 guard seam.

  Parses SHACL Turtle shapes into closed guard predicates:

      {:ok, guard_fun} = LawCompiler.compile_shape("ex:OrderShape", ttl)
      guard_fun.(%{"orderTotal" => 9500})   # => :ok
      guard_fun.(%{"orderTotal" => 10_001}) # => {:violation, rule_id, diagnostic}

  Substrate reuse: `Smalt.GraphLaw.Validator.ShapeFile` is the canonical
  shape-Turtle tokenizer/parser, but its statement grammar is pinned to the
  shapes-file keyword set only (`sh:path/minCount/maxCount/datatype/message`)
  and raises by design on `sh:maxInclusive` / `powl:notEquals`. Rather than
  mutate shared bench/SHACL infra from a lane, this module carries a
  law-grammar parser in the same token discipline (quote-aware `#` comments,
  prefixed names, `<IRI>`s, string/number literals, punctuation), and pins
  the same evaluation laws `Smalt.GraphLaw.Validator` enforces: absent
  minCount is optional (KD-156), a missing value can only refuse (never
  falsely pass required/maxInclusive), and a non-conforming value type is a
  typed violation, never a crash.

  Supported constraint classes (the spec's five):

    * `sh:maxInclusive` — numeric ceiling on a path (order > 10k requires a
      compliance signature ⇒ `sh:maxInclusive 10000` on the order-total path).
    * `sh:minCount 1` — required presence (GDPR consent tag).
    * exclusion — subject≠object invariant: `powl:notEquals <peerPath>` inside
      a `sh:property` block (actor cannot approve own report).
    * `sh:not` — negated pattern: `sh:not [ sh:property [ ... ] ]` (the
      W3C-C ACP noneOf reduction: conflicted-class membership excluded).
      Violates iff the node CONFORMS to the inner pattern.
    * `sh:in` — allowed-value membership: `sh:in ( acp:Read acp:Write )`
      (the W3C-C ACP allow-mode reduction). An absent value conforms
      (SHACL semantics; pair with `sh:minCount 1` for required presence) —
      same relation discipline as the `powl:notEquals` exclusion class.
    * `sh:datatype` — datatype closure on a path (W2 DTDL lane: the 6th
      constraint class the tier2-scout mapping table names). `sh:datatype
      xsd:double` on a telemetry path violates on a present value of the
      wrong datatype; absent values conform (relation discipline — pair
      with `sh:minCount 1` for required presence). Known datatypes:
      `xsd:string/anyURI` (binary), `xsd:dateTime/date/time` (ISO8601-
      parseable binary), `xsd:boolean`, `xsd:integer/int/long/short/byte/
      nonNegativeInteger` (integers), `xsd:double/float/decimal`
      (numbers). Unknown datatype refuses every value (fail-closed).
    * `sh:qualifiedValueShape` — qualified nested-node constraint
      (W2 DTDL lane: relationship targets / component instances).
      `sh:property [ sh:path hostedBy ; sh:qualifiedValueShape [
      sh:property [ sh:path target ; sh:datatype xsd:string ] ] ]`
      violates iff the value at the path is present and does not satisfy
      the inner shape: non-map values refuse (fail-closed); map values
      are evaluated against the inner constraints. Absent values conform
      (SHACL qualified-shape semantics over minCount 0 edges).

  Context resolution: a constraint's `sh:path` local name is looked up in the
  context map under the binary key; atom keys are tolerated. `nil` counts as
  absent. Missing value ⇒ violation for required / maxInclusive classes
  (fail-closed). Malformed TTL ⇒ `{:error, {:parse_error, description}}` —
  typed, never a raise across the seam. Unknown shape ⇒
  `{:error, {:unknown_shape, iri}}`.
  """

  @typedoc "Guard predicate: context map → verdict"
  @type guard_fun :: (map() -> :ok | {:violation, String.t(), String.t()})

  @typedoc """
  Parsed constraint tuple: `{:max_inclusive, path, threshold, message}`,
  `{:min_count, path, count, message}`, or
  `{:not_equals, path, peer_path, message}`.
  """
  @type constraint ::
          {:max_inclusive, String.t(), number(), String.t() | nil}
          | {:min_count, String.t(), pos_integer(), String.t() | nil}
          | {:not_equals, String.t(), String.t(), String.t() | nil}
          | {:not, [constraint()]}
          | {:in, String.t(), [String.t()], String.t() | nil}
          | {:datatype, String.t(), String.t(), String.t() | nil}
          | {:qvs, String.t(), [constraint()], String.t() | nil}

  @typedoc "Parsed shape"
  @type shape :: %{target_class: String.t() | nil, constraints: [constraint()]}

  @law_source "powl2-law"

  @doc """
  Parse a TTL text into `%{shape_local_name => shape()}`. Raises
  `CompileError` on malformed input (compile-time discipline, same as
  `Smalt.GraphLaw.Validator.ShapeFile.parse!/2`); prefer `compile_shape/2`
  at the seam.
  """
  @spec parse!(String.t()) :: %{String.t() => shape()}
  def parse!(ttl) when is_binary(ttl) do
    ttl
    |> tokenize()
    |> split_statements()
    |> Enum.reduce(%{}, fn tokens, acc ->
      case parse_statement(tokens) do
        :skip -> acc
        {name, shape} -> Map.put(acc, name, shape)
      end
    end)
  end

  @doc """
  Compile `shape_iri` (full IRI or local name) out of `ttl` text into a
  guard predicate. Returns:

    * `{:ok, guard_fun}` — `guard_fun.(ctx) → :ok | {:violation, rule_id, diagnostic}`
    * `{:error, {:parse_error, description}}` — malformed TTL
    * `{:error, {:unknown_shape, iri}}` — TTL parsed but shape absent
  """
  @spec compile_shape(String.t(), String.t()) ::
          {:ok, guard_fun()}
          | {:error, {:parse_error, String.t()}}
          | {:error, {:unknown_shape, String.t()}}
  def compile_shape(shape_iri, ttl) when is_binary(shape_iri) and is_binary(ttl) do
    with {:ok, shapes} <- parse_typed(ttl),
         {:ok, shape} <- fetch_shape(shapes, shape_iri) do
      {:ok, build_guard(local_name(shape_iri), shape)}
    end
  end

  @doc """
  Compile every shape in `ttl`: `{:ok, %{local_name => guard_fun}}`.
  """
  @spec compile_all(String.t()) ::
          {:ok, %{String.t() => guard_fun()}} | {:error, {:parse_error, String.t()}}
  def compile_all(ttl) when is_binary(ttl) do
    case parse_typed(ttl) do
      {:ok, shapes} -> {:ok, Map.new(shapes, fn {name, shape} -> {name, build_guard(name, shape)} end)}
      error -> error
    end
  end

  # -- typed parse wrapper ------------------------------------------------------

  defp parse_typed(ttl) do
    {:ok, parse!(ttl)}
  rescue
    e in CompileError -> {:error, {:parse_error, Exception.message(e)}}
  end

  defp fetch_shape(shapes, shape_iri) do
    case Map.fetch(shapes, local_name(shape_iri)) do
      {:ok, shape} -> {:ok, shape}
      :error -> {:error, {:unknown_shape, shape_iri}}
    end
  end

  # -- guard construction ---------------------------------------------------------

  @doc false
  def build_guard(shape_name, shape) when is_binary(shape_name) and is_map(shape) do
    constraints = shape.constraints

    fn ctx ->
      if is_map(ctx) do
        first_violation(shape_name, constraints, ctx)
      else
        # EXPL5-T3: non-map input (JSON array/string/number from remote events)
        # must fail the guard, never match vacuously.
        {:violation, "#{shape_name}/datatype/$", "non-map data (#{inspect_simple(ctx)})"}
      end
    end
  end

  defp inspect_simple(term) do
    cond do
      is_list(term) -> "list of #{length(term)}"
      is_binary(term) -> "string"
      is_number(term) -> "number"
      true -> inspect(term)
    end
  end

  defp first_violation(shape_name, constraints, ctx) do
    Enum.reduce_while(constraints, :ok, fn constraint, :ok ->
      case check(constraint, ctx) do
        :ok -> {:cont, :ok}
        {:violation, detail} -> {:halt, {:violation, rule_id(shape_name, constraint), detail}}
      end
    end)
  end

  defp rule_id(shape_name, {class, path, _, _}) do
    "#{shape_name}/#{class_name(class)}/#{path}"
  end

  defp rule_id(shape_name, {:not, _inner}) do
    "#{shape_name}/not"
  end

  defp class_name(:max_inclusive), do: "maxInclusive"
  defp class_name(:min_count), do: "minCount"
  defp class_name(:not_equals), do: "notEquals"
  defp class_name(:not), do: "not"
  defp class_name(:in), do: "in"
  defp class_name(:datatype), do: "datatype"
  defp class_name(:qvs), do: "qualifiedValueShape"

  defp check({:max_inclusive, path, threshold, message}, ctx) do
    case ctx_value(ctx, path) do
      :absent ->
        {:violation, violation_message(path, message, "missing value under maxInclusive ceiling")}

      value when is_integer(value) or is_float(value) ->
        if value <= threshold do
          :ok
        else
          {:violation,
           violation_message(
             path,
             message,
             "value #{inspect(value)} exceeds maxInclusive #{inspect(threshold)}"
           )}
        end

      value ->
        {:violation,
         violation_message(
           path,
           message,
           "non-numeric value #{inspect(value)} under maxInclusive ceiling (fail-closed)"
         )}
    end
  end

  defp check({:min_count, path, count, message}, ctx) do
    if ctx_value(ctx, path) != :absent do
      :ok
    else
      {:violation,
       violation_message(path, message, "required property #{path} missing (sh:minCount #{count})")}
    end
  end

  defp check({:not_equals, path, peer_path, message}, ctx) do
    {value, peer} = {ctx_value(ctx, path), ctx_value(ctx, peer_path)}

    if value != :absent and peer != :absent and same_principal?(value, peer) do
      {:violation,
       violation_message(
         path,
         message,
         "subject #{path} equals object #{peer_path} (#{inspect(value)}) — exclusion violated"
       )}
    else
      # Exclusion is a relation: if either side is absent the invariant is not
      # violated (nothing to compare). Fail-closed presence is the minCount
      # class's job, not the exclusion's.
      :ok
    end
  end

  defp check({:not, inner}, ctx) do
    # sh:not violates iff the node CONFORMS to the inner pattern: run the
    # inner constraints; their clean pass is the outer violation (the
    # W3C-C ACP noneOf reduction — presence of the excluded pattern is the
    # breach). Fail-closed: a negation over an empty pattern cannot arise —
    # add_not/2 raises at compile time on a vacuous inner block.
    case first_violation("not", inner, ctx) do
      :ok ->
        {:violation,
         violation_message(
           "sh:not",
           nil,
           "node matches the excluded (conflicted-class) pattern — acp:noneOf breach (ethical wall)"
         )}

      {:violation, _inner_rule, _diag} ->
        :ok
    end
  end

  defp check({:in, path, values, message}, ctx) do
    case ctx_value(ctx, path) do
      :absent ->
        # SHACL semantics: sh:in constrains present values; required presence
        # is the paired sh:minCount's job (same relation discipline as notEquals).
        :ok

      value ->
        if Enum.any?(values, &same_principal?(&1, value)) do
          :ok
        else
          {:violation,
           violation_message(
             path,
             message,
             "value #{inspect(value)} not in the allowed set #{inspect(values)} (sh:in)"
           )}
        end
    end
  end

  defp check({:datatype, path, datatype, message}, ctx) do
    case ctx_value(ctx, path) do
      :absent ->
        # Relation discipline: datatype constrains present values; required
        # presence is the paired sh:minCount's job (same as sh:in / notEquals).
        :ok

      value ->
        if datatype_conforms?(datatype, value) do
          :ok
        else
          {:violation,
           violation_message(
             path,
             message,
             "value #{inspect(value)} does not satisfy sh:datatype #{datatype} (fail-closed)"
           )}
        end
    end
  end

  defp check({:qvs, path, inner, message}, ctx) do
    case ctx_value(ctx, path) do
      :absent ->
        # SHACL qualified-shape semantics: the constraint qualifies present
        # values; edge presence is the multiplicity (minCount) class's job.
        :ok

      value when is_map(value) ->
        case first_violation("qvs", inner, value) do
          :ok ->
            :ok

          {:violation, _inner_rule, diag} ->
            {:violation,
             violation_message(
               path,
               message,
               "value map fails the qualified value shape (#{diag})"
             )}
        end

      value ->
        {:violation,
         violation_message(
           path,
           message,
           "non-map value #{inspect(value)} under sh:qualifiedValueShape (fail-closed)"
         )}
    end
  end

  # GL-KILL F2: canonical representation equality for the exclusion invariant.
  # Raw `==` was representation-sensitive in BOTH directions — over-permissive
  # (:alice vs "alice" evaded; distinct struct types with the same id evaded)
  # and over-strict across numeric spellings. The documented choice:
  #
  #   * numbers compare NUMERICALLY — 7 and 7.0 are the same quantity, so
  #     actor 7 vs approver 7.0 is a violation;
  #   * everything else compares through its CANONICAL STRING FORM — atoms and
  #     binaries spell the same principal (:alice == "alice" ⇒ violation), and
  #     structs compare by their field map with the type tag stripped, so two
  #     distinct struct types carrying the same id are the same principal
  #     (identity rides the value, not the module name);
  #   * mixed number/non-number never equal; unrepresentable terms fall back
  #     to inspect/1, so the canonical form is total and never raises.
  defp same_principal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp same_principal?(a, b) when is_number(a) or is_number(b), do: false
  defp same_principal?(a, b), do: canonical(a) == canonical(b)

  defp canonical(v) when is_struct(v), do: "struct:" <> inspect(Map.from_struct(v))

  defp canonical(v) do
    to_string(v)
  rescue
    Protocol.UndefinedError -> inspect(v)
  end

  defp violation_message(path, nil, default), do: "#{path}: #{default}"
  defp violation_message(_path, message, _default), do: message

  # xsd datatype closure (W2 DTDL lane). Unknown datatype refuses every value.
  @xsd_integer ~w(integer int long short byte nonNegativeInteger positiveInteger unsignedLong unsignedInt)
  @xsd_decimal ~w(double float decimal)

  defp datatype_conforms?(dt, value) when is_binary(dt) do
    cond do
      dt in ~w(string anyURI) -> is_binary(value)
      dt == "boolean" -> is_boolean(value)
      dt == "dateTime" -> is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))
      dt == "date" -> is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))
      dt == "time" -> is_binary(value) and match?({:ok, _}, Time.from_iso8601(value))
      dt in @xsd_integer -> is_integer(value)
      dt in @xsd_decimal -> is_number(value)
      true -> false
    end
  end

  # -- context lookup ---------------------------------------------------------

  defp ctx_value(ctx, path) when is_map(ctx) do
    # SPOF-B / A-6 (atom law, frame_codec class): the shapes-file path never
    # mints an atom — the previous `String.to_atom(path)` minted per path per
    # file. Compare spellings as binaries instead: match the binary key
    # directly, else scan for an EXISTING atom key whose name equals `path`
    # (Atom.to_string/1 mints nothing). Nil values are skipped (absent), as
    # before.
    case ctx do
      %{^path => value} when not is_nil(value) ->
        value

      _ ->
        case Enum.find(ctx, fn {k, v} -> is_atom(k) and v != nil and Atom.to_string(k) == path end) do
          {_k, value} -> value
          nil -> :absent
        end
    end
  end

  defp ctx_value(_ctx, _path), do: :absent

  # -- tokenizer (discipline adapted from Validator.ShapeFile) -------------------

  @punct ["[", "]", ",", ";", "."]

  defp tokenize(text) do
    text
    |> String.graphemes()
    |> do_tokenize([], [])
    |> Enum.reverse()
  end

  defp do_tokenize(["\"" | rest], tokens, acc) do
    {string, rest} = read_string(rest, [])
    do_tokenize(rest, [{:string, string} | flush(acc, tokens)], [])
  end

  defp do_tokenize([ch | rest], tokens, acc) do
    cond do
      ch in [" ", "\t", "\n", "\r"] ->
        do_tokenize(rest, flush(acc, tokens), [])

      ch == "#" ->
        do_tokenize(Enum.drop_while(rest, &(&1 != "\n")), flush(acc, tokens), [])

      ch == "<" ->
        {iri, rest} = read_iri(rest, [])
        do_tokenize(rest, [{:iri, iri} | flush(acc, tokens)], [])

      ch in @punct ->
        do_tokenize(rest, [{:punct, ch} | flush(acc, tokens)], [])

      true ->
        do_tokenize(rest, tokens, [ch | acc])
    end
  end

  defp do_tokenize([], tokens, acc), do: flush(acc, tokens)

  defp flush([], tokens), do: tokens
  defp flush(acc, tokens), do: [{:word, Enum.reverse(acc) |> Enum.join()} | tokens]

  defp read_string(["\\", escaped | rest], char_acc), do: read_string(rest, [escaped | char_acc])

  defp read_string(["\"" | rest], char_acc), do: {Enum.reverse(char_acc) |> Enum.join(), rest}

  defp read_string([ch | rest], char_acc), do: read_string(rest, [ch | char_acc])

  defp read_string([], _char_acc) do
    raise CompileError, file: @law_source, description: "unterminated string literal"
  end

  defp read_iri([">" | rest], char_acc), do: {Enum.reverse(char_acc) |> Enum.join(), rest}

  defp read_iri([ch | rest], char_acc), do: read_iri(rest, [ch | char_acc])

  defp read_iri([], _char_acc) do
    raise CompileError, file: @law_source, description: "unterminated IRI"
  end

  # -- statement grouping ---------------------------------------------------------

  defp split_statements([]), do: []

  defp split_statements(tokens) do
    {statement, rest} = Enum.split_while(tokens, &(&1 != {:punct, "."}))

    case rest do
      # Token stream exhausted with no terminal `.` — EXPL-10 F5: the trailing
      # partial statement must be a typed parse refusal, never compiled as a
      # complete shape (a truncated remote TTL is corrupt input).
      [] when statement != [] ->
        raise CompileError,
          file: @law_source,
          description: "truncated statement without final '.' (truncated TTL)"

      [] ->
        []

      [_dot | tail] ->
        case statement do
          [] -> split_statements(tail)
          stmt -> [stmt | split_statements(tail)]
        end
    end
  end

  # -- statement parsing -------------------------------------------------------------

  @shacl_ns "http://www.w3.org/ns/shacl#"

  defp parse_statement([subject, {:word, "a"}, {:word, "sh:NodeShape"} | rest]) do
    {local_name(subject), parse_body(rest, empty_shape())}
  end

  defp parse_statement([subject, {:word, "a"}, {:iri, @shacl_ns <> "NodeShape"} | rest]) do
    {local_name(subject), parse_body(rest, empty_shape())}
  end

  defp parse_statement(_tokens), do: :skip

  defp empty_shape, do: %{target_class: nil, constraints: []}

  defp parse_body([], shape), do: shape
  defp parse_body([{:punct, ";"} | rest], shape), do: parse_body(rest, shape)
  defp parse_body([{:punct, ","} | rest], shape), do: parse_body(rest, shape)

  defp parse_body([{:word, "sh:targetClass"}, value | rest], shape) do
    parse_body(rest, %{shape | target_class: term_value(value)})
  end

  defp parse_body([{:word, "sh:description"}, _value | rest], shape) do
    parse_body(rest, shape)
  end

  defp parse_body([{:word, "sh:property"} | rest], shape) do
    # Comma-separated property blocks: `sh:property [ ... ] , [ ... ] .`
    # (the doubled-bracket multi-block form the ShapeFile substrate also
    # accepts). Each block carries its own constraint.
    {blocks, rest} = read_blocks(rest)
    parse_body(rest, Enum.reduce(blocks, shape, &add_property(&2, &1)))
  end

  defp parse_body([{:word, "sh:not"} | rest], shape) do
    # sh:not [ sh:property [ ... ] ] — the negated pattern block is itself a
    # shape body: parse it with the same body grammar (fail-closed: any
    # construct the parser cannot evaluate raises rather than silently
    # degrading the negation). Violates iff the node conforms to the pattern.
    {blocks, rest} = read_blocks(rest)
    parse_body(rest, Enum.reduce(blocks, shape, &add_not(&2, &1)))
  end

  defp parse_body(tokens, _shape) do
    raise CompileError,
      file: @law_source,
      description: "unsupported shape body syntax near #{inspect(Enum.take(tokens, 6))}"
  end

  defp read_block([{:punct, "["} | rest]) do
    # Bracket-depth-aware: blocks nest (sh:not wraps sh:property blocks), so
    # the block ends at the bracket whose depth returns to zero, not at the
    # first closer.
    {inner, rest} = do_read_block(rest, 1, [])
    {Enum.reverse(inner), rest}
  end

  defp read_block(_) do
    raise CompileError, file: @law_source, description: "expected sh:property block"
  end

  defp do_read_block([{:punct, "["} | rest], depth, acc),
    do: do_read_block(rest, depth + 1, [{:punct, "["} | acc])

  defp do_read_block([{:punct, "]"} | rest], 1, acc), do: {acc, rest}

  defp do_read_block([{:punct, "]"} | rest], depth, acc) when depth > 1,
    do: do_read_block(rest, depth - 1, [{:punct, "]"} | acc])

  defp do_read_block([t | rest], depth, acc), do: do_read_block(rest, depth, [t | acc])

  defp do_read_block([], _depth, _acc) do
    raise CompileError, file: @law_source, description: "unterminated sh:property block"
  end

  defp read_blocks(rest) do
    {block, rest} = read_block(rest)

    case rest do
      [{:punct, ","} | [{:punct, "["} | _] = rest2] ->
        {more, rest2} = read_blocks(rest2)
        {[block | more], rest2}

      _ ->
        {[block], rest}
    end
  end

  defp add_not(shape, block) do
    inner_shape =
      block
      |> Enum.reject(&(&1 in [{:punct, ";"}, {:punct, ","}]))
      |> parse_body(empty_shape())

    case inner_shape.constraints do
      [] ->
        raise CompileError,
          file: @law_source,
          description: "sh:not block declares no supported constraint (inner pattern would be vacuous)"

      inner ->
        %{shape | constraints: shape.constraints ++ [{:not, inner}]}
    end
  end

  @prop_keywords ~w(sh:path sh:minCount sh:maxInclusive powl:notEquals sh:in sh:message sh:datatype sh:qualifiedValueShape)

  defp add_property(shape, block) do
    prop =
      Enum.reduce(
        block,
        %{path: nil, min_count: nil, max_inclusive: nil, peer: nil, in_values: [], message: nil, datatype: nil, qvs: nil, qvs_acc: nil, __kw: nil},
        fn
          {:punct, "("}, prop ->
            # sh:in RDF-list opener; members accumulate until the closer.
            %{prop | __kw: "sh:in"}

          {:punct, ")"}, %{__kw: "sh:in"} = prop ->
            %{prop | __kw: nil}

          # sh:qualifiedValueShape [ <nested shape body> ] — bracket-depth-aware
          # accumulation; the closed body is parsed with the same shape grammar.
          {:punct, "["}, %{__kw: "sh:qualifiedValueShape"} = prop ->
            %{prop | __kw: :qvs_body, qvs_acc: []}

          {:punct, "["}, %{__kw: :qvs_body, qvs_acc: acc} = prop ->
            %{prop | qvs_acc: [{:punct, "["} | acc]}

          {:punct, "]"}, %{__kw: :qvs_body, qvs_acc: acc} = prop ->
            depth =
              Enum.count(acc, &(&1 == {:punct, "["})) - Enum.count(acc, &(&1 == {:punct, "]"}))

            if depth == 0 do
              %{prop | qvs: parse_qvs_body(Enum.reverse(acc)), __kw: nil, qvs_acc: nil}
            else
              %{prop | qvs_acc: [{:punct, "]"} | acc]}
            end

          token, %{__kw: :qvs_body, qvs_acc: acc} = prop ->
            %{prop | qvs_acc: [token | acc]}

          {:punct, _}, prop ->
            prop

          {:word, kw}, prop when kw in @prop_keywords ->
            Map.put(prop, :__kw, kw)

          value, %{__kw: "sh:path"} = prop ->
            prop |> Map.put(:path, local_name(term_value(value))) |> Map.put(:__kw, nil)

          value, %{__kw: "sh:minCount"} = prop ->
            prop |> Map.put(:min_count, parse_int(value)) |> Map.put(:__kw, nil)

          value, %{__kw: "sh:maxInclusive"} = prop ->
            prop |> Map.put(:max_inclusive, parse_number(value)) |> Map.put(:__kw, nil)

          value, %{__kw: "powl:notEquals"} = prop ->
            prop |> Map.put(:peer, local_name(term_value(value))) |> Map.put(:__kw, nil)

          value, %{__kw: "sh:in"} = prop ->
            # RDF-list member: `(` `)` arrive as punct; bare words are members.
            %{prop | in_values: prop.in_values ++ [local_name(term_value(value))]}

          value, %{__kw: "sh:datatype"} = prop ->
            prop |> Map.put(:datatype, local_name(term_value(value))) |> Map.put(:__kw, nil)

          {:string, msg}, %{__kw: "sh:message"} = prop ->
            prop |> Map.put(:message, msg) |> Map.put(:__kw, nil)

          {:word, kw}, _prop ->
            raise CompileError,
              file: @law_source,
              description: "unsupported sh:property constraint #{inspect(kw)}"

          _value, prop ->
            raise CompileError,
              file: @law_source,
              description:
                "unexpected property value before any constraint keyword (pending: #{inspect(prop.__kw)})"
        end
      )

    case prop do
      %{path: nil} ->
        raise CompileError, file: @law_source, description: "sh:property block without sh:path"

      %{min_count: nil, max_inclusive: nil, peer: nil, in_values: [], datatype: nil, qvs: nil} ->
        raise CompileError,
          file: @law_source,
          description:
            "sh:property block for #{inspect(prop.path)} declares no supported constraint " <>
              "(supported: sh:minCount, sh:maxInclusive, powl:notEquals, sh:not, sh:in, " <>
              "sh:datatype, sh:qualifiedValueShape)"

      %{min_count: n, max_inclusive: nil, peer: nil, in_values: [], datatype: nil, qvs: nil}
      when is_integer(n) ->
        %{shape | constraints: shape.constraints ++ [{:min_count, prop.path, n, prop.message}]}

      %{min_count: nil, max_inclusive: v, peer: nil, in_values: [], datatype: nil, qvs: nil}
      when is_number(v) ->
        %{shape | constraints: shape.constraints ++ [{:max_inclusive, prop.path, v, prop.message}]}

      %{min_count: nil, max_inclusive: nil, peer: peer, in_values: [], datatype: nil, qvs: nil}
      when is_binary(peer) ->
        %{shape | constraints: shape.constraints ++ [{:not_equals, prop.path, peer, prop.message}]}

      %{min_count: nil, max_inclusive: nil, peer: nil, in_values: vals, datatype: nil, qvs: nil}
      when is_list(vals) and vals != [] ->
        %{shape | constraints: shape.constraints ++ [{:in, prop.path, vals, prop.message}]}

      %{min_count: nil, max_inclusive: nil, peer: nil, in_values: [], datatype: dt, qvs: nil}
      when is_binary(dt) ->
        %{shape | constraints: shape.constraints ++ [{:datatype, prop.path, dt, prop.message}]}

      %{min_count: nil, max_inclusive: nil, peer: nil, in_values: [], datatype: nil, qvs: inner}
      when is_list(inner) and inner != [] ->
        %{shape | constraints: shape.constraints ++ [{:qvs, prop.path, inner, prop.message}]}

      _overconstrained ->
        raise CompileError,
          file: @law_source,
          description:
            "sh:property block for #{inspect(prop.path)} mixes constraint classes " <>
              "(one of sh:minCount | sh:maxInclusive | powl:notEquals | sh:in | " <>
              "sh:datatype | sh:qualifiedValueShape per block)"
    end
  end

  defp parse_qvs_body(tokens) do
    inner_shape =
      tokens
      |> Enum.reject(&(&1 in [{:punct, ";"}, {:punct, ","}]))
      |> parse_body(empty_shape())

    case inner_shape.constraints do
      [] ->
        raise CompileError,
          file: @law_source,
          description:
            "sh:qualifiedValueShape block declares no supported constraint (inner pattern would be vacuous)"

      inner ->
        inner
    end
  end

  # -- literal parsing ---------------------------------------------------------------

  defp parse_int({:word, word}) do
    case Integer.parse(word) do
      {int, ""} -> int
      _ -> raise CompileError, file: @law_source, description: "invalid integer value #{inspect(word)}"
    end
  end

  defp parse_int(value) do
    raise CompileError, file: @law_source, description: "invalid integer value #{inspect(value)}"
  end

  defp parse_number({:word, word}) do
    case Integer.parse(word) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(word) do
          {f, ""} -> f
          _ -> raise CompileError, file: @law_source, description: "invalid numeric value #{inspect(word)}"
        end
    end
  end

  defp parse_number(value) do
    raise CompileError, file: @law_source, description: "invalid numeric value #{inspect(value)}"
  end

  defp term_value({:string, s}), do: s
  defp term_value({:iri, iri}), do: iri
  defp term_value({:word, word}), do: word


  # -- GL-7: in-place atomic guard-pointer swap ----------------------------------

  @doc """
  Creates (or returns) the named ETS guard-pointer table. One row per shape
  local name: `{local_name, guard_fun}`.
  """
  @spec guard_table!(atom()) :: :ets.table()
  def guard_table!(name) when is_atom(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :set, :public, read_concurrency: true])
      tid -> tid
    end
  end

  @doc """
  GL-7 rule-change swap: compile the (possibly amended) `ttl` for `shape_iri`
  and atomically replace the guard pointer under `local_name(shape_iri)` in
  `table`. The single `:ets.insert` on an existing key is the atomic swap;
  net topology (table shape, key set) is untouched. Returns the installed
  fun so the caller can pin the post-swap identity.
  """
  @spec swap_guard(:ets.table(), String.t(), String.t()) ::
          {:ok, guard_fun()} | {:error, {:parse_error, String.t()}} | {:error, {:unknown_shape, String.t()}}
  def swap_guard(table, shape_iri, ttl) when is_atom(table) do
    with {:ok, fun} <- compile_shape(shape_iri, ttl) do
      true = :ets.insert(table, {local_name(shape_iri), fun})
      {:ok, fun}
    end
  end

  @doc """
  Read the currently installed guard for `shape_iri` (a future evaluator's
  only lookup path). `{:error, :guard_not_installed}` when absent.
  """
  @spec lookup_guard(:ets.table(), String.t()) :: {:ok, guard_fun()} | {:error, :guard_not_installed}
  def lookup_guard(table, shape_iri) when is_atom(table) do
    case :ets.lookup(table, local_name(shape_iri)) do
      [{_k, fun}] -> {:ok, fun}
      [] -> {:error, :guard_not_installed}
    end
  end

  defp local_name(name) when is_binary(name) do
    name
    |> String.split(["#", "/", ":"], [])
    |> List.last()
  end

  # GL-9 compile-freeze unblock (disclosed): parse_statement hands the raw
  # subject token ({:word,_}/{:iri,_) to local_name/1; unwrap via term_value/1.
  defp local_name(token), do: local_name(term_value(token))
end
