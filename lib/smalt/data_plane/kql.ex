defmodule Smalt.DataPlane.KQL do
  @moduledoc """
  Deterministic KQL-subset filter engine for Sentinel/ResourceGraph query strings.

  Parses pipelines of:

      | where <pred> | take N | order by <col> asc|desc | project col1, col2

  into an AST (no eval, no injection surface) and executes it over a list of
  row maps with string column keys (e.g. the Sentinel base columns `ledgerId`,
  `tenantId`, `subjectSha256`, `eventId`, `sha256Hash`).

  Pure: `run/2` returns `{:ok, rows'}` or `{:error, {:parse | :limit, msg}}`.
  """

  @max_query_length 2_000
  @max_ast_depth 20
  @max_take 1_000

  @type row :: %{optional(String.t()) => term()}
  @type run_err :: {:error, {:parse | :limit, String.t()}}

  @order_dirs %{"asc" => :asc, "desc" => :desc}
  @comparison_atoms %{
    "==" => :eq,
    "!=" => :neq,
    "contains" => :contains,
    "startswith" => :startswith,
    ">" => :gt,
    "<" => :lt,
    ">=" => :gte,
    "<=" => :lte
  }
  @bool_ops %{"and" => :and, "or" => :or}
  @bp %{or: 1, and: 2}

  @spec run([row], String.t()) :: {:ok, [row]} | run_err
  def run(rows, query) when is_list(rows) and is_binary(query) do
    with :ok <- check_query_length(query),
         {:ok, stages} <- parse(query) do
      case max_stage_depth(stages) do
        depth when depth <= @max_ast_depth -> execute(stages, rows)
        _ -> {:error, {:limit, "AST depth exceeds #{@max_ast_depth}"}}
      end
    end
  end

  def run(_rows, _query), do: {:error, {:parse, "query must be a string, rows a list"}}

  ## -- Pipeline execution ----------------------------------------------------

  defp execute(stages, rows) do
    Enum.reduce_while(stages, {:ok, rows}, fn
      stage, {:ok, acc} -> {:cont, apply_stage(stage, acc)}
      _stage, {:error, _} = err -> {:halt, err}
    end)
  end

  defp apply_stage({:take, n}, rows) do
    if n <= @max_take do
      {:ok, Enum.take(rows, n)}
    else
      {:error, {:limit, "take #{n} exceeds cap of #{@max_take}"}}
    end
  end

  defp apply_stage({:where, pred}, rows), do: {:ok, Enum.filter(rows, &eval(pred, &1))}

  defp apply_stage({:order, col, dir}, rows),
    do: {:ok, Enum.sort_by(rows, &sort_key(&1, col), dir)}

  defp apply_stage({:project, cols}, rows), do: {:ok, Enum.map(rows, &Map.take(&1, cols))}

  # Missing columns sort as the empty string; Erlang's sort is stable, so equal
  # keys keep input order — deterministic output.
  defp sort_key(row, col) do
    case Map.get(row, col) do
      nil -> ""
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  ## -- Predicates -------------------------------------------------------------

  defp eval({:and, l, r}, row), do: eval(l, row) and eval(r, row)
  defp eval({:or, l, r}, row), do: eval(l, row) or eval(r, row)

  defp eval({:eq, col, lit}, row), do: Map.get(row, col) == lit
  defp eval({:neq, col, lit}, row), do: Map.get(row, col) != lit

  defp eval({op, col, lit}, row) when op in [:contains, :startswith] do
    case Map.get(row, col) do
      nil ->
        false

      v ->
        v = to_str(v)
        lit = to_str(lit)

        if op == :contains do
          String.contains?(v, lit)
        else
          String.starts_with?(v, lit)
        end
    end
  end

  defp eval({op, col, num}, row) when op in [:gt, :lt, :gte, :lte] do
    case number(Map.get(row, col)) do
      {:ok, n} -> apply_cmp(op, n, num)
      :error -> false
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

  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)

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
    case lex(query, []) do
      {:ok, tokens} ->
        case parse_stages(tokens, []) do
          {:ok, stages} -> {:ok, stages}
          {:error, msg} -> {:error, {:parse, msg}}
        end

      {:error, msg} ->
        {:error, {:parse, msg}}
    end
  end

  ## -- Lexer ----------------------------------------------------------------------

  @whitespace ~c' \t\r\n'
  @punct ~c'(),|'

  defp lex(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp lex(<<c::utf8, rest::binary>>, acc) when c in @whitespace, do: lex(rest, acc)

  defp lex(<<?(, rest::binary>>, acc), do: lex(rest, [{:lparen, "("} | acc])
  defp lex(<<?), rest::binary>>, acc), do: lex(rest, [{:rparen, ")"} | acc])
  defp lex(<<?,, rest::binary>>, acc), do: lex(rest, [{:comma, ","} | acc])
  defp lex(<<?|, rest::binary>>, acc), do: lex(rest, [{:word, "|"} | acc])

  # String literals: single- or double-quoted (real Kusto/Cosmos accepts both).
  # Backslash escapes the next byte (\', \", \\), so quoted terminators can
  # appear inside a literal.
  defp lex(<<q, rest::binary>>, acc) when q == ?' or q == ?" do
    case lex_string(rest, q, "") do
      {:ok, s, rest} -> lex(rest, [{:string, s} | acc])
      :error -> {:error, "unterminated string literal"}
    end
  end

  defp lex(<<c::utf8, rest::binary>>, acc) do
    {word, rest} = take_word(rest, [c])
    lex(rest, [{:word, List.to_string(word)} | acc])
  end

  # Catch-all byte clause: a byte that is not valid UTF-8 is treated as a word
  # byte instead of crashing the lexer with FunctionClauseError (fuzz fence).
  defp lex(<<c, rest::binary>>, acc) when c not in @whitespace and c not in @punct do
    lex_word(rest, [c], acc)
  end

  defp lex_word(<<>>, word_acc, acc), do: lex(<<>>, [{:word, word_bytes(word_acc)} | acc])

  defp lex_word(<<c, rest::binary>>, word_acc, acc) when c in @whitespace or c in @punct,
    do: lex(<<c, rest::binary>>, [{:word, word_bytes(word_acc)} | acc])

  defp lex_word(<<c, rest::binary>>, word_acc, acc), do: lex_word(rest, [c | word_acc], acc)

  defp word_bytes(chars), do: List.to_string(Enum.reverse(chars))

  defp take_word(<<c::utf8, rest::binary>>, acc) when c in @whitespace or c in @punct,
    do: {Enum.reverse(acc), <<c::utf8, rest::binary>>}

  defp take_word(<<c::utf8, rest::binary>>, acc), do: take_word(rest, [c | acc])

  # Invalid UTF-8 byte inside a word: consume as a raw byte (fuzz fence).
  defp take_word(<<c, rest::binary>>, acc), do: take_word(rest, [c | acc])

  defp take_word(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  # Minimal unblock fix (store+graphlaw lane, compile-freeze SLA): the caller
  # lex/2 invokes lex_string/3 with the opening quote byte `q`; define the
  # quote-aware 3-arg clauses (backslash escapes the next byte, matching the
  # comment on the lex/2 clause).
  defp lex_string(<<>>, _q, _acc), do: :error

  # Backslash escape: real Kusto consumes the backslash — \' -> ', \" -> ",
  # \\ -> \, \n -> newline, \t -> tab, \r -> CR. Unknown escapes keep the
  # escaped byte itself (backslash dropped), matching lenient Kusto behavior.
  defp lex_string(<<?\\, ?n, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, ?\n>>)
  defp lex_string(<<?\\, ?t, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, ?\t>>)
  defp lex_string(<<?\\, ?r, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, ?\r>>)

  defp lex_string(<<?\\, c, rest::binary>>, q, acc) when is_integer(c),
    do: lex_string(rest, q, <<acc::binary, c>>)

  defp lex_string(<<q, rest::binary>>, q, acc), do: {:ok, acc, rest}

  defp lex_string(<<c::utf8, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, c::utf8>>)

  # Invalid UTF-8 byte inside a string literal: consume as a raw byte (fuzz fence).
  defp lex_string(<<c, rest::binary>>, q, acc), do: lex_string(rest, q, <<acc::binary, c>>)

  ## -- Parser: tokens -> stage list -------------------------------------------------

  # A pipeline is zero or more stages, each introduced by `|`.
  defp parse_stages([], stages), do: {:ok, Enum.reverse(stages)}

  defp parse_stages([{:word, "|"} | rest], stages), do: parse_stage(rest, stages)

  defp parse_stages([{:word, w} | _], _stages),
    do: {:error, "expected '|' before #{inspect(w)}"}

  # Catch-all: stray string/comma/paren tokens at a stage boundary are a parse
  # error, never a FunctionClauseError crash (fuzz fence).
  defp parse_stages([_bad | _], _stages),
    do: {:error, "unexpected token at pipeline boundary"}

  defp parse_stage([{:word, "where"} | rest], stages) do
    with {:ok, pred, rest} <- parse_expr(rest, 0) do
      parse_stages(rest, [{:where, pred} | stages])
    end
  end

  defp parse_stage([{:word, "take"} | rest], stages) do
    case rest do
      [{:word, n} | rest] ->
        case Integer.parse(n) do
          {int, ""} when int >= 0 ->
            parse_stages(rest, [{:take, int} | stages])

          _ ->
            {:error, "take expects a non-negative integer, got #{inspect(n)}"}
        end

      [] ->
        {:error, "take expects an integer"}

      # Catch-all: any non-word token after 'take' is a parse error (fuzz fence).
      _ ->
        {:error, "take expects an integer"}
    end
  end

  defp parse_stage([{:word, "order"} | rest], stages) do
    case rest do
      [{:word, "by"}, {:word, col} | rest] ->
        {dir, rest} =
          case rest do
            [{:word, d} | r] ->
              case Map.fetch(@order_dirs, d) do
                {:ok, dir} -> {dir, r}
                :error -> {:asc, rest}
              end

            _ ->
              {:asc, rest}
          end

        parse_stages(rest, [{:order, col, dir} | stages])

      [{:word, "by"} | _] ->
        {:error, "order by expects a column"}

      _ ->
        {:error, "order expects 'by'"}
    end
  end

  defp parse_stage([{:word, "project"} | rest], stages) do
    case parse_cols(rest, []) do
      {:error, msg} -> {:error, msg}
      {[], _rest} -> {:error, "project expects at least one column"}
      {cols, rest} -> parse_stages(rest, [{:project, cols} | stages])
    end
  end

  defp parse_stage([{:word, other} | _], _stages),
    do: {:error, "unknown pipeline keyword #{inspect(other)}"}

  defp parse_stage([], _stages), do: {:error, "expected pipeline keyword after '|'"}

  # Catch-all: any non-word token (rparen/comma/string) right after '|' is a
  # parse error, never a FunctionClauseError crash (random-fuzz fence, cycle 9).
  defp parse_stage([_bad | _], _stages), do: {:error, "unexpected token after '|'"}

  defp parse_cols([{:word, col} | rest], acc),
    do: parse_cols_skip_comma(rest, [col | acc])

  defp parse_cols(_rest, _acc), do: {:error, "project expects a column list"}

  defp parse_cols_skip_comma([{:comma, ","}, {:word, col} | rest], acc),
    do: parse_cols_skip_comma(rest, [col | acc])

  defp parse_cols_skip_comma(rest, acc), do: {Enum.reverse(acc), rest}

  # Expression grammar, precedence climbing: or (bp 1) < and (bp 2).
  defp parse_expr(tokens, min_bp) do
    with {:ok, lhs, rest} <- parse_operand(tokens) do
      parse_loop(lhs, rest, min_bp)
    end
  end

  defp parse_operand([{:lparen, "("} | rest]) do
    with {:ok, expr, rest} <- parse_expr(rest, 0) do
      case rest do
        [{:rparen, ")"} | rest] -> {:ok, expr, rest}
        _ -> {:error, "expected ')'"}
      end
    end
  end

  defp parse_operand([{:word, col} | rest]) do
    parse_comparison(col, rest)
  end

  defp parse_operand([{tok, val} | _]), do: {:error, "unexpected #{tok} #{inspect(val)} in predicate"}
  defp parse_operand([]), do: {:error, "unexpected end of predicate"}

  defp parse_comparison(col, [{:word, op} | rest]) do
    case Map.fetch(@comparison_atoms, op) do
      {:ok, op_atom} ->
        case rest do
          [{:string, lit} | rest] ->
            {:ok, {op_atom, col, lit}, rest}

          [{:word, num} | rest] ->
            case parse_number(num) do
              {:ok, n} -> {:ok, {op_atom, col, n}, rest}
              :error -> {:error, "expected number after #{op}, got #{inspect(num)}"}
            end

          _ ->
            {:error, "expected literal after #{op}"}
        end

      :error ->
        {:error, "unknown comparison operator #{inspect(op)}"}
    end
  end

  defp parse_comparison(_col, []), do: {:error, "expected comparison operator after column"}

  # Catch-all: a non-word token (paren/string/comma) after a column is a parse
  # error, never a FunctionClauseError crash (fuzz fence, cycle 10).
  defp parse_comparison(_col, [_bad | _]),
    do: {:error, "expected comparison operator after column"}

  defp parse_number(bin) do
    case Integer.parse(bin) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(bin) do
          {f, ""} -> {:ok, f}
          _ -> :error
        end
    end
  end

  defp parse_loop(lhs, [{:word, op} | rest], min_bp) when op in ["and", "or"] do
    op_atom = Map.fetch!(@bool_ops, op)

    if Map.fetch!(@bp, op_atom) >= min_bp do
      with {:ok, rhs, rest} <- parse_expr(rest, Map.fetch!(@bp, op_atom) + 1) do
        parse_loop({op_atom, lhs, rhs}, rest, min_bp)
      end
    else
      {:ok, lhs, [{:word, op} | rest]}
    end
  end

  defp parse_loop(lhs, rest, _min_bp), do: {:ok, lhs, rest}
end
