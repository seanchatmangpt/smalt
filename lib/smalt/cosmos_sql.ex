defmodule Smalt.CosmosSql do
  @moduledoc """
  80/20 Cosmos SQL AST: parse + evaluate the console-contract grammar.

  Closes the evaluation half of GAP(cosmos-sql-translator-absent): the
  whitelist in `Smalt.DataPlane.Cosmos` stays as the `SELECT * FROM c`
  fast path; every other query is parsed here and evaluated per-document
  against the scanned set.

  Grammar (case-insensitive keywords, whitespace-insensitive):

      SELECT <proj> FROM <alias> [WHERE <pred>] [ORDER BY <prop> [ASC|DESC]] [LIMIT <n>]

      proj     ::= "*" | <path> ("," <path>)*
      path     ::= <ident> ("." <ident>)*        -- e.g. c, c.a.b
      pred     ::= <or>
      or       ::= <and> ("OR" <and>)*
      and      ::= <unary> ("AND" <unary>)*
      unary    ::= "NOT" <unary> | <comparison>
      comparison ::=
          <operand> (=|!=|<>|<|>|<=|>=) <operand>
        | <operand> "IN" "(" <literal> ("," <literal>)* ")"
        | "CONTAINS"       "(" <operand> "," <operand> ")"
        | "STARTSWITH"     "(" <operand> "," <operand> ")"
        | "ARRAY_CONTAINS" "(" <operand> "," <operand> ")"
      operand  ::= <path> | <literal> | <param>
      literal  ::= string | number | true | false | null
      param    ::= "@" <ident>  -- bound from the query body's
                                -- "parameters" array, by name

  Anything outside the grammar (joins, UDFs, aggregates, TOP, OFFSET LIMIT,
  subqueries, function calls other than the three named) is a typed
  `{:error, {:syntax, reason}}` -- the caller answers 400 SyntaxError,
  fail-closed. Aggregates (COUNT(1) et al.) are intentionally NOT admitted.
  """

  @enforce_keys [:projection, :from]
  defstruct [:projection, :from, where: nil, order_by: nil, limit: nil, params: %{}]

  @type t :: %__MODULE__{
          projection: :star | {:props, [path()]},
          from: String.t(),
          where: expr() | nil,
          order_by: {path(), :asc | :desc} | nil,
          limit: pos_integer() | nil,
          params: %{optional(String.t()) => term()}
        }

  @type path :: [String.t()]

  @type expr ::
          {:cmp, op(), expr(), expr()}
          | {:and, expr(), expr()}
          | {:or, expr(), expr()}
          | {:not, expr()}
          | {:in, expr(), [literal()]}
          | {:contains, expr(), expr()}
          | {:startswith, expr(), expr()}
          | {:array_contains, expr(), expr()}
          | {:get, path()}
          | {:lit, literal()}
          | {:param, String.t()}

  @type op :: :eq | :neq | :lt | :gt | :lteq | :gteq
  @type literal :: binary() | number() | boolean() | nil

  # -- Public API -----------------------------------------------------------

  @doc "Parse `query` with bound `params` (map of @name => value)."
  @spec parse(String.t(), %{optional(String.t()) => term()}) ::
          {:ok, t()} | {:error, {:syntax, String.t()}}
  def parse(query, params \\ %{}) when is_binary(query) and is_map(params) do
    with {:ok, tokens} <- tokenize(query),
         {:ok, %__MODULE__{} = ast} <- parse_tokens(tokens) do
      used = params_used(ast.where) |> Enum.uniq()
      missing = Enum.reject(used, &Map.has_key?(params, &1))

      if missing == [] do
        {:ok, %__MODULE__{ast | params: params}}
      else
        {:error, {:syntax, "Unbound parameter(s): #{Enum.join(Enum.sort(missing), ", ")}"}}
      end
    end
  end

  @doc "Evaluate a parsed query against one document."
  @spec eval_doc(t(), map()) :: map() | :no_match
  def eval_doc(%__MODULE__{} = q, doc) when is_map(doc) do
    if where_holds?(q, doc), do: project(q, doc), else: :no_match
  end

  @doc "Filter + sort + limit a document list."
  @spec eval_docs(t(), [map()]) :: [map()]
  def eval_docs(%__MODULE__{} = q, docs) when is_list(docs) do
    matched = for doc <- docs, where_holds?(q, doc), do: project(q, doc)

    matched =
      case q.order_by do
        {path, dir} -> Enum.sort_by(matched, &sort_key(&1, path), dir)
        nil -> matched
      end

    case q.limit do
      nil -> matched
      n when is_integer(n) and n > 0 -> Enum.take(matched, n)
    end
  end

  @doc "One-shot: parse + evaluate, for the call site."
  @spec run(String.t(), [map()], %{optional(String.t()) => term()}) ::
          {:ok, [map()]} | {:error, {:syntax, String.t()}}
  def run(query, docs, params \\ %{}) do
    case parse(query, params) do
      {:ok, q} -> {:ok, eval_docs(q, docs)}
      {:error, {:syntax, _}} = err -> err
    end
  end

  # -- Evaluation -----------------------------------------------------------

  defp where_holds?(%__MODULE__{where: nil}, _doc), do: true

  defp where_holds?(%__MODULE__{where: where, params: params}, doc),
    do: truthy?(where, doc, params)

  defp project(%__MODULE__{projection: :star}, doc), do: doc

  # Subset projection: each projected path keys by its LAST segment (c.a.b ->
  # "b"); a missing field is OMITTED (real Cosmos omits undefined, no null).
  defp project(%__MODULE__{projection: {:props, paths}}, doc) do
    Enum.reduce(paths, %{}, fn path, acc ->
      case get_in_doc(doc, path) do
        nil -> acc
        value -> Map.put(acc, List.last(path), value)
      end
    end)
  end

  # Property access: missing field or non-map traversal step -> nil
  # (undefined in Cosmos SQL terms; comparisons against undefined are false).
  @doc false
  def get_in_doc(doc, path) do
    Enum.reduce_while(path, doc, fn seg, acc ->
      if is_map(acc) and Map.has_key?(acc, seg) do
        {:cont, Map.fetch!(acc, seg)}
      else
        {:halt, nil}
      end
    end)
  end

  @doc false
  def truthy?(expr, doc, params), do: eval_expr(expr, doc, params) == true

  defp eval_expr({:lit, v}, _doc, _params), do: v
  defp eval_expr({:param, name}, _doc, params), do: Map.fetch!(params, name)
  defp eval_expr({:get, path}, doc, _params), do: get_in_doc(doc, path)
  defp eval_expr({:not, e}, doc, params), do: not truthy?(e, doc, params)

  defp eval_expr({:and, l, r}, doc, params),
    do: truthy?(l, doc, params) and truthy?(r, doc, params)

  defp eval_expr({:or, l, r}, doc, params),
    do: truthy?(l, doc, params) or truthy?(r, doc, params)

  defp eval_expr({:cmp, op, l, r}, doc, params) do
    compare(op, eval_expr(l, doc, params), eval_expr(r, doc, params))
  end

  defp eval_expr({:in, e, lits}, doc, params) do
    v = eval_expr(e, doc, params)
    v != nil and Enum.any?(lits, &eq?(v, &1))
  end

  defp eval_expr({:contains, l, r}, doc, params) do
    case {eval_expr(l, doc, params), eval_expr(r, doc, params)} do
      {a, b} when is_binary(a) and is_binary(b) -> String.contains?(a, b)
      _ -> false
    end
  end

  defp eval_expr({:startswith, l, r}, doc, params) do
    case {eval_expr(l, doc, params), eval_expr(r, doc, params)} do
      {a, b} when is_binary(a) and is_binary(b) -> String.starts_with?(a, b)
      _ -> false
    end
  end

  defp eval_expr({:array_contains, l, r}, doc, params) do
    case {eval_expr(l, doc, params), eval_expr(r, doc, params)} do
      {a, b} when is_list(a) -> Enum.any?(a, &eq?(&1, b))
      _ -> false
    end
  end

  # Undefined (missing) never compares — false for every operator. A DEFINED
  # value vs literal null: neq is true (defined != null), everything else false.
  # Type-mismatched comparisons are false (Cosmos: undefined propagates; WHERE
  # keeps only defined-true). Numbers compare numerically across int/float;
  # strings lexicographically; booleans only against booleans (Elixir booleans
  # are integers, hence the is_boolean discrimination below).
  defp compare(_op, nil, _rv), do: false
  defp compare(:neq, _lv, nil), do: true
  defp compare(_op, _lv, nil), do: false

  defp compare(op, lv, rv) when is_number(lv) and is_number(rv) and not is_boolean(lv),
    do: do_compare(op, lv, rv)

  defp compare(op, lv, rv) when is_binary(lv) and is_binary(rv),
    do: do_compare(op, lv, rv)

  defp compare(op, lv, rv) when is_boolean(lv) and is_boolean(rv),
    do: do_compare(op, lv, rv)

  defp compare(:eq, lv, rv), do: lv === rv and is_boolean(lv) == is_boolean(rv)
  defp compare(:neq, lv, rv), do: not compare(:eq, lv, rv)
  defp compare(_ord, _lv, _rv), do: false

  defp do_compare(:eq, a, b), do: a == b
  defp do_compare(:neq, a, b), do: a != b
  defp do_compare(:lt, a, b), do: a < b
  defp do_compare(:gt, a, b), do: a > b
  defp do_compare(:lteq, a, b), do: a <= b
  defp do_compare(:gteq, a, b), do: a >= b

  # Equality for IN / ARRAY_CONTAINS: numeric across int/float, strict
  # (structural) within other types.
  defp eq?(a, b) when is_number(a) and is_number(b), do: a == b
  defp eq?(a, b), do: a === b

  defp sort_key(doc, path), do: get_in_doc(doc, path)

  defp params_used(nil), do: []

  defp params_used(expr) do
    {used, _} =
      walk(expr, fn
        {:param, name}, acc -> {[name | acc], nil}
        _node, acc -> {acc, nil}
      end)

    used
  end

  # Bottom-up expression walk: visitor returns {acc, replacement}; nil
  # replacement keeps the node.
  defp walk({:lit, _} = n, _fun), do: {[], n}
  defp walk({:get, _} = n, fun), do: fun.(n, [])
  defp walk({:param, _} = n, fun), do: fun.(n, [])

  defp walk({:not, e}, fun) do
    {acc, e2} = walk(e, fun)
    fun.({:not, e2}, acc)
  end

  defp walk({:cmp, op, l, r}, fun) do
    {acc_l, l2} = walk(l, fun)
    {acc_r, r2} = walk(r, fun)
    fun.({:cmp, op, l2, r2}, acc_l ++ acc_r)
  end

  defp walk({op, l, r}, fun)
       when op in [:and, :or, :contains, :startswith, :array_contains] do
    {acc_l, l2} = walk(l, fun)
    {acc_r, r2} = walk(r, fun)
    fun.({op, l2, r2}, acc_l ++ acc_r)
  end

  defp walk({:in, e, lits}, fun) do
    {acc, e2} = walk(e, fun)
    fun.({:in, e2, lits}, acc)
  end

  # -- Lexer ----------------------------------------------------------------
  # Token form: {kind, value} two-tuples. 1-tuple tokens are banned here:
  # `{:select}` in a PATTERN binds a variable named select, it does not match
  # the 1-tuple (witnessed failure mode, lane 523).

  @keywords [
    :select,
    :from,
    :where,
    :order,
    :by,
    :asc,
    :desc,
    :limit,
    :and,
    :or,
    :not,
    :in,
    :contains,
    :startswith,
    :array_contains,
    true,
    false,
    :null
  ]

  @ws [32, 9, 10, 13]

  @doc false
  def tokenize(str) do
    {:ok, Enum.reverse(do_tokenize(str, []))}
  catch
    {:syntax, msg} -> {:error, {:syntax, msg}}
  end

  defp do_tokenize("", acc), do: acc

  defp do_tokenize(<<c::utf8, rest::binary>>, acc) when c in @ws, do: do_tokenize(rest, acc)

  defp do_tokenize("(" <> rest, acc), do: do_tokenize(rest, [{:lparen, nil} | acc])
  defp do_tokenize(")" <> rest, acc), do: do_tokenize(rest, [{:rparen, nil} | acc])
  defp do_tokenize("," <> rest, acc), do: do_tokenize(rest, [{:comma, nil} | acc])
  defp do_tokenize("*" <> rest, acc), do: do_tokenize(rest, [{:star, nil} | acc])
  defp do_tokenize("=" <> rest, acc), do: do_tokenize(rest, [{:op, :eq} | acc])
  defp do_tokenize("!=" <> rest, acc), do: do_tokenize(rest, [{:op, :neq} | acc])
  defp do_tokenize("<>" <> rest, acc), do: do_tokenize(rest, [{:op, :neq} | acc])
  defp do_tokenize("<=" <> rest, acc), do: do_tokenize(rest, [{:op, :lteq} | acc])
  defp do_tokenize(">=" <> rest, acc), do: do_tokenize(rest, [{:op, :gteq} | acc])
  defp do_tokenize("<" <> rest, acc), do: do_tokenize(rest, [{:op, :lt} | acc])
  defp do_tokenize(">" <> rest, acc), do: do_tokenize(rest, [{:op, :gt} | acc])

  defp do_tokenize("@" <> rest, acc) do
    case Regex.run(~r/^[A-Za-z_][A-Za-z0-9_]*/, rest) do
      [name] ->
        do_tokenize(String.slice(rest, String.length(name)..-1//1), [{:param, name} | acc])

      _ ->
        throw({:syntax, "Parameter name expected after @"})
    end
  end

  defp do_tokenize("'" <> rest, acc), do: lex_string(rest, "", acc)

  defp do_tokenize(rest, acc) do
    cond do
      Regex.match?(~r/^[A-Za-z_]/, rest) -> lex_word(rest, acc)
      Regex.match?(~r/^[-+]?[0-9]/, rest) -> lex_number(rest, acc)
      true -> throw({:syntax, "Unexpected character at: #{inspect(String.slice(rest, 0, 12))}"})
    end
  end

  defp lex_string("", _buf, _acc), do: throw({:syntax, "Unterminated string literal"})

  defp lex_string("'" <> rest, buf, acc), do: do_tokenize(rest, [{:lit, buf} | acc])

  defp lex_string(<<c::utf8, rest::binary>>, buf, acc),
    do: lex_string(rest, buf <> <<c::utf8>>, acc)

  defp lex_word(rest, acc) do
    [w] = Regex.run(~r/^[A-Za-z_][A-Za-z0-9_.]*/, rest)
    rest2 = String.slice(rest, String.length(w)..-1//1)
    lw = String.to_atom(String.downcase(w))

    token =
      if lw in @keywords do
        {:kw, lw}
      else
        {:ident, w}
      end

    do_tokenize(rest2, [token | acc])
  end

  defp lex_number(rest, acc) do
    [n] = Regex.run(~r/^[-+]?[0-9]+(\.[0-9]+)?/, rest)
    rest2 = String.slice(rest, String.length(n)..-1//1)
    value = if String.contains?(n, "."), do: String.to_float(n), else: String.to_integer(n)
    do_tokenize(rest2, [{:lit, value} | acc])
  end

  # -- Parser (recursive descent) -------------------------------------------

  defp parse_tokens(tokens) do
    case parse_select(tokens) do
      {:ok, %__MODULE__{} = ast, []} ->
        # Alias stripping: `c.age` addresses the document root, so a member
        # path whose first segment equals the FROM alias is rewritten to the
        # remaining segments. Non-matching heads stay (and evaluate as plain
        # property access — real Cosmos would reject them; 80/20 tolerated).
        {:ok, normalize_paths(ast)}

      {:ok, _ast, _leftover} ->
        {:error, {:syntax, "Unexpected tokens after the query"}}

      {:error, {:syntax, _}} = err ->
        err
    end
  end

  defp normalize_paths(%__MODULE__{from: alias} = ast) do
    down = String.downcase(alias)

    order_by =
      case ast.order_by do
        {[head | rest], dir} ->
          if String.downcase(head) == down and rest != [],
            do: {rest, dir},
            else: {[head | rest], dir}

        nil ->
          nil
      end

    projection =
      case ast.projection do
        {:props, paths} ->
          {:props, Enum.map(paths, &strip_path_alias(&1, down))}

        other ->
          other
      end

    %{
      ast
      | :where => strip_alias(ast.where, down),
        :order_by => order_by,
        :projection => projection
    }
  end

  defp strip_path_alias([head | rest], down) do
    if String.downcase(head) == down and rest != [] do
      rest
    else
      [head | rest]
    end
  end

  defp strip_alias(nil, _down), do: nil

  defp strip_alias(expr, down) do
    {[], expr2} =
      walk(expr, fn
        {:get, [head | rest]}, acc ->
          if String.downcase(head) == down and rest != [] do
            {acc, {:get, rest}}
          else
            {acc, {:get, [head | rest]}}
          end

        node, acc ->
          {acc, node}
      end)

    expr2
  end

  defp parse_select([{:kw, :select} | rest]) do
    with {:ok, projection, rest} <- parse_projection_wrapped(rest),
         {:ok, from, rest} <- parse_from(rest),
         {:ok, where, rest} <- parse_where(rest),
         {:ok, order_by, rest} <- parse_order_by(rest),
         {:ok, limit, rest} <- parse_limit(rest) do
      {:ok,
       %__MODULE__{
         projection: projection,
         from: from,
         where: where,
         order_by: order_by,
         limit: limit
       }, rest}
    end
  end

  defp parse_select(_), do: {:error, {:syntax, "Expected SELECT"}}

  defp parse_projection([{:star, nil} | rest]), do: {:ok, :star, rest}
  defp parse_projection(tokens), do: parse_prop_list(tokens, [])

  defp parse_projection_wrapped(tokens) do
    with {:ok, paths, rest} <- parse_projection(tokens) do
      case paths do
        :star -> {:ok, :star, rest}
        paths -> {:ok, {:props, paths}, rest}
      end
    end
  end

  defp parse_prop_list([{:ident, name} | rest], acc) do
    path = String.split(name, ".")

    case rest do
      [{:comma, nil} | rest2] -> parse_prop_list(rest2, [path | acc])
      _ -> {:ok, Enum.reverse([path | acc]), rest}
    end
  end

  defp parse_prop_list(_, _acc), do: {:error, {:syntax, "Projection path expected"}}

  defp parse_from([{:kw, :from}, {:ident, name} | rest]), do: {:ok, name, rest}
  defp parse_from(_), do: {:error, {:syntax, "Expected FROM <alias>"}}

  defp parse_where([{:kw, :where} | rest]) do
    case parse_or(rest) do
      {:ok, expr, rest2} -> {:ok, expr, rest2}
      {:error, {:syntax, _}} = err -> err
    end
  end

  defp parse_where(rest), do: {:ok, nil, rest}

  defp parse_order_by([{:kw, :order}, {:kw, :by}, {:ident, name} | rest]) do
    {dir, rest2} =
      case rest do
        [{:kw, :asc} | r] -> {:asc, r}
        [{:kw, :desc} | r] -> {:desc, r}
        r -> {:asc, r}
      end

    {:ok, {String.split(name, "."), dir}, rest2}
  end

  defp parse_order_by(rest), do: {:ok, nil, rest}

  defp parse_limit([{:kw, :limit}, {:lit, n} | rest]) when is_integer(n) and n > 0,
    do: {:ok, n, rest}

  defp parse_limit([{:kw, :limit} | _]),
    do: {:error, {:syntax, "LIMIT expects a positive integer"}}

  defp parse_limit(rest), do: {:ok, nil, rest}

  defp parse_or(tokens) do
    with {:ok, l, rest} <- parse_and(tokens) do
      collect_binop(rest, l, :or, &parse_and/1)
    end
  end

  defp parse_and(tokens) do
    with {:ok, l, rest} <- parse_unary(tokens) do
      collect_binop(rest, l, :and, &parse_unary/1)
    end
  end

  defp collect_binop([{:kw, tok} | rest2], l, kw, parse_rhs) when tok == kw do
    with {:ok, r, rest3} <- parse_rhs.(rest2) do
      collect_binop(rest3, {kw, l, r}, kw, parse_rhs)
    end
  end

  defp collect_binop(rest, l, _kw, _parse_rhs), do: {:ok, l, rest}

  defp parse_unary([{:kw, :not} | rest]) do
    with {:ok, e, rest2} <- parse_unary(rest) do
      {:ok, {:not, e}, rest2}
    end
  end

  # Parenthesized predicate: WHERE (a = 1 OR b = 2) AND c = 3.
  defp parse_unary([{:lparen, nil} | rest]) do
    with {:ok, e, rest2} <- parse_or(rest),
         [{:rparen, nil} | rest3] <- rest2 do
      {:ok, e, rest3}
    else
      _ -> {:error, {:syntax, "Expected ) after parenthesized predicate"}}
    end
  end

  defp parse_unary(tokens), do: parse_comparison(tokens)

  defp parse_comparison([{:kw, kw} | rest])
       when kw in [:contains, :startswith, :array_contains] do
    with {:ok, {l, r}, rest2} <- parse_paren_pair(rest) do
      {:ok, {kw, l, r}, rest2}
    end
  end

  defp parse_comparison(tokens) do
    with {:ok, l, rest} <- parse_operand(tokens) do
      case rest do
        [{:op, op} | rest2] ->
          with {:ok, r, rest3} <- parse_operand(rest2) do
            {:ok, {:cmp, op, l, r}, rest3}
          end

        [{:kw, :in} | rest2] ->
          with {:ok, lits, rest3} <- parse_literal_list(rest2) do
            {:ok, {:in, l, lits}, rest3}
          end

        _ ->
          {:error, {:syntax, "Expected comparison operator"}}
      end
    end
  end

  # "operand, operand" inside parentheses (the three named functions).
  defp parse_paren_pair(rest) do
    case rest do
      [{:lparen, nil} | rest2] ->
        with {:ok, first, rest3} <- parse_operand(rest2),
             [{:comma, nil} | rest4] <- rest3,
             {:ok, second, rest5} <- parse_operand(rest4),
             [{:rparen, nil} | rest6] <- rest5 do
          {:ok, {first, second}, rest6}
        else
          _ -> {:error, {:syntax, "Malformed function arguments"}}
        end

      _ ->
        {:error, {:syntax, "Expected ("}}
    end
  end

  defp parse_literal_list([{:lparen, nil} | rest]), do: parse_literal_items(rest, [])

  defp parse_literal_list(_), do: {:error, {:syntax, "Expected ( after IN"}}

  defp parse_literal_items([{:lit, v} | rest], acc) do
    case rest do
      [{:comma, nil} | rest2] -> parse_literal_items(rest2, [v | acc])
      [{:rparen, nil} | rest2] -> {:ok, Enum.reverse([v | acc]), rest2}
      _ -> {:error, {:syntax, "Expected , or ) in IN list"}}
    end
  end

  defp parse_literal_items(_, _acc), do: {:error, {:syntax, "Literal list expected"}}

  defp parse_operand([{:lit, v} | rest]), do: {:ok, {:lit, v}, rest}
  defp parse_operand([{:param, name} | rest]), do: {:ok, {:param, name}, rest}
  defp parse_operand([{:kw, true} | rest]), do: {:ok, {:lit, true}, rest}
  defp parse_operand([{:kw, false} | rest]), do: {:ok, {:lit, false}, rest}
  defp parse_operand([{:kw, :null} | rest]), do: {:ok, {:lit, nil}, rest}

  defp parse_operand([{:ident, name} | rest]),
    do: {:ok, {:get, String.split(name, ".")}, rest}

  defp parse_operand(_), do: {:error, {:syntax, "Operand expected"}}
end
