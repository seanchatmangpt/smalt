defmodule Smalt.SqlIngest do
  @moduledoc """
  Pure-Elixir postgres-dump (pg_dump text format) COPY-block parser and
  CSV converter — the documented fallback when the duckdb postgres
  scanner cannot read a dump file directly (duckdb v1.4.1's postgres
  extension only ATTACHes a *live* postgres server; there is no
  `read_pg_copy`-style table function in this build).

  Scope: the COPY format ("the dominant dump format"). Only
  `COPY <table> [(cols)] FROM stdin;` ... `\\.` blocks are extracted;
  the surrounding DDL is parsed for nothing beyond namespacing and is
  never executed. Row data is treated as opaque text and unescaped with
  the postgres COPY text-format rules (`\\N`, `\\t`, `\\n`, `\\r`, `\\\\`,
  `\\b`, `\\f`, `\\v`).

  Failure mode is fail-closed and typed:

    * a COPY header whose table name fails the identifier guard
      (`^[a-zA-Z_][a-zA-Z0-9_]*$` after optional `schema.` qualification)
      yields `{:error, {:injection_token, name}}` — a table name carrying
      SQL metacharacters (`;`, `--`, quotes, whitespace) is refused before
      any row is consumed, and nothing from that block is ingested.
    * a COPY block without a terminator is `{:error, :unterminated_copy_block}`.
    * ANY `COPY`-prefixed line that is not the exact well-formed
      `COPY <ident>[.<ident>] [(cols)] FROM stdin;` shape is refused
      (`{:error, {:injection_token, <first-token-after-COPY>}}`) — a
      malformed header is never silently skipped; skipping is the vacuity.

  ## CSV encoding contract (GLD-5FIX, lossless by construction)

  `to_csv/2` emits a **lossless, typed-NULL** encoding:

    * NULL (`\\N` in the COPY block) → bare unquoted `\\N` field.
    * Empty string → quoted `""` field. With duckdb's
      `allow_quoted_nulls = false`, quoted fields are never matched
      against `nullstr`, so NULL, empty string, and a literal `\N`
      VALUE are three distinct wire tokens that all survive a real
      `read_csv` load (pinned by the GLD-5FIX round-trip court).
    * A literal `\\N` *value* (the two bytes backslash-N, e.g. produced by
      the COPY escape `\\\\N`) is quoted (`"\\N"`), so it can never alias
      the NULL sentinel. This is the only value force-quoted beyond the
      RFC4180 minimum.
    * All other quoting is RFC4180 minimal (quote iff the field contains
      `,`, `"`, newline, or CR).

  Consumers must load with
  `read_csv(..., nullstr = '\N', allow_quoted_nulls = false)` (the
  GLD-5FIX round-trip court pins this exact load). The SQLD-2 corpus
  contains no NULLs, so its existing `read_csv` legs are unaffected;
  `read_csv_auto` legs in the SQLD-8 perf baseline ride the same
  NULL-free corpus.

  ## Formula-injection neutralization (GLD-5 F3)

  Spreadsheet-class tools execute cells whose text begins with `=`, `+`,
  `-`, or `@` as formulas. `to_csv/2` neutralizes such fields with the
  spreadsheet-standard `'` prefix — **except** for fields that are valid
  numeric literals (optional sign, digits, optional fraction/exponent):
  a spreadsheet evaluates those as numbers, not formulas, so prefixing
  them would corrupt round-trip fidelity (`-0.0`, `3.10`, `1e-3` pass
  through byte-exact; `=cmd|'/c no'!A1`, `+1+1`, `-1+1`, `@SUM(1)` are
  neutralized to `'=...`). The neutralized form is the *safe transport*
  form: the payload is inert in any spreadsheet-class consumer. This is
  the OWASP CSV-injection cheat-sheet mitigation.

  No dependency on Jason or any other hex package: stdlib only, so the
  module compiles standalone under plain `elixir` for court runs.
  """

  @identifier_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @copy_regex ~r/^COPY\s+(?<target>[^\s(]+)\s*(?<cols>\([^)]*\))?\s+FROM\s+stdin;\s*$/i

  @escapes %{
    "b" => <<8>>,
    "f" => <<12>>,
    "n" => "\n",
    "r" => "\r",
    "t" => "\t",
    "v" => <<11>>,
    "\\" => "\\"
  }

  # GLD-5 F3: numeric-literal exemption for formula neutralization — a
  # leading-sign numeric is evaluated as a NUMBER by spreadsheets, never
  # a formula, so prefixing it would break value-exact round-trips.
  @numeric_regex ~r/^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/

  @doc """
  Parse a pg_dump text file into
  `%{"table" => %{columns: [String.t()], rows: [[String.t() | :null]]}}`
  (values kept as raw binaries after COPY-text unescaping; typing happens
  at the duckdb load step). Returns `{:ok, tables}` or `{:error, term()}`.

  Tables whose name fails the identifier guard are refused whole
  (`{:error, {:injection_token, name}}`), before any of their rows are
  read; the refusal aborts the whole parse (fail-closed, no partial
  ingestion of a poisoned dump).
  """
  @spec parse_dump(binary()) ::
          {:ok, %{optional(String.t()) => %{columns: [String.t()], rows: [[String.t() | :null]]}}}
          | {:error, term()}

  def parse_dump(text) when is_binary(text) do
    lines = String.split(text, ["\r\n", "\n"])

    case scan(lines, [], nil, %{}) do
      {:error, _} = err -> err
      tables -> {:ok, tables}
    end
  end

  @doc """
  Identifier guard: only bare SQL identifiers (`^[a-zA-Z_][a-zA-Z0-9_]*$`,
  optionally `schema.`-qualified) are admitted. Anything carrying
  statement separators, comment markers, quotes, or whitespace is an
  injection token.
  """
  @spec valid_table_name?(String.t()) :: boolean()
  def valid_table_name?(name) when is_binary(name) do
    name
    |> String.split(".", parts: 2)
    |> Enum.all?(&Regex.match?(@identifier_regex, &1))
  end

  @doc """
  Unescape one COPY text-format field (`\\N` → `:null`, `\\t` handled by
  the splitter; `\\\\`, `\\n`, `\\r`, `\\b`, `\\f`, `\\v` decoded).
  """
  @spec unescape_field(String.t()) :: String.t() | :null
  def unescape_field("\\N"), do: :null

  def unescape_field(field) when is_binary(field) do
    case String.contains?(field, "\\") do
      false -> field
      true -> do_unescape(field, [])
    end
  end

  @doc """
  Serialize rows to lossless CSV (module doc: `\\N`-nulls as bare `\\N`,
  empty strings as `""`, literal `\\N` values quoted, formula
  neutralization on leading `=+-@` with a numeric-literal exemption).
  Returns iodata.
  """
  @spec to_csv([String.t()], [[String.t() | :null]]) :: iodata()
  def to_csv(columns, rows) do
    header = Enum.join(columns, ",")
    body = Enum.map(rows, fn row -> Enum.map_join(row, ",", &csv_field/1) end)
    Enum.intersperse([header | body], ?\n)
  end

  # — internal —

  defp scan([], [], _current, acc), do: acc
  defp scan([], _rest, {:copy, _target, _cols}, _acc), do: {:error, :unterminated_copy_block}

  defp scan([line | rest], buffered, current, acc) do
    cond do
      current == nil and Regex.match?(~r/^(\s*)COPY\s/i, line) ->
        case Regex.named_captures(@copy_regex, line) do
          nil ->
            # Fail-closed: a COPY header that is not the exact well-formed
            # `COPY <ident>[.<ident>] (cols) FROM stdin;` shape is refused
            # whole. A poisoned header (injection-token table name) does not
            # match the strict shape and must never be silently skipped —
            # skipping IS the vacuity. The refused name is the first token
            # after COPY (the candidate table target).
            first_token =
              line
              |> String.trim_leading()
              |> String.split(~r/\s+/, parts: 3)
              |> Enum.at(1)
              |> String.split(".", parts: 2)
              |> List.last()

            {:error, {:injection_token, first_token}}

          caps ->
            target = String.trim(caps["target"])

            case valid_table_name?(target) do
              false ->
                {:error, {:injection_token, target}}

              true ->
                bare = target |> String.split(".", parts: 2) |> List.last()
                scan(rest, [], {:copy, bare, parse_columns(caps["cols"])}, acc)
            end
        end

      match?({:copy, _, _}, current) and line == "\\." ->
        {:copy, target, cols} = current
        rows = Enum.reverse(buffered) |> Enum.map(&split_copy_line/1)
        scan(rest, [], nil, Map.put(acc, target, %{columns: cols, rows: rows}))

      match?({:copy, _, _}, current) ->
        scan(rest, [line | buffered], current, acc)

      true ->
        scan(rest, buffered, nil, acc)
    end
  end

  defp parse_columns(nil), do: []
  defp parse_columns(cols) do
    cols
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn c -> String.replace(c, "\"", "") end)
  end

  defp split_copy_line(line), do: line |> String.split("\t") |> Enum.map(&unescape_field/1)

  defp do_unescape(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp do_unescape(<<?\\, c, rest::binary>>, acc) do
    case Map.fetch(@escapes, <<c>>) do
      {:ok, rep} -> do_unescape(rest, [rep | acc])
      :error -> do_unescape(rest, [<<c>> | acc])
    end
  end

  defp do_unescape(<<c, rest::binary>>, acc), do: do_unescape(rest, [<<c>> | acc])

  # — CSV field encoding (GLD-5FIX contract) —

  defp csv_field(:null), do: "\\N"

  defp csv_field(value) when is_binary(value) do
    value |> neutralize_formula() |> IO.iodata_to_binary() |> quote_field()
  end

  defp csv_field(other), do: to_string(other)

  # F3: spreadsheet-standard `'` prefix for formula-hostile leading chars,
  # with the numeric-literal exemption (numbers are inert in spreadsheets;
  # prefixing them would break value-exact round-trips).
  defp neutralize_formula(<<c, _::binary>> = value) when c in [?=, ?+, ?@] do
    neutralize_numeric_or_prefix(value)
  end

  defp neutralize_formula(<<?-, _::binary>> = value) do
    # `-` leads both numbers (`-0.0`) and formulas (`-1+1`): only the
    # numeric-exemption check decides.
    neutralize_numeric_or_prefix(value)
  end

  defp neutralize_formula(value), do: value

  defp neutralize_numeric_or_prefix(value) do
    case Regex.match?(@numeric_regex, value) do
      true -> value
      false -> [?', value]
    end
  end

  defp quote_field(value) do
    needs_quote =
      value == "" or value == "\\N" or String.contains?(value, [",", "\"", "\n", "\r"])

    cond do
      not needs_quote -> value
      true -> "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    end
  end
end
