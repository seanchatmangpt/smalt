defmodule Smalt.DataPlane.KQL do
  @moduledoc """
  Deterministic KQL-subset filter/aggregation engine for Sentinel/ResourceGraph
  query strings.

  Parses pipelines of:

      | where <pred> | take N | sort by <col> asc|desc [nulls first|last]
      | order by <col> asc|desc [nulls first|last]
      | summarize count() [, sum(C)|avg(C)|min(C)|max(C)]* [by K1, K2]
      | project Alias = Col, Total = <scalar-expr>, ...
      | extend Name = <scalar-expr>, ...

  into an AST (no eval, no injection surface) and executes it over a list of
  row maps with string column keys (e.g. the Sentinel base columns `ledgerId`,
  `tenantId`, `subjectSha256`, `eventId`, `sha256Hash`, `TimeGenerated`).

  Scalar expressions (comparison RHS, project/extend computed columns):

      col | number | "string" | -number | (expr) | expr + - * / expr
      | ago(<dur>) | now() | datetime("<iso8601>")

  Time functions resolve against an execution-time anchor (`DateTime.utc_now/0`
  captured once per `run/2`). `ago(1h)` matches a `TimeGenerated` column stored
  as `%DateTime{}` OR as an ISO8601 string (DCR-ingested rows carry ISO
  strings; `to_datetime/1` normalizes both).

  Pure: `run/2` returns `{:ok, rows'}` or `{:error, {:parse | :limit, msg}}`.
  Parse errors are typed KQL-style `SYN-` codes with byte position:

      "SYN0002: unexpected token 'frobnicate' (position 14)"

  Fail-closed: any unknown pipeline operator, aggregate, comparison operator,
  or function is a typed parse error — never a silent-ignore.
  """

  @max_query_length 2_000
  @max_ast_depth 20
  @max_take 1_000

  @type row :: %{optional(String.t()) => term()}
  @type run_err :: {:error, {:parse | :limit, String.t()}}

  @order_dirs %{"asc" => :asc, "desc" => :desc}
  @nulls_pos %{"first" => :first, "last" => :last}
  @comparison_atoms %{
    "==" => :eq,
    "!=" => :neq,
    "contains" => :contains,
    "startswith" => :startswith,
    "endswith" => :endswith,
    "has" => :has,
    ">" => :gt,
    "<" => :lt,
    ">=" => :gte,
    "<=" => :lte
  }
  @bool_ops %{"and" => :and, "or" => :or}
  @bp %{or: 1, and: 2}
  @bool_words Map.keys(@bool_ops)

  @aggregates ~w(count sum avg min max)

  # SYN- error codes (KQL-style typed parse errors; position = byte offset).
  @syn_unexpected "SYN0002"
  @syn_operand "SYN0003"
  @syn_unknown "SYN0004"
  @syn_string "SYN0005"

  @spec run([row], String.t()) :: {:ok, [row]} | run_err
  def run(rows, query) when is_list(rows) and is_binary(query) do
    with :ok <- check_query_length(query),
         {:ok, stages} <- parse(query) do
      case max_stage_depth(stages) do
        depth when depth <= @max_ast_depth -> execute(stages, rows, DateTime.utc_now())
        _ -> {:error, {:limit, "AST depth exceeds #{@max_ast_depth}"}}
      end
    end
  end

  def run(_rows, _query), do: {:error, "query must be a string, rows a list"}

  ## -- Pipeline execution ----------------------------------------------------

  defp execute(stages, rows, now) do
    Enum.reduce_while(stages, {:ok, rows}, fn
      stage, {:ok, acc} -> {:cont, apply_stage(stage, acc, now)}
      _stage, {:error, _} = err -> {:halt, err}
    end)
  end

  defp apply_stage({:take, n}, rows, _now) do
    if n <= @max_take do
      {:ok, Enum.take(rows, n)}
    else
      {:error, {:limit, "take #{n} exceeds cap of #{@max_take}"}}
    end
  end

  defp apply_stage({:where, pred}, rows, now),
    do: {:ok, Enum.filter(rows, &eval(pred, &1, now))}

  # order by / sort by: direction + optional explicit nulls placement.
  # Default (no explicit `nulls` clause) preserves the historical engine rule:
  # missing columns sort first regardless of direction; Erlang's sort is
  # stable, so equal keys keep input order — deterministic output.
  defp apply_stage({:order, col, dir, nil}, rows, _now) do
    {:ok, Enum.sort_by(rows, &sort_key(&1, col, numeric_column?(rows, col)), dir)}
  end

  defp apply_stage({:order, col, dir, nulls}, rows, _now) do
    {nils, rest} = Enum.split_with(rows, &is_nil(Map.get(&1, col)))
    sorted = Enum.sort_by(rest, &sort_key(&1, col, numeric_column?(rest, col)), dir)

    case nulls do
      :first -> {:ok, nils ++ sorted}
      :last -> {:ok, sorted ++ nils}
    end
  end

  defp apply_stage({:project, items}, rows, now) do
    {:ok,
     Enum.map(rows, fn row ->
       Map.new(items, fn {name, expr} -> {name, eval_scalar(expr, row, now)} end)
     end)}
  end

  defp apply_stage({:extend, items}, rows, now) do
    {:ok,
     Enum.map(rows, fn row ->
       Enum.reduce(items, row, fn {name, expr}, acc ->
         Map.put(acc, name, eval_scalar(expr, row, now))
       end)
     end)}
  end

  # summarize: group by the by-key tuple (groups in first-appearance order),
  # one output row per group: by keys first, then aggregate columns under real
  # Kusto suffix naming (count_, sum_X, avg_X, min_X, max_X). `summarize by K`
  # with no aggregate yields distinct key rows. Empty input with no `by` gives
  # one zero/nil row (Kusto's empty-set aggregate semantics).
  defp apply_stage({:summarize, aggs, []}, rows, _now) do
    if rows == [] and aggs != [] do
      {:ok, [empty_agg_row(aggs)]}
    else
      {:ok, [summarize_row(rows, aggs, %{})]}
    end
  end

  defp apply_stage({:summarize, aggs, by_keys}, rows, _now) do
    groups = Enum.group_by(rows, fn row -> Enum.map(by_keys, &by_key_value(row, &1)) end)

    {:ok,
     Enum.map(groups, fn {key_vals, group_rows} ->
       by_map =
         by_keys
         |> Enum.map(&by_key_name/1)
         |> Enum.zip(key_vals)
         |> Map.new()

       summarize_row(group_rows, aggs, by_map)
     end)}
  end

  defp summarize_row(group_rows, aggs, by_map) do
    Map.merge(by_map, Map.new(aggs, &apply_agg(&1, group_rows)))
  end

  defp empty_agg_row(aggs),
    do:
      Map.new(aggs, fn
        {:count, "count_"} -> {"count_", 0}
        {fun, out, _col} -> {out, agg_over(fun, [])}
      end)

  defp apply_agg({:count, "count_"}, group_rows), do: {"count_", length(group_rows)}

  defp apply_agg({fun, out, col}, group_rows),
    do: {out, agg_over(fun, Enum.reject(Enum.map(group_rows, &Map.get(&1, col)), &is_nil/1))}

  defp agg_over(_fun, []), do: nil

  defp agg_over(:sum, values) do
    case numeric_values(values) do
      nil -> nil
      nums -> Enum.sum(nums)
    end
  end

  defp agg_over(:avg, values) do
    case numeric_values(values) do
      nil -> nil
      nums -> Enum.sum(nums) / length(nums)
    end
  end

  # min/max over mixed values: numeric when every value parses as a number,
  # lexicographic (via to_str) otherwise — mirrors the sort-by typing rule.
  defp agg_over(fun, values) when fun in [:min, :max] do
    pick = if fun == :min, do: 0, else: 1

    case numeric_values(values) do
      nil -> values |> Enum.map(&to_str/1) |> Enum.min_max() |> elem(pick)
      nums -> nums |> Enum.min_max() |> elem(pick)
    end
  end

  # all-numeric -> numbers; any non-numeric -> nil (Kusto would error; the
  # engine fails soft to a nil aggregate cell rather than failing the query).
  defp numeric_values(values) do
    parsed = Enum.map(values, &number/1)

    if Enum.all?(parsed, &match?({:ok, _}, &1)) do
      Enum.map(parsed, fn {:ok, n} -> n end)
    end
  end

  # Numeric order rule: a column sorts numerically ONLY when every present
  # (non-nil) value in the rowset parses as a number — otherwise the sort is
  # lexicographic. Rationale: `column_type/2` in the Sentinel plane advertises
  # "long"/"real" for numeric columns, and real Kusto sorts "10" > "9"
  # numerically; per-column typing is not tracked in this engine, so the
  # all-values-parse rule is the cheap local equivalent.
  defp numeric_column?(rows, col) do
    Enum.all?(rows, fn row ->
      case Map.get(row, col) do
        nil -> true
        v -> match?({:ok, _}, number(v))
      end
    end)
  end

  # Missing columns sort first (tag {0, ""}); Erlang's sort is stable, so equal
  # keys keep input order — deterministic output. Keys are uniform {tag, value}
  # tuples so number/string branches never mix incomparable terms.
  defp sort_key(row, col, numeric) do
    case Map.get(row, col) do
      nil ->
        {0, ""}

      v ->
        if numeric do
          case number(v) do
            {:ok, n} -> {1, n}
            # unreachable when numeric_column?/2 held, kept total for safety
            :error -> {1, to_str(v)}
          end
        else
          {1, to_str(v)}
        end
    end
  end

  ## -- Scalar expression evaluation ---------------------------------------------

  defp eval_scalar({:col, name}, row, _now), do: Map.get(row, name)

  defp eval_scalar({:lit, v}, _row, _now), do: v

  defp eval_scalar({:f, "ago", dur}, _row, now),
    do: DateTime.add(now, -duration_ms(dur), :millisecond)

  defp eval_scalar({:f, "now", []}, _row, now), do: now

  defp eval_scalar({:f, "datetime", [iso]}, _row, _now) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # Arithmetic is numeric-only; non-numeric operand -> nil (Kusto null
  # propagation: null op anything = null). Division by zero -> nil, not raise.
  defp eval_scalar({:arith, op, l, r}, row, now) do
    case {eval_scalar(l, row, now), eval_scalar(r, row, now)} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {a, b} ->
        case {number(a), number(b)} do
          {{:ok, na}, {:ok, nb}} ->
            case op do
              :+ -> na + nb
              :- -> na - nb
              :* -> na * nb
              :/ when nb != 0 -> na / nb
              :/ -> nil
            end

          _ ->
            nil
        end
    end
  end

  # Parse-time validated duration grammar; defensive default here is 0.
  defp duration_ms(dur) do
    [_, n, unit] = Regex.run(~r/^(\d+)(ms|s|m|h|d)$/, dur)
    n = String.to_integer(n)

    case unit do
      "ms" -> n
      "s" -> n * 1000
      "m" -> n * 60_000
      "h" -> n * 3_600_000
      "d" -> n * 86_400_000
    end
  end

  ## -- Predicates -------------------------------------------------------------

  defp eval({:and, l, r}, row, now), do: eval(l, row, now) and eval(r, row, now)
  defp eval({:or, l, r}, row, now), do: eval(l, row, now) or eval(r, row, now)

  defp eval({:eq, col, rhs}, row, now) do
    case Map.get(row, col) do
      nil -> false
      v -> v == eval_scalar(rhs, row, now)
    end
  end

  defp eval({:neq, col, rhs}, row, now) do
    case Map.get(row, col) do
      # null is not comparable in Kusto — a null comparison is unknown, never true
      nil -> false
      v -> v != eval_scalar(rhs, row, now)
    end
  end

  defp eval({op, col, rhs}, row, now) when op in [:contains, :startswith, :endswith] do
    case Map.get(row, col) do
      nil ->
        false

      v ->
        # Real Kusto: contains/startswith/endswith are case-INsensitive; only
        # the explicit _cs variants are case-sensitive. Compare downcased.
        #
        # Known divergence (KD-class, parked): downcase-folding is not full
        # Kusto case-folding — e.g. 'İ' (U+0130) downcases to "i̇" (i + combining
        # dot) while Kusto folds it to "i", and 'ß'/'ss' asymmetries differ.
        # The asymmetry is inherent to per-codepoint String.downcase/2; forcing
        # full Unicode case-folding parity here is not cheap, so the divergence
        # stands documented rather than fixed. ASCII and common Latin-1 folding
        # match Kusto.
        v = String.downcase(to_str(v))
        lit = String.downcase(to_str(eval_scalar(rhs, row, now)))

        case op do
          :contains -> String.contains?(v, lit)
          :startswith -> String.starts_with?(v, lit)
          :endswith -> String.ends_with?(v, lit)
        end
    end
  end

  # Kusto `has`: case-insensitive WHOLE-TERM match — the needle must appear as
  # a complete term delimited by non-alphanumerics ("error" has-matches
  # "an error occurred" but not "errors").
  defp eval({:has, col, rhs}, row, now) do
    case Map.get(row, col) do
      nil ->
        false

      v ->
        needle = String.downcase(to_str(eval_scalar(rhs, row, now)))
        terms = String.split(String.downcase(to_str(v)), ~r/[^a-z0-9]+/, trim: true)
        needle in terms
    end
  end

  defp eval({op, col, rhs}, row, now) when op in [:gt, :lt, :gte, :lte] do
    case Map.get(row, col) do
      nil -> false
      v -> compare(op, v, eval_scalar(rhs, row, now))
    end
  end

  defp eval({:between, col, lo, hi}, row, now) do
    case Map.get(row, col) do
      nil ->
        false

      v ->
        compare(:gte, v, eval_scalar(lo, row, now)) and
          compare(:lte, v, eval_scalar(hi, row, now))
    end
  end

  # Datetime-aware ordering comparison: if either side resolves to a
  # %DateTime{}, both sides are normalized through to_datetime/1 (ISO8601
  # strings stand in for DateTime columns); otherwise fall back to numbers.
  defp compare(op, a, b) when op in [:gt, :lt, :gte, :lte] do
    cond do
      is_struct(a, DateTime) or is_struct(b, DateTime) ->
        case {to_datetime(a), to_datetime(b)} do
          {{:ok, da}, {:ok, db}} -> apply_dt_cmp(op, DateTime.compare(da, db))
          _ -> false
        end

      true ->
        case {number(a), number(b)} do
          {{:ok, na}, {:ok, nb}} -> apply_cmp(op, na, nb)
          _ -> false
        end
    end
  end

  defp apply_dt_cmp(op, cmp) when op in [:gt, :gte] and cmp == :eq, do: op == :gte
  defp apply_dt_cmp(op, cmp) when op in [:lt, :lte] and cmp == :eq, do: op == :lte
  defp apply_dt_cmp(op, :gt) when op in [:gt, :gte], do: true
  defp apply_dt_cmp(op, :lt) when op in [:lt, :lte], do: true
  defp apply_dt_cmp(_op, _cmp), do: false

  defp to_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp to_datetime(v) do
    case DateTime.from_iso8601(to_str(v)) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp apply_cmp(:gt, a, b), do: a > b
  defp apply_cmp(:lt, a, b), do: a < b
  defp apply_cmp(:gte, a, b), do: a >= b
  defp apply_cmp(:lte, a, b), do: a <= b

  defp number(n) when is_integer(n) or is_float(n), do: {:ok, n}

  defp number(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(v) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  defp number(_), do: :error

  # SHIM-COURT-visible coercion contract: predicates must never raise out of
  # run/2 ({:ok,_}|{:error,_} contract, hostile-ingest reachable via Sentinel
  # nested maps). inspect/1 is total over all terms — Protocol.UndefinedError
  # on maps/tuples/lists is impossible. Note: list->charlist silent coercion
  # (to_string([?a,?b]) == "ab") is intentionally gone — lists now inspect as
  # "[...]" instead of coercing to strings/charlists.
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: inspect(v)

  ## -- Limits -------------------------------------------------------------------

  defp check_query_length(query) do
    # byte_size, not String.length: an invalid-UTF-8 query would raise
    # UnicodeConversionError instead of returning a limit error (fuzz fence).
    if byte_size(query) <= @max_query_length do
      :ok
    else
      {:error, {:limit, "query length exceeds #{@max_query_length}"}}
    end
  end

  defp max_stage_depth(stages) do
    stages
    |> Enum.map(fn
      {:where, pred} -> pred_depth(pred)
      _ -> 1
    end)
    |> Enum.max(fn -> 1 end)
  end

  defp pred_depth({op, l, r}) when op in [:and, :or], do: 1 + max(pred_depth(l), pred_depth(r))
  defp pred_depth(_), do: 1

  ## -- Parse entry ----------------------------------------------------------------

  defp parse(query) do
    format = fn
      {:error, {:syn, code, msg, pos}} -> {:error, {:parse, "#{code}: #{msg} (position #{pos})"}}
      {:error, msg} when is_binary(msg) -> {:error, {:parse, msg}}
      other -> other
    end

    case lex(query, 0, []) do
      {:ok, tokens} ->
        case parse_stages(tokens, []) do
          {:ok, stages} -> {:ok, stages}
          {:error, _} = err -> format.(err)
        end

      {:error, _} = err ->
        format.(err)
    end
  end

  defp syn(code, msg, pos), do: {:error, {:syn, code, msg, pos}}

  ## -- Lexer ----------------------------------------------------------------------
  # Tokens carry their byte offset for typed positional errors:
  #   {:word, w, pos} {:string, s, pos} {:lparen, "(", pos} {:rparen, ")", pos}
  #   {:comma, ",", pos} {:assign, "=", pos} {:op, "+", pos} (also - * /)

  @whitespace ~c' \t\r\n'
  # '.' stays a word byte so "1.5" and the `..` between-range word survive.
  @punct ~c'(),|+-*/='

  defp lex(<<>>, _pos, acc), do: {:ok, Enum.reverse(acc)}

  defp lex(<<c::utf8, rest::binary>>, pos, acc) when c in @whitespace, do: lex(rest, pos + 1, acc)

  defp lex(<<?(, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:lparen, "(", pos} | acc])
  defp lex(<<?), rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:rparen, ")", pos} | acc])
  defp lex(<<?,, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:comma, ",", pos} | acc])
  defp lex(<<?|, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:word, "|", pos} | acc])

  # "==" stays a single word token (comparison operator); a lone '=' assigns.
  defp lex(<<?=, ?=, rest::binary>>, pos, acc), do: lex(rest, pos + 2, [{:word, "==", pos} | acc])
  defp lex(<<?=, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:assign, "=", pos} | acc])

  defp lex(<<?+, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:op, "+", pos} | acc])
  defp lex(<<?-, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:op, "-", pos} | acc])
  defp lex(<<?*, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:op, "*", pos} | acc])
  defp lex(<<?/, rest::binary>>, pos, acc), do: lex(rest, pos + 1, [{:op, "/", pos} | acc])

  # String literals: single- or double-quoted (real Kusto/Cosmos accepts both).
  # Backslash escapes the next byte (\', \", \\), so quoted terminators can
  # appear inside a literal.
  defp lex(<<q, rest::binary>>, pos, acc) when q == ?' or q == ?" do
    case lex_string(rest, q, "") do
      {:ok, s, rest, consumed} ->
        lex(rest, pos + 1 + consumed, [{:string, s, pos} | acc])

      :error ->
        syn(@syn_string, "unterminated string literal", pos)
    end
  end

  defp lex(<<c::utf8, rest::binary>>, pos, acc) do
    {chars, rest} = take_word(rest, [c])
    word = List.to_string(chars)
    lex(rest, pos + byte_size(word) + 1, [{:word, word, pos} | acc])
  end

  # Catch-all byte clause: a byte that is not valid UTF-8 is treated as a word
  # byte instead of crashing the lexer with FunctionClauseError (fuzz fence).
  defp lex(<<c, rest::binary>>, pos, acc) when c not in @whitespace and c not in @punct do
    lex_word(rest, [c], pos, acc)
  end

  defp lex_word(<<>>, word_acc, pos, acc),
    do: lex(<<>>, pos, [{:word, word_bytes(word_acc), pos} | acc])

  defp lex_word(<<c, rest::binary>>, word_acc, pos, acc) when c in @whitespace or c in @punct,
    do: lex(<<c, rest::binary>>, pos, [{:word, word_bytes(word_acc), pos} | acc])

  defp lex_word(<<c, rest::binary>>, word_acc, pos, acc),
    do: lex_word(rest, [c | word_acc], pos, acc)

  defp word_bytes(chars), do: List.to_string(Enum.reverse(chars))

  defp take_word(<<c::utf8, rest::binary>>, acc) when c in @whitespace or c in @punct,
    do: {Enum.reverse(acc), <<c::utf8, rest::binary>>}

  defp take_word(<<c::utf8, rest::binary>>, acc), do: take_word(rest, [c | acc])

  # Invalid UTF-8 byte inside a word: consume as a raw byte (fuzz fence).
  defp take_word(<<c, rest::binary>>, acc), do: take_word(rest, [c | acc])

  defp take_word(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # Backslash escape: real Kusto consumes the backslash — \' -> ', \" -> ",
  # \\ -> \, \n -> newline, \t -> tab, \r -> CR. Unknown escapes keep the
  # escaped byte itself (backslash dropped), matching lenient Kusto behavior.
  # Returns {:ok, string, rest, consumed_byte_count} (closing quote included).
  defp lex_string(<<>>, _q, _acc), do: :error

  defp lex_string(<<?\\, ?n, rest::binary>>, q, acc),
    do: lex_string(rest, q, <<acc::binary, ?\n>>)

  defp lex_string(<<?\\, ?t, rest::binary>>, q, acc),
    do: lex_string(rest, q, <<acc::binary, ?\t>>)

  defp lex_string(<<?\\, ?r, rest::binary>>, q, acc),
    do: lex_string(rest, q, <<acc::binary, ?\r>>)

  defp lex_string(<<?\\, c, rest::binary>>, q, acc) when is_integer(c),
    do: lex_string(rest, q, <<acc::binary, c>>)

  defp lex_string(<<q, rest::binary>>, q, acc), do: {:ok, acc, rest, byte_size(acc) + 1}

  defp lex_string(<<c::utf8, rest::binary>>, q, acc),
    do: lex_string(rest, q, <<acc::binary, c::utf8>>)

  # Invalid UTF-8 byte inside a string literal: consume as a raw byte (fuzz fence).
  defp lex_string(<<c, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, c>>)

  ## -- Parser: tokens -> stage list -------------------------------------------------

  # A pipeline is zero or more stages, each introduced by `|`.
  defp parse_stages([], stages), do: {:ok, Enum.reverse(stages)}

  defp parse_stages([{:word, "|", p} | rest], stages), do: parse_stage(rest, stages, p)

  defp parse_stages([{:word, w, p} | _], _stages),
    do: syn(@syn_unexpected, "expected '|' before #{inspect(w)}", p)

  # Catch-all: stray string/comma/paren tokens at a stage boundary are a parse
  # error, never a FunctionClauseError crash (fuzz fence).
  defp parse_stages([bad | _], _stages),
    do: syn(@syn_unexpected, "unexpected token at pipeline boundary", token_pos(bad))

  defp parse_stage([{:word, "where", _} | rest], stages, _pipe_pos) do
    with {:ok, pred, rest} <- parse_expr(rest, 0) do
      parse_stages(rest, [{:where, pred} | stages])
    end
  end

  defp parse_stage([{:word, "take", p} | rest], stages, _pipe_pos) do
    case rest do
      [{:word, n, _} | rest] ->
        case Integer.parse(n) do
          {int, ""} when int >= 0 ->
            parse_stages(rest, [{:take, int} | stages])

          _ ->
            syn(@syn_operand, "take expects a non-negative integer, got #{inspect(n)}", p)
        end

      _ ->
        syn(@syn_operand, "take expects an integer", p)
    end
  end

  # order by / sort by (synonyms): `<kw> by C [asc|desc] [nulls first|last]`
  for kw <- ["order", "sort"] do
    defp parse_stage([{:word, unquote(kw), p} | rest], stages, _pipe_pos) do
      case rest do
        [{:word, "by", _}, {:word, col, _} | rest] ->
          {dir, rest} =
            case rest do
              [{:word, d, _} | r] ->
                case Map.fetch(@order_dirs, d) do
                  {:ok, dir} -> {dir, r}
                  :error -> {:asc, rest}
                end

              _ ->
                {:asc, rest}
            end

          nulls_res =
            case rest do
              [{:word, "nulls", _}, {:word, n, pn} | r] ->
                case Map.fetch(@nulls_pos, n) do
                  {:ok, nulls} -> {:cont, {nulls, r}}
                  :error -> {:err, syn(@syn_unexpected, "expected 'first' or 'last' after 'nulls'", pn)}
                end

              _ ->
                {:cont, {nil, rest}}
            end

          case nulls_res do
            {:cont, {nulls, rest}} ->
              parse_stages(rest, [{:order, col, dir, nulls} | stages])

            {:err, err} ->
              err
          end

        [{:word, "by", _} | _] ->
          syn(@syn_operand, "#{unquote(kw)} by expects a column", p)

        _ ->
          syn(@syn_operand, "#{unquote(kw)} expects 'by'", p)
      end
    end
  end

  defp parse_stage([{:word, "project", _} | rest], stages, _pipe_pos) do
    with {:ok, items, rest} <- parse_items(rest, false) do
      parse_stages(rest, [{:project, items} | stages])
    end
  end

  defp parse_stage([{:word, "extend", _} | rest], stages, _pipe_pos) do
    with {:ok, items, rest} <- parse_items(rest, true) do
      parse_stages(rest, [{:extend, items} | stages])
    end
  end

  defp parse_stage([{:word, "summarize", _} | rest], stages, _pipe_pos) do
    with {:ok, aggs, rest} <- parse_aggs(rest),
          {:ok, by_keys, rest} <- parse_by(rest) do
      case rest do
        # any leftover word that is not the stage-terminating pipe belongs to
        # no clause — fail-closed
        [{:word, w, p} | _] when w != "|" ->
          syn(@syn_unknown, "unknown token #{inspect(w)} in summarize", p)

        _ ->
          parse_stages(rest, [{:summarize, aggs, by_keys} | stages])
      end
    end
  end

  defp parse_stage([{:word, other, p} | _], _stages, _pipe_pos),
    do: syn(@syn_unknown, "unknown pipeline operator #{inspect(other)}", p)

  defp parse_stage([], _stages, pipe_pos),
    do: syn(@syn_unexpected, "expected pipeline keyword after '|'", pipe_pos)

  # Catch-all: any non-word token (rparen/comma/string) right after '|' is a
  # parse error, never a FunctionClauseError crash (random-fuzz fence, cycle 9).
  defp parse_stage([_bad | _], _stages, pipe_pos),
    do: syn(@syn_unexpected, "unexpected token after '|'", pipe_pos)

  # -- project/extend items: `Name = <scalar-expr>` or a bare column ------------

  defp parse_items([], _require_assign),
    do: syn(@syn_operand, "expected a column list", 0)

  defp parse_items(tokens, require_assign), do: items_loop(tokens, [], require_assign)

  defp items_loop([{:word, w, p} | rest], acc, require_assign) do
    case item_expr(w, rest, require_assign, p) do
      {:ok, item, rest} ->
        acc = [item | acc]

        case rest do
          [{:comma, ",", _} | r] -> items_loop(r, acc, require_assign)
          _ -> {:ok, Enum.reverse(acc), rest}
        end

      {:error, _} = err ->
        err
    end
  end

  defp items_loop([{_tok, val, p} | _], _acc, _require_assign),
    do: syn(@syn_operand, "expected a column name, got #{inspect(val)}", p)

  defp items_loop([], _acc, _require_assign),
    do: syn(@syn_operand, "dangling ',' in column list", 0)

  defp item_expr(w, [{:assign, "=", _} | rest], _require_assign, _p) do
    case parse_scalar(rest) do
      {:ok, expr, rest} -> {:ok, {w, expr}, rest}
      {:error, _} = err -> err
    end
  end

  defp item_expr(w, rest, false, _p), do: {:ok, {w, {:col, w}}, rest}

  defp item_expr(_w, _rest, true, p),
    do: syn(@syn_operand, "extend expects 'Name = <expression>'", p)

  # -- summarize aggregates: count() | sum(C) | avg(C) | min(C) | max(C) -------

  defp parse_aggs([{:word, "by", _} | _] = rest), do: {:ok, [], rest}

  defp parse_aggs(tokens), do: aggs_loop(tokens, [])

  defp aggs_loop([{:word, fun, p}, {:lparen, "(", _} | rest], acc) when fun in @aggregates do
    case rest do
      # count() — no argument
      [{:rparen, ")", _} | r] when fun == "count" ->
        comma_or_done({:count, "count_"}, r, acc)

      [{:word, col, _}, {:rparen, ")", _} | r] when fun != "count" ->
        comma_or_done({String.to_existing_atom(fun), "#{fun}_#{col}", col}, r, acc)

      _ ->
        if fun == "count" do
          syn(@syn_operand, "count() takes no arguments", p)
        else
          syn(@syn_operand, "#{fun}() expects a column name", p)
        end
    end
  end

  defp aggs_loop([{:word, fun, p}, {:lparen, "(", _} | _], _acc) when fun not in @aggregates,
    do:
      syn(
        @syn_unknown,
        "unknown aggregate function #{inspect(fun)} (supported: count, sum, avg, min, max)",
        p
      )

  defp aggs_loop([{:word, w, p} | _], _acc),
    do:
      syn(
        @syn_unexpected,
        "expected an aggregate like count() in summarize, got #{inspect(w)}",
        p
      )

  defp aggs_loop([{_tok, val, p} | _], _acc),
    do: syn(@syn_unexpected, "unexpected #{inspect(val)} in summarize", p)

  defp aggs_loop([], _acc), do: syn(@syn_operand, "summarize expects an aggregate", 0)

  defp comma_or_done(item, [{:comma, ",", _} | rest], acc),
    do: aggs_loop(rest, [item | acc])

  defp comma_or_done(item, rest, acc), do: {:ok, Enum.reverse([item | acc]), rest}

  # T-05 rider (v26.10.28): parse_by returns {:ok, keys, rest} | {:error,_} —
  # the old bare {cols, rest} tuple let a key_cols_loop error destructure AS
  # the by-list ({:error, _} matches {by_keys, rest}), crashing parse_stages
  # with FunctionClauseError instead of the typed SYN- error (latent hole,
  # exposed by bin()'s malformed-shape courts).
  defp parse_by([{:word, "by", _} | rest]) do
    case key_cols_loop(rest, []) do
      {:ok, cols, rest} -> {:ok, cols, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_by(rest), do: {:ok, [], rest}

  # T-05 increment 1 (v26.10.28): `by bin(Col, <timespan>|<number>)` —
  # bucket the group key. Step validates at parse time (typed SYN- error,
  # same fail-closed law as every other construct).
  defp key_cols_loop(
         [{:word, "bin", bp}, {:lparen, "(", _}, {:word, col, _}, {:comma, ",", _},
          {:word, step, sp} | rest],
         acc
       ) do
    case rest do
      [{:rparen, ")", _} | r] ->
        case bin_step(step) do
          {:ok, step_value} ->
            by_item_done({:bin, col, step_value}, r, acc)

          :error ->
            syn(@syn_unexpected,
              "invalid bin() step #{inspect(step)} (expected a timespan like 5m or a number)",
              sp
            )
        end

      _ ->
        syn(@syn_unexpected, "expected ')' to close bin(...)", bp)
    end
  end

  defp key_cols_loop([{:word, col, _} | rest], acc), do: by_item_done(col, rest, acc)

  defp by_item_done(item, [{:comma, ",", _} | r], acc), do: key_cols_loop(r, [item | acc])
  defp by_item_done(item, rest, acc), do: {:ok, Enum.reverse([item | acc]), rest}

  defp key_cols_loop([{_tok, val, p} | _], _acc),
    do: syn(@syn_unexpected, "expected a column name in by-list, got #{inspect(val)}", p)

  defp key_cols_loop([], _acc), do: syn(@syn_operand, "by expects at least one column", 0)

  # bin() step: a duration word ("5m") or a numeric word.
  defp bin_step(step) when is_binary(step) do
    case Integer.parse(step) do
      {n, ""} -> {:ok, {:num, n}}
      _ ->
        case Float.parse(step) do
          {f, ""} -> {:ok, {:num, f}}
          _ ->
            if Regex.match?(~r/^\d+(ms|s|m|h|d)$/, step) do
              {:ok, {:dur, duration_ms(step)}}
            else
              :error
            end
        end
    end
  end

  # Group-key value for one by-item; output column name for one by-item
  # (Kusto renders `by bin(TimeGenerated, 5m)` with the bare column name).
  defp by_key_value(row, {:bin, col, step}), do: bucket_value(Map.get(row, col), step)
  defp by_key_value(row, col) when is_binary(col), do: Map.get(row, col)

  defp by_key_name({:bin, col, _step}), do: col
  defp by_key_name(col) when is_binary(col), do: col

  # Datetimes (DateTime or ISO string, via to_datetime/1) bucket to the
  # bucket-START DateTime; numbers floor to the step multiple. Values that
  # are neither stay nil (grouped as nil, like a missing plain column).
  defp bucket_value(v, {:dur, step_ms}) do
    case to_datetime(v) do
      {:ok, dt} ->
        ms = DateTime.to_unix(dt, :millisecond)
        DateTime.from_unix!(div(ms, step_ms) * step_ms, :millisecond)

      :error ->
        nil
    end
  end

  defp bucket_value(v, {:num, step}) when is_number(v), do: Float.floor(v / step) * step
  defp bucket_value(_v, {:num, _step}), do: nil

  ## -- Scalar expression grammar ---------------------------------------------------

  # scalar := term (('+'|'-'|'*'|'/') term)*   with * / binding tighter
  # term   := number | "string" | column | ago(dur) | now() | datetime("...")
  #          | -number | '(' scalar ')'
  # Returns {:ok, ast, rest} | {:halt, ast, rest} | {:error, _}. :halt means
  # the next token terminates the expression (a clause keyword like `by`, `and`,
  # `nulls`, or a `)` inside a between range) and is only legal at term
  # boundaries the caller accepts; anything else is a typed SYN- error.

  defp parse_scalar(tokens), do: scalar_loop_from(tokens)

  defp scalar_loop_from(tokens) do
    case parse_term(tokens) do
      {:ok, lhs, rest} -> scalar_loop(lhs, rest, 0)
      # end-of-input inside an expression: typed operand error, not an atom leak
      {:error, :term_end} -> syn(@syn_operand, "expected a value in expression", 0)
      {:error, _} = err -> err
    end
  end

  @scalar_bp %{:+ => 1, :- => 1, :* => 2, :/ => 2}

  defp scalar_loop(lhs, [{:op, sym, pos} | rest], min_bp) do
    op = String.to_existing_atom(sym)

    if Map.fetch!(@scalar_bp, op) >= min_bp do
      case parse_term(rest) do
        {:ok, rhs, rest} -> scalar_loop({:arith, op, lhs, rhs}, rest, min_bp)
        {:halt, rhs, rest} -> scalar_loop({:arith, op, lhs, rhs}, rest, min_bp)
        {:error, _} = err -> err
      end
    else
      {:ok, lhs, [{:op, sym, pos} | rest]}
    end
  end

  defp scalar_loop(lhs, rest, _min_bp), do: {:ok, lhs, rest}

  @clause_words ["by", "nulls", "asc", "desc" | @bool_words]

  defp parse_term([{:word, w, p} | rest]) do
    cond do
      w in @clause_words ->
        # clause keyword: belongs to the enclosing stage, ends this expression
        {:halt, {:col, w}, [{:word, w, p} | rest]}

      true ->
        case rest do
          [{:lparen, "(", _} | r] -> parse_call(w, r, p)
          # a numeric word IS a literal (30, 2.5); everything else is a column
          _ ->
            case number(w) do
              {:ok, n} -> {:ok, {:lit, n}, rest}
              :error -> {:ok, {:col, w}, rest}
            end
        end
    end
  end

  defp parse_term([{:lparen, "(", p} | rest]) do
    with {:ok, expr, rest} <- parse_scalar(rest) do
      case rest do
        [{:rparen, ")", _} | r] -> {:ok, expr, r}
        [{:word, w, p2} | _] -> syn(@syn_unexpected, "expected ')' before #{inspect(w)}", p2)
        _ -> syn(@syn_unexpected, "expected ')'", p)
      end
    end
  end

  defp parse_term([{:string, s, _} | rest]), do: {:ok, {:lit, s}, rest}

  defp parse_term([{:op, "-", p}, {:word, n, _} | rest]) do
    case number(n) do
      {:ok, num} -> {:ok, {:lit, -num}, rest}
      :error -> syn(@syn_operand, "expected a number after unary '-'", p)
    end
  end

  defp parse_term([{:op, sym, p} | _]),
    do: syn(@syn_operand, "unexpected '#{sym}' in expression", p)

  defp parse_term([{:assign, "=", p} | _]),
    do: syn(@syn_unexpected, "unexpected '=' in expression", p)

  defp parse_term([{_tok, val, p} | _]),
    do: syn(@syn_unexpected, "unexpected #{inspect(val)} in expression", p)

  defp parse_term([]), do: {:error, :term_end}

  defp parse_call("ago", [{:word, dur, p}, {:rparen, ")", _} | rest], _wp) do
    if Regex.match?(~r/^\d+(ms|s|m|h|d)$/, dur) do
      {:ok, {:f, "ago", dur}, rest}
    else
      syn(@syn_operand, "ago() expects a duration like 1h, 30m, 7d, 10s, 500ms", p)
    end
  end

  # duration present but closing paren missing -> still a duration error
  defp parse_call("ago", [{:word, dur, p} | _], _wp),
    do: syn(@syn_operand, "ago() expects a duration like 1h, 30m, 7d, 10s, 500ms, got #{inspect(dur)}", p)

  defp parse_call("ago", [{_tok, val, p} | _], _wp),
    do: syn(@syn_operand, "ago() expects a duration literal, got #{inspect(val)}", p)

  defp parse_call("ago", [], p),
    do: syn(@syn_operand, "ago() expects a duration literal", p)

  defp parse_call("now", [{:rparen, ")", _} | rest], _wp), do: {:ok, {:f, "now", []}, rest}

  defp parse_call("now", [{_tok, val, p} | _], _wp),
    do: syn(@syn_operand, "now() takes no arguments, got #{inspect(val)}", p)

  defp parse_call("now", [], p), do: syn(@syn_operand, "now() takes no arguments", p)

  defp parse_call("datetime", [{:string, iso, p}, {:rparen, ")", _} | rest], _wp) do
    if match?({:ok, _, _}, DateTime.from_iso8601(iso)) do
      {:ok, {:f, "datetime", [iso]}, rest}
    else
      syn(@syn_operand, "datetime() expects a valid ISO8601 string", p)
    end
  end

  defp parse_call("datetime", [{:string, iso, p} | _], _wp),
    do: syn(@syn_operand, "expected ')' after datetime(#{inspect(iso)})", p)

  defp parse_call("datetime", [{_tok, val, p} | _], _wp),
    do: syn(@syn_operand, "datetime() expects a quoted ISO8601 string, got #{inspect(val)}", p)

  # Fail-closed on unknown functions (real KQL: unknown function is a parse error).
  defp parse_call(other, _rest, p),
    do: syn(@syn_unknown, "unknown function #{inspect(other)}", p)

  ## -- Predicate grammar -------------------------------------------------------

  # Precedence climbing: or (bp 1) < and (bp 2).
  defp parse_expr(tokens, min_bp) do
    with {:ok, lhs, rest} <- parse_operand(tokens) do
      parse_loop(lhs, rest, min_bp)
    end
  end

  defp parse_operand([{:lparen, "(", p} | rest]) do
    with {:ok, expr, rest} <- parse_expr(rest, 0) do
      case rest do
        [{:rparen, ")", _} | rest] -> {:ok, expr, rest}
        [{:word, w, p2} | _] -> syn(@syn_unexpected, "expected ')' before #{inspect(w)}", p2)
        _ -> syn(@syn_unexpected, "expected ')'", p)
      end
    end
  end

  defp parse_operand([{:word, col, p} | rest]) do
    parse_comparison(col, rest, p)
  end

  defp parse_operand([{_tok, val, p} | _]),
    do: syn(@syn_unexpected, "unexpected #{inspect(val)} in predicate", p)

  defp parse_operand([]), do: syn(@syn_operand, "unexpected end of predicate", 0)

  defp parse_comparison(col, [{:word, "between", _} | rest], _cp) do
    case rest do
      [{:lparen, "(", _} | r1] ->
        with {:ok, lo, r2} <- parse_scalar(r1),
             {:ok, hi, r4} <- expect_dotdot_then_scalar(r2) do
          case r4 do
            [{:rparen, ")", _} | r5] -> {:ok, {:between, col, lo, hi}, r5}
            [{:word, w, p} | _] -> syn(@syn_unexpected, "expected ')' before #{inspect(w)}", p)
            _ -> syn(@syn_unexpected, "expected ')' after between range", 0)
          end
        end

      [{_tok, val, p} | _] ->
        syn(@syn_operand, "between expects '(', got #{inspect(val)}", p)

      [] ->
        syn(@syn_operand, "between expects '('", 0)
    end
  end

  defp parse_comparison(col, [{:word, op, p} | rest], _cp) do
    case Map.fetch(@comparison_atoms, op) do
      {:ok, op_atom} ->
        case parse_scalar(rest) do
          {:ok, rhs, rest} -> {:ok, {op_atom, col, rhs}, rest}
          {:halt, rhs, rest} -> {:ok, {op_atom, col, rhs}, rest}
          {:error, _} = err -> err
        end

      :error ->
        syn(@syn_unknown, "unknown comparison operator #{inspect(op)}", p)
    end
  end

  defp parse_comparison(_col, [], cp),
    do: syn(@syn_operand, "expected comparison operator after column", cp)

  # Catch-all: a non-word token (paren/string/comma) after a column is a parse
  # error, never a FunctionClauseError crash (fuzz fence, cycle 10).
  defp parse_comparison(_col, [_bad | _], cp),
    do: syn(@syn_operand, "expected comparison operator after column", cp)

  defp expect_dotdot_then_scalar([{:word, "..", _} | rest]) do
    case parse_scalar(rest) do
      {:ok, expr, rest} -> {:ok, expr, rest}
      {:halt, expr, rest} -> {:ok, expr, rest}
      {:error, _} = err -> err
    end
  end

  defp expect_dotdot_then_scalar([{_tok, val, p} | _]),
    do: syn(@syn_operand, "expected '..' in between range, got #{inspect(val)}", p)

  defp expect_dotdot_then_scalar([]),
    do: syn(@syn_operand, "expected '..' in between range", 0)

  defp parse_loop(lhs, [{:word, op, pos} | rest], min_bp) when op in ["and", "or"] do
    op_atom = Map.fetch!(@bool_ops, op)

    if Map.fetch!(@bp, op_atom) >= min_bp do
      with {:ok, rhs, rest} <- parse_expr(rest, Map.fetch!(@bp, op_atom) + 1) do
        parse_loop({op_atom, lhs, rhs}, rest, min_bp)
      end
    else
      {:ok, lhs, [{:word, op, pos} | rest]}
    end
  end

  defp parse_loop(lhs, rest, _min_bp), do: {:ok, lhs, rest}

  @spec token_pos(tuple()) :: non_neg_integer()
  defp token_pos(tok) when is_tuple(tok), do: elem(tok, tuple_size(tok) - 1)
end
