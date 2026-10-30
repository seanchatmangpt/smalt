defmodule Smalt.DataPlane.Cosmos.Sql do
  @moduledoc """
  80/20 Cosmos SQL AST: parse + evaluate the console-contract grammar.

  T09 split (v26.10.29): moved verbatim from `lib/smalt/cosmos_sql.ex`
  (`Smalt.CosmosSql`); `lib/smalt/cosmos_sql.ex` is now a defdelegate
  compatibility shim so external call sites and courts are unchanged.

  Closes the evaluation half of GAP(cosmos-sql-translator-absent): the
  whitelist in `Smalt.DataPlane.Cosmos` stays as the `SELECT * FROM c`
  fast path; every other query is parsed here and evaluated per-document
  against the scanned set.

  Grammar (case-insensitive keywords, whitespace-insensitive):

      SELECT [DISTINCT] [TOP <n>] <proj> FROM <alias>
             [JOIN <join-alias> IN <src.path>]
             [WHERE <pred>]
             [ORDER BY <prop> [ASC|DESC]] [OFFSET <n> LIMIT <m>] [LIMIT <n>]
      FROM    <iter-alias> IN <src.path>  -- cross-array iteration (fan-out)
      JOIN    <join-alias> IN <src.path>  -- sub-array join (same fan-out law;
                                          -- ONE total iterated source per query)

      proj     ::= "*" | <item> ("," <item>)*
      item     ::= <path> ["AS" <alias>]
                | <scalar_fn> "(" <arg> ["," <arg>] ")" "AS" <alias>
      path     ::= <ident> ("." <ident>)*        -- e.g. c, c.a.b
      scalar_fn ::= UPPER | LOWER | LENGTH | CONTAINS
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

  Cross-array iteration (`FROM t IN c.tags`) binds `t` per array element
  (fan-out: N docs x M elements = N x M result rows; each row sees the element
  as `t` while the doc root stays addressable as `c.*`). Composes with WHERE /
  SELECT / ORDER BY. A non-array iteration target (including undefined) is a
  typed `{:error, {:syntax, reason}}` at evaluation time -- fail-closed, never
  a silent wrong answer.

  Anything outside the grammar (joins of 2+ iterated sources, UDFs, aggregates,
  subqueries, scalar functions other than UPPER/LOWER/LENGTH/CONTAINS) is a
  typed `{:error, {:syntax, reason}}` -- the caller answers 400 SyntaxError,
  fail-closed. Aggregates (COUNT(1) et al.) are intentionally NOT admitted.
  """

  @enforce_keys [:projection, :from]
  defstruct [
    :projection,
    :from,
    iterate: nil,
    joins: [],
    distinct: false,
    where: nil,
    order_by: nil,
    top: nil,
    limit: nil,
    offset: nil,
    params: %{},
    udfs: %{}
  ]

  @type t :: %__MODULE__{
          projection: :star | {:props, [path() | proj_item()]},
          from: String.t(),
          iterate: {String.t(), path()} | nil,
          joins: [{String.t(), path()}],
          distinct: boolean(),
          where: expr() | nil,
          order_by: {path(), :asc | :desc} | nil,
          top: pos_integer() | nil,
          limit: pos_integer() | nil,
          offset: non_neg_integer() | nil,
          params: %{optional(String.t()) => term()}
        }

  @type path :: [String.t()]
  @type proj_item :: {:fn, fn_name(), [path() | literal()], String.t()}
  @type fn_name :: :upper | :lower | :length | :contains

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
  def eval_docs(%__MODULE__{iterate: nil} = q, docs) when is_list(docs), do: pipeline(q, docs)

  # Cross-array iteration: fan each doc into one synthetic row per array
  # element, the iteration alias bound as a synthetic key on a copy of the doc
  # (alias shadows any same-named field; the doc root stays addressable). The
  # downstream WHERE / projection / ORDER BY / TOP / OFFSET / LIMIT pipeline is
  # unchanged -- it just sees N x M pre-fanned rows.
  def eval_docs(%__MODULE__{iterate: {alias, rel_path}} = q, docs) when is_list(docs) do
    fanned =
      for doc <- docs, elem <- iter_values(doc, rel_path) do
        Map.put(doc, alias, elem)
      end

    pipeline(%__MODULE__{q | iterate: nil}, fanned)
  end

  # JOIN-position fan-out: identical synthetic-row binding to the FROM IN
  # clause (alias bound per array element on a doc copy; root stays
  # addressable). Parse enforces at most ONE total iterated source, so this
  # clause and the FROM IN clause are mutually exclusive.
  def eval_docs(%__MODULE__{joins: [{alias, rel_path} | _]} = q, docs) when is_list(docs) do
    fanned =
      for doc <- docs, elem <- iter_values(doc, rel_path) do
        Map.put(doc, alias, elem)
      end

    pipeline(%__MODULE__{q | joins: []}, fanned)
  end

  # Undefined or non-array targets contribute no rows here; the typed-SYN
  # contract lives in run/3 (which owns the error channel). Direct
  # parse/1+eval_docs/2 consumers get fan-out-over-nothing = [] (documented).
  defp iter_values(doc, rel_path) do
    case get_in_doc(doc, rel_path) do
      v when is_list(v) -> v
      _ -> []
    end
  end

  defp pipeline(q, docs) do
    matched = for doc <- docs, where_holds?(q, doc), do: project(q, doc)

    matched =
      if q.distinct do
        # DISTINCT: dedup on the serialized result value (first occurrence
        # wins; order of first appearance preserved for the later ORDER BY).
        Enum.uniq_by(matched, &:erlang.term_to_binary/1)
      else
        matched
      end

    matched =
      case q.order_by do
        {path, dir} -> Enum.sort_by(matched, &sort_key(&1, path), dir)
        nil -> matched
      end

    matched =
      case q.top do
        nil -> matched
        n -> Enum.take(matched, n)
      end

    matched =
      case q.offset do
        nil -> matched
        n -> Enum.drop(matched, n)
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
      {:ok, q} ->
        with :ok <- iterate_targets_ok?(q, docs),
             :ok <- projection_fns_resolved?(q) do
          {:ok, eval_docs(q, docs)}
        end

      {:error, {:syntax, _}} = err ->
        err
    end
  end

  # Unknown-function projection guard: an unknown ident call parses as a UDF
  # call; with no registered UDF of that name it must be a typed syntax error,
  # never a silent all-undefined projection (witnessed tier breakage FIX-3).
  defp projection_fns_resolved?(%__MODULE__{projection: {:props, items}, udfs: udfs}) do
    Enum.find_value(items, :ok, fn
      {:fn, {:udf, name}, _args, _alias} ->
        if Map.has_key?(udfs, name),
          do: nil,
          else: {:error, {:syntax, "Unknown function in projection: #{name}"}}

      _item ->
        nil
    end)
  end

  defp projection_fns_resolved?(%__MODULE__{}), do: :ok

  # Typed SYN on a non-array (or undefined) iteration target. Evaluated over
  # the scanned set before any fan-out; a single bad doc fails the query.
  defp iterate_targets_ok?(%__MODULE__{iterate: nil, joins: []}, _docs), do: :ok

  defp iterate_targets_ok?(%__MODULE__{joins: [{alias, rel_path} | _], from: root}, docs) do
    full = Enum.join([root | rel_path], ".")

    if Enum.all?(docs, fn doc -> is_list(get_in_doc(doc, rel_path)) end) do
      :ok
    else
      {:error,
       {:syntax,
        "JOIN #{alias} IN #{full} requires an array iteration target; '#{full}' is not an array"}}
    end
  end

  defp iterate_targets_ok?(%__MODULE__{iterate: {alias, rel_path}, from: root}, docs) do
    full = Enum.join([root | rel_path], ".")

    if Enum.all?(docs, fn doc -> is_list(get_in_doc(doc, rel_path)) end) do
      :ok
    else
      {:error,
       {:syntax,
        "FROM #{alias} IN #{full} requires an array iteration target; '#{full}' is not an array"}}
    end
  end

  # -- Evaluation -----------------------------------------------------------

  defp where_holds?(%__MODULE__{where: nil}, _doc), do: true

  defp where_holds?(%__MODULE__{where: where, params: params}, doc),
    do: truthy?(where, doc, params)

  defp project(%__MODULE__{projection: :star}, doc), do: doc

  # Subset projection: each projected path keys by its LAST segment (c.a.b ->
  # "b") unless an explicit AS alias renames it; a missing (undefined) field is
  # OMITTED, never null (real Cosmos semantics). Function projections evaluate
  # per-document; a non-applicable argument (e.g. UPPER over a number) yields
  # undefined -> omitted.
  defp project(%__MODULE__{projection: {:props, items}, udfs: udfs}, doc) do
    Enum.reduce(items, %{}, fn
      path, acc when is_list(path) ->
        case get_in_doc(doc, path) do
          nil -> acc
          value -> Map.put(acc, List.last(path), value)
        end

      {path, alias}, acc ->
        case get_in_doc(doc, path) do
          nil -> acc
          value -> Map.put(acc, alias, value)
        end

      {:fn, {:udf, name}, args, alias}, acc ->
        case eval_udf(udfs, name, args, doc) do
          nil -> acc
          value -> Map.put(acc, alias, value)
        end

      {:fn, name, args, alias}, acc ->
        case eval_fn(name, args, doc) do
          nil -> acc
          value -> Map.put(acc, alias, value)
        end
    end)
  end

  @doc false
  def eval_fn(name, args, doc)

  def eval_fn(:upper, [path], doc) do
    case get_in_doc(doc, path) do
      v when is_binary(v) -> String.upcase(v)
      _ -> nil
    end
  end

  def eval_fn(:lower, [path], doc) do
    case get_in_doc(doc, path) do
      v when is_binary(v) -> String.downcase(v)
      _ -> nil
    end
  end

  def eval_fn(:length, [path], doc) do
    case get_in_doc(doc, path) do
      v when is_binary(v) -> String.length(v)
      v when is_list(v) -> length(v)
      _ -> nil
    end
  end

  def eval_fn(:contains, [a, b], doc) do
    case {proj_arg(a, doc), proj_arg(b, doc)} do
      {x, y} when is_binary(x) and is_binary(y) -> String.contains?(x, y)
      _ -> nil
    end
  end

  def eval_fn(_name, _args, _doc), do: nil

  defp proj_arg(path, doc) when is_list(path), do: get_in_doc(doc, path)
  defp proj_arg(lit, _doc), do: lit

  # -- User-defined function kernel (lane w6g) ---------------------------------
  #
  # Real Cosmos UDF bodies are JavaScript. The emulator executes the honest
  # kernel: `function <name>(<param>) { return <expr>; }` where <expr> is a
  # SINGLE expression over literals, the parameter (dotted paths allowed),
  # `+ - * /`, unary minus, parentheses, `true/false/null`. Anything outside
  # the kernel parses/registers fine but evaluates to undefined (omitted from
  # the projection row) — fail-closed, never a silent wrong answer beyond the
  # documented kernel bounds.

  defp eval_udf(udfs, name, args, doc) do
    case {Map.get(udfs, name), args} do
      {body, [path]} when is_binary(body) and is_list(path) ->
        arg = get_in_doc(doc, path)
        udf_kernel_eval(body, arg)

      _ ->
        nil
    end
  end

  # Kernel expression grammar: literals | param-rooted dotted path |
  # + - * / | unary minus | parentheses | true/false/null.
  defp udf_kernel_eval(body, arg) do
    case kernel_function_extract(body) do
      {param, expr_src} when is_binary(expr_src) ->
        case kernel_tokens(expr_src) do
          {:ok, toks} ->
            case kernel_parse_expr(toks, param, arg) do
              {:ok, v} -> v
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp kernel_function_extract(body) do
    re = ~r/^\s*function\s+[A-Za-z_$][\w$]*\s*\(\s*([A-Za-z_$][\w$]*)\s*\)\s*\{\s*return\s+(.*);\s*\}\s*$/s

    case Regex.run(re, body) do
      [_, param, expr] -> {param, expr}
      _ -> :error
    end
  end

  defp kernel_tokens(src) do
    toks =
      Regex.scan(
        ~r/\s*(\d+\.\d+|\d+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*|[-+*\/()])/,
        src
      )
      |> Enum.map(fn [_, t] -> t end)

    if Enum.join(toks, "") |> String.replace(~r/\s+/, "") == String.replace(src, ~r/\s+/, "") do
      {:ok, toks}
    else
      :error
    end
  end

  # Precedence climb: expr := addsub; addsub := muldiv (('+'|'-') muldiv)*;
  # muldiv := unary (('*'|'/') unary)*; unary := '-' unary | primary.
  defp kernel_parse_expr(toks, param, arg) do
    case kernel_addsub(toks, param, arg) do
      {:ok, v, []} -> {:ok, v}
      _ -> :error
    end
  end

  defp kernel_addsub([x | rest], param, arg) do
    kernel_addsub_rest(rest, x, param, arg)
  end

  defp kernel_addsub([], _param, _arg), do: :error

  defp kernel_addsub_rest([op | rest], l, param, arg) when op in ["+", "-"] do
    case kernel_muldiv(rest, param, arg) do
      {:ok, r, rest2} ->
        v = if op == "+", do: kernel_add(l, r), else: kernel_sub(l, r)
        kernel_addsub_rest(rest2, v, param, arg)

      _ ->
        :error
    end
  end

  defp kernel_addsub_rest(rest, v, _param, _arg), do: {:ok, v, rest}

  defp kernel_muldiv([x | rest], param, arg) do
    kernel_muldiv_rest(rest, x, param, arg)
  end

  defp kernel_muldiv([], _param, _arg), do: :error

  defp kernel_muldiv_rest([op | rest], l, param, arg) when op in ["*", "/"] do
    case kernel_unary(rest, param, arg) do
      {:ok, r, rest2} ->
        v =
          cond do
            op == "*" -> kernel_mul(l, r)
            op == "/" and r in [0, 0.0] -> nil
            op == "/" -> kernel_div(l, r)
          end

        if is_nil(v) do
          :error
        else
          kernel_muldiv_rest(rest2, v, param, arg)
        end

      _ ->
        :error
    end
  end

  defp kernel_muldiv_rest(rest, v, _param, _arg), do: {:ok, v, rest}

  defp kernel_unary(["-" | rest], param, arg) do
    case kernel_unary(rest, param, arg) do
      {:ok, v, rest2} when is_number(v) -> {:ok, -v, rest2}
      _ -> :error
    end
  end

  defp kernel_unary(toks, param, arg), do: kernel_primary(toks, param, arg)

  defp kernel_primary(["(" | rest], param, arg) do
    case kernel_addsub(rest, param, arg) do
      {:ok, v, [")" | rest2]} -> {:ok, v, rest2}
      _ -> :error
    end
  end

  defp kernel_primary([t | rest], _param, _arg) when t in ["true", "false", "null"] do
    {:ok, kernel_literal(t), rest}
  end

  defp kernel_primary([t | rest], param, arg) when is_binary(t) do
    cond do
      t =~ ~r/^["']/ ->
        inner = String.slice(t, 1..-2//1)

        {:ok, String.replace(inner, ~r/\\(.)/, "\\1"), rest}

      t =~ ~r/^\d/ ->
        v =
          if String.contains?(t, ".") do
            String.to_float(t)
          else
            String.to_integer(t)
          end

        {:ok, v, rest}

      String.contains?(t, ".") ->
        segs = String.split(t, ".")
        [root | path] = segs

        if root == param do
          {:ok, get_in_doc(arg_map(arg), path), rest}
        else
          :error
        end

      t == param ->
        {:ok, arg, rest}

      true ->
        :error
    end
  end

  defp kernel_primary(_, _param, _arg), do: :error

  defp arg_map(v) when is_map(v), do: v
  defp arg_map(_), do: %{}

  defp kernel_literal("true"), do: true
  defp kernel_literal("false"), do: false
  defp kernel_literal("null"), do: nil

  defp kernel_add(l, r) when is_number(l) and is_number(r), do: l + r
  defp kernel_add(l, r) when is_binary(l) and is_binary(r), do: l <> r
  defp kernel_add(_l, _r), do: nil

  defp kernel_sub(l, r) when is_number(l) and is_number(r), do: l - r
  defp kernel_sub(_l, _r), do: nil

  defp kernel_mul(l, r) when is_number(l) and is_number(r), do: l * r
  defp kernel_mul(_l, _r), do: nil

  defp kernel_div(l, r) when is_number(l) and is_number(r) and r != 0, do: l / r
  defp kernel_div(_l, _r), do: nil

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
    :offset,
    :top,
    :as,
    :and,
    :or,
    :not,
    :in,
    :contains,
    :startswith,
    :array_contains,
    :distinct,
    :join,
    true,
    false,
    :null
  ]

  # Binary forms of @keywords for non-minting keyword matching (JA16-D1).
  @keyword_strings Enum.map(@keywords, &Atom.to_string/1)

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

    # JA16-D1: wire-sourced words are never minted into atoms (same law as
    # amqp/frame_codec.ex:800). Keyword match is a binary comparison against
    # the compile-time keyword strings; String.to_existing_atom is only
    # reached for words that ARE keywords, whose atoms already exist in
    # @keywords — the atom table never grows from query content.
    lw = String.downcase(w)

    token =
      if lw in @keyword_strings do
        {:kw, String.to_existing_atom(lw)}
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

      {:error, {:unsupported, _}} = err ->
        err

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
        {:props, items} ->
          {:props, Enum.map(items, &strip_item_alias(&1, down))}

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

  defp strip_item_alias({:fn, f, args, alias}, down) do
    args =
      Enum.map(args, fn
        path when is_list(path) -> strip_path_alias(path, down)
        lit -> lit
      end)

    {:fn, f, args, alias}
  end

  defp strip_item_alias({path, alias}, down), do: {strip_path_alias(path, down), alias}
  defp strip_item_alias(path, down) when is_list(path), do: strip_path_alias(path, down)

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
    with {:ok, top, rest} <- parse_top(rest),
         {:ok, distinct, rest} <- parse_distinct(rest),
         {:ok, projection, rest} <- parse_projection_wrapped(rest),
         {:ok, {from, iterate}, rest} <- parse_from(rest),
         {:ok, joins, rest} <- parse_joins(rest),
         {:ok, where, rest} <- parse_where(rest),
         {:ok, order_by, rest} <- parse_order_by(rest),
         {:ok, offset, limit, rest} <- parse_offset_limit(rest),
         {:ok, limit, rest} <- parse_trailing_limit(limit, rest) do
      cond do
        # 80/20 iterated-source cap (moduledoc: "joins of 2+ iterated
        # sources" stay outside the grammar) — FROM IN plus any JOIN counts.
        (iterate != nil and joins != []) or length(joins) > 1 ->
          {:error,
           {:syntax,
            "Joins of 2+ iterated sources are not supported (one FROM IN or JOIN per query)"}}

        distinct and match?([{:ident, g} | _] when g in ["group"], rest) ->
          # Real Cosmos refuses DISTINCT with GROUP BY (aggregates are not
          # in this grammar at all; give the specific refusal message).
          {:error, {:syntax, "DISTINCT is not supported with GROUP BY"}}

        true ->
          {:ok,
           %__MODULE__{
             projection: projection,
             from: from,
             iterate: iterate,
             joins: joins,
             distinct: distinct,
             where: where,
             order_by: order_by,
             top: top,
             offset: offset,
             limit: limit
           }, rest}
      end
    end
  end

  defp parse_select(_), do: {:error, {:syntax, "Expected SELECT"}}

  defp parse_distinct([{:kw, :distinct} | rest]), do: {:ok, true, rest}
  defp parse_distinct(rest), do: {:ok, false, rest}

  # Zero-or-more `JOIN <alias> IN <dotted.path>` clauses (parse-time cap of
  # one total iterated source is enforced in parse_select).
  defp parse_joins([{:kw, :join} | _] = tokens), do: parse_join_list(tokens, [])

  defp parse_joins(rest), do: {:ok, [], rest}

  defp parse_join_list([{:kw, :join}, {:ident, alias}, {:kw, :in}, {:ident, src} | rest], acc) do
    case String.split(src, ".") do
      [_root] ->
        {:error, {:syntax, "JOIN #{alias} IN expects a dotted property path (e.g. c.tags)"}}

      [_root | rel] ->
        parse_join_list(rest, [{alias, rel} | acc])
    end
  end

  defp parse_join_list([{:kw, :join} | _], _acc),
    do: {:error, {:syntax, "JOIN expects <alias> IN <dotted.path>"}}

  defp parse_join_list(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_top([{:kw, :top}, {:lit, n} | rest]) when is_integer(n) and n > 0,
    do: {:ok, n, rest}

  defp parse_top([{:kw, :top} | _]),
    do: {:error, {:syntax, "TOP expects a positive integer"}}

  defp parse_top(rest), do: {:ok, nil, rest}

  # Real Cosmos pair form: OFFSET <n> LIMIT <m> (both required together,
  # n >= 0, m >= 1). A bare OFFSET without LIMIT is a typed syntax error.
  defp parse_offset_limit([{:kw, :offset}, {:lit, n}, {:kw, :limit}, {:lit, m} | rest])
       when is_integer(n) and n >= 0 and is_integer(m) and m > 0,
       do: {:ok, n, m, rest}

  defp parse_offset_limit([{:kw, :offset} | _]),
    do: {:error, {:syntax, "OFFSET requires a paired non-negative OFFSET <n> LIMIT <m>"}}

  defp parse_offset_limit(rest), do: {:ok, nil, nil, rest}

  # Legacy (pre-raise) bare LIMIT clause: still admitted after ORDER BY / the
  # OFFSET LIMIT pair for back-compat with existing consumers.
  defp parse_trailing_limit(nil, rest), do: parse_limit(rest)
  defp parse_trailing_limit(limit, rest), do: {:ok, limit, rest}

  defp parse_projection([{:star, nil} | rest]), do: {:ok, :star, rest}
  defp parse_projection(tokens), do: parse_prop_list(tokens, [])

  defp parse_projection_wrapped(tokens) do
    with {:ok, items, rest} <- parse_projection(tokens) do
      case items do
        :star -> {:ok, :star, rest}
        items -> {:ok, {:props, items}, rest}
      end
    end
  end

  # Scalar function projection: UPPER(x) / LOWER(x) / LENGTH(x) / CONTAINS(a, b),
  # alias mandatory (real Cosmos requires a target for a computed value).
  # An unknown ident call parses as a USER-DEFINED function call
  # ({:fn, {:udf, name}, args, alias}) — resolution against the container's
  # UDF registry happens at query time (Smalt.DataPlane.Cosmos.resolve_udfs);
  # unknown UDFs are a typed 400 there, never a parse-time lie.
  defp parse_prop_list([{:ident, fname}, {:lparen, nil} | rest], acc) do
    known = %{"UPPER" => :upper, "LOWER" => :lower, "LENGTH" => :length, "CONTAINS" => :contains}

    case Map.fetch(known, String.upcase(fname)) do
      {:ok, f} ->
        with {:ok, args, rest2} <- parse_fn_args(rest, f, []) do
          case rest2 do
            [{:kw, :as}, {:ident, alias} | rest3] ->
              parse_prop_list_tail(rest3, [{:fn, f, args, alias} | acc])

            _ ->
              {:error,
               {:syntax,
                "AS alias required after #{String.upcase(fname)}() projection (computed values need a target name)"}}
          end
        end

      :error ->
        with {:ok, args, rest2} <- parse_fn_args(rest, :udf, []) do
          case rest2 do
            [{:kw, :as}, {:ident, alias} | rest3] ->
              parse_prop_list_tail(rest3, [{:fn, {:udf, fname}, args, alias} | acc])

            _ ->
              {:error,
               {:syntax,
                "AS alias required after #{fname}() projection (computed values need a target name)"}}
          end
        end
    end
  end

  # CONTAINS is a lexer keyword, so its projection form rides a kw-token clause
  # (same alias-mandatory contract as the ident-named scalar fns).
  defp parse_prop_list([{:kw, :contains}, {:lparen, nil} | rest], acc) do
    with {:ok, args, rest2} <- parse_fn_args(rest, :contains, []) do
      case rest2 do
        [{:kw, :as}, {:ident, alias} | rest3] ->
          parse_prop_list_tail(rest3, [{:fn, :contains, args, alias} | acc])

        _ ->
          {:error, {:syntax, "AS alias required after CONTAINS() projection (computed values need a target name)"}}
      end
    end
  end

  # Plain (optionally AS-renamed) path item. Ordered AFTER the fn clause so
  # `UPPER(` is claimed by the function arm, not consumed as a bare path.
  defp parse_prop_list([{:ident, name} | rest], acc) do
    path = String.split(name, ".")

    case rest do
      [{:comma, nil} | rest2] -> parse_prop_list(rest2, [path | acc])
      [{:kw, :as}, {:ident, alias} | rest2] -> {:ok, Enum.reverse([{path, alias} | acc]), rest2}
      _ -> {:ok, Enum.reverse([path | acc]), rest}
    end
  end

  defp parse_prop_list(_, _acc), do: {:error, {:syntax, "Projection path expected"}}

  # Continuation of a comma-separated projection list after a function item.
  defp parse_prop_list_tail([{:comma, nil} | rest], acc), do: parse_prop_list(rest, acc)
  defp parse_prop_list_tail(rest, acc), do: {:ok, Enum.reverse(acc), rest}

  # Function arguments over tokens: scalar fns take 1 arg (UPPER/LOWER/LENGTH)
  # or 2 (CONTAINS); each arg is a path (ident) or a literal.
  defp parse_fn_args(rest, f, _acc) do
    n = if f == :contains, do: 2, else: 1

    with {:ok, args, rest2} <- parse_fn_arg_list(rest, n, []) do
      case rest2 do
        [{:rparen, nil} | rest3] -> {:ok, args, rest3}
        _ -> {:error, {:syntax, "Expected ) after #{String.upcase(Atom.to_string(f))}() arguments"}}
      end
    end
  end

  defp parse_fn_arg_list(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_fn_arg_list(rest, n, acc) do
    case rest do
      [tok | rest2] when elem(tok, 0) in [:ident, :lit] ->
        with {:ok, arg} <- parse_fn_arg(tok) do
          if n == 1 do
            parse_fn_arg_list(rest2, 0, [arg | acc])
          else
            case rest2 do
              [{:comma, nil} | rest3] -> parse_fn_arg_list(rest3, 1, [arg | acc])
              _ -> {:error, {:syntax, "Expected , between function arguments"}}
            end
          end
        end

      _ ->
        {:error, {:syntax, "Malformed function arguments"}}
    end
  end

  defp parse_fn_arg({:ident, name}), do: {:ok, String.split(name, ".")}
  defp parse_fn_arg({:lit, v}), do: {:ok, v}
  defp parse_fn_arg(_), do: {:error, {:syntax, "Function argument expected"}}

  # Cross-array iteration (`FROM t IN c.tags`): the iteration alias is stored
  # with its SOURCE path relative to the doc root (head segment = the root
  # alias, stripped here); evaluation fans out per element -- see eval_docs/2.
  defp parse_from([{:kw, :from}, {:ident, alias}, {:kw, :in}, {:ident, src} | rest]) do
    case String.split(src, ".") do
      [_root] ->
        {:error, {:syntax, "FROM #{alias} IN expects a dotted property path (e.g. c.tags)"}}

      [root | rel] ->
        {:ok, {root, {alias, rel}}, rest}
    end
  end

  defp parse_from([{:kw, :from}, {:ident, name} | rest]), do: {:ok, {name, nil}, rest}
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
