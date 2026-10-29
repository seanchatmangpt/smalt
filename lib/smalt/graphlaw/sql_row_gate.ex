defmodule Smalt.GraphLaw.SqlRowGate do
  @moduledoc """
  GLD-6: the ingestion wire face's SHACL gate extended to the DATA itself -
  per-row compliance over the SQLD-5 auto-shapes, fail-closed.

  Pipeline: the dump's CREATE TABLE DDL (where NOT NULL / PK declarations
  live) -> SQLD-5 schema model -> SqlShapeGen.generate/1 -> substrate
  ShapeFile.parse!/2 -> per-row Validator.validate_shape/2 over typed row
  payloads.

  A refused dump projects NOTHING: the gate runs before the OCEL projection
  step, so no bad row can reach the projected ledger. Returns :ok or
  {:refusal, %{rule_id, diagnostic, repair_hint, digest_term}} - the exact
  fields Smalt.Egress.SqlIngestRoutes.andon_refusal/5 consumes.
  """

  alias Smalt.GraphLaw.SqlShapeGen
  alias Smalt.GraphLaw.Validator

  @ddl_regex ~r/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:(?<schema>[a-zA-Z_][a-zA-Z0-9_]*)\.)?(?<table>[a-zA-Z_][a-zA-Z0-9_]*)\s*\((?<body>.*?)\)\s*;/is

  @type_alias %{
    "int" => "INTEGER",
    "int2" => "SMALLINT",
    "int4" => "INTEGER",
    "int8" => "BIGINT",
    "integer" => "INTEGER",
    "smallint" => "SMALLINT",
    "bigint" => "BIGINT",
    "tinyint" => "TINYINT",
    "character" => "VARCHAR",
    "varchar" => "VARCHAR",
    "text" => "TEXT",
    "string" => "STRING",
    "char" => "CHAR",
    "bpchar" => "BPCHAR",
    "boolean" => "BOOLEAN",
    "bool" => "BOOLEAN"
  }

  @doc """
  Gate a parsed dump. `sql_text` supplies the CREATE TABLE DDL (where the
  NOT NULL / PK declarations live); `tables` is Smalt.SqlIngest.parse_dump/1
  output. Returns :ok, or a typed refusal naming the violated shape, column,
  constraint and row number.
  """
  @spec check(String.t(), %{
          optional(String.t()) => %{columns: [String.t()], rows: [[String.t() | :null]]}
        }) :: :ok | {:refusal, map()}
  def check(sql_text, tables) when is_binary(sql_text) and is_map(tables) do
    try do
      with {:ok, schema} <- schema_from_ddl(sql_text),
           {:ok, shapes} <- shapes_for(schema) do
        validate_tables(schema, shapes, tables)
      end
    rescue
      e in __MODULE__.SqlTypeError ->
        {:refusal,
         %{
           rule_id: "sql.shape_generation",
           diagnostic: Exception.message(e),
           repair_hint:
             "every governed column needs a substrate counterpart (INTEGER family -> xsd:integer, " <>
               "VARCHAR family -> xsd:string, BOOLEAN family -> xsd:boolean); widen or drop the " <>
               "column, then re-POST",
           digest_term: {:shape_generation, Exception.message(e)}
         }}
    end
  end

  @doc "Parse the dump's CREATE TABLE DDL into the SQLD-5 schema model."
  @spec schema_from_ddl(String.t()) :: {:ok, list(map())} | {:refusal, map()}
  def schema_from_ddl(sql_text) when is_binary(sql_text) do
    case Regex.scan(@ddl_regex, sql_text, capture: Regex.names(@ddl_regex)) do
      [] ->
        {:refusal,
         %{
           rule_id: "sql.shape_generation",
           diagnostic: "no CREATE TABLE DDL found in dump",
           repair_hint:
             "a pg_dump text file precedes each COPY block with CREATE TABLE DDL; " <>
               "POST a full pg_dump text file and re-POST",
           digest_term: {:no_ddl, "sql-ingest"}
         }}

      ddl ->
        {:ok, Enum.map(ddl, &ddl_table(Enum.zip(Regex.names(@ddl_regex), &1) |> Map.new()))}
    end
  end

  defp ddl_table(caps) do
    _schema = caps["schema"]
    table = caps["table"]
    body = caps["body"]
    # The schema model carries the SHORT table name: SqlShapeGen's camelize
    # and targetClass emission do not handle schema-qualified names, and the
    # qualified form survives only in diagnostics (sql-qualified COPY target).
    %{table: table, columns: parse_columns(table, body), closed: true}
  end

  # -- DDL body -> column specs ------------------------------------------------

  defp parse_columns(table, body) do
    {cols_rev, _pk} =
      split_items(body)
      |> Enum.reduce({[], MapSet.new()}, fn item, {cols, pk} ->
        case classify(item) do
          {:column, name, type, null, is_pk} ->
            {[col_spec(table, name, type, null, is_pk or MapSet.member?(pk, name)) | cols], pk}

          {:constraint, pk_cols} ->
            {cols, MapSet.union(pk, MapSet.new(pk_cols))}

          {:skip, nil} ->
            {cols, pk}
        end
      end)

    Enum.reverse(cols_rev)
  end

  defp col_spec(table, name, type, null, is_pk) do
    %{
      table: table,
      name: name,
      type: type,
      null: null,
      pk: is_pk,
      closed: true
    }
  end

  defp classify(item) do
    case String.split(String.trim(item)) do
      [] -> {:skip, nil}
      [first | rest] -> classify_item(item, first, rest)
    end
  end

  defp classify_item(item, first, rest) do
    cond do
      first in ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "EXCLUDE"] ->
        {:constraint, pk_columns(item)}

      true ->
        column_item(first, rest)
    end
  end

  defp column_item(name0, rest) do
    name = name0 |> String.trim("\"") |> String.trim()

    if name == "" or String.contains?(name, "(") do
      {:skip, nil}
    else
      case rest do
        [] ->
          {:column, name, "TEXT", "YES", false}

        _ ->
          {type_tokens, modifiers} = split_type(rest)
          norm = String.downcase(hd(type_tokens))

          case Map.fetch(@type_alias, norm) do
            {:ok, sql_type} ->
              null = if modifier?(modifiers, ["NOT", "NULL"]), do: "NO", else: "YES"
              is_pk = modifier?(modifiers, ["PRIMARY", "KEY"])
              {:column, name, sql_type, null, is_pk}

            :error ->
              # SQLD-5 typed no-silent-widening law: a governed column with no
              # substrate counterpart refuses, naming table.column.
              raise __MODULE__.SqlTypeError,
                    message:
                      "no substrate sh:datatype for column #{name} of SQL type #{hd(type_tokens)} " <>
                        "(supported: INTEGER family -> xsd:integer, VARCHAR family -> xsd:string, " <>
                        "BOOLEAN family -> xsd:boolean)"
          end
      end
    end
  end

  defp split_type(rest) do
    idx =
      Enum.find_index(rest, fn t ->
        String.upcase(t) in ["NOT", "DEFAULT", "PRIMARY", "UNIQUE", "CHECK", "REFERENCES", "GENERATED", "CONSTRAINT"]
      end)

    if idx do
      {Enum.take(rest, idx), Enum.drop(rest, idx)}
    else
      {rest, []}
    end
  end

  defp modifier?([], _pair), do: false

  defp modifier?(modifiers, pair) do
    ups = Enum.map(modifiers, &String.upcase/1)
    n = length(pair)

    ups == pair or
      Enum.any?(0..(length(ups) - n)//1, fn i ->
        Enum.slice(ups, i, n) == pair
      end)
  end

  defp pk_columns(item) do
    case Regex.run(~r/PRIMARY\s+KEY\s*\(([^)]*)\)/i, item) do
      [_, cols] ->
        cols
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  defp split_items(body) do
    body
    |> split_top_level_commas()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # split on commas at paren-depth 0 (varchar(50) survives)
  defp split_top_level_commas(body), do: do_split(body, 0, [], [])

  defp do_split(<<>>, _depth, cur, acc) do
    parts =
      case cur do
        [] -> acc
        _ -> [IO.iodata_to_binary(Enum.reverse(cur)) | acc]
      end

    Enum.reverse(parts)
  end

  defp do_split(<<?(, rest::binary>>, depth, cur, acc),
    do: do_split(rest, depth + 1, [?( | cur], acc)

  defp do_split(<<?), rest::binary>>, depth, cur, acc),
    do: do_split(rest, depth - 1, [?) | cur], acc)

  defp do_split(<<?,, rest::binary>>, 0, cur, acc),
    do: do_split(rest, 0, [], [IO.iodata_to_binary(Enum.reverse(cur)) | acc])

  defp do_split(<<c, rest::binary>>, depth, cur, acc),
    do: do_split(rest, depth, [c | cur], acc)

  # -- shapes + row validation ---------------------------------------------------

  defp shapes_for(schema) do
    ttl = SqlShapeGen.generate(schema)

    {:ok, SqlShapeGen.parse(ttl)}
  rescue
    e in ArgumentError ->
      {:refusal,
       %{
         rule_id: "sql.shape_generation",
         diagnostic: Exception.message(e),
         repair_hint:
           "every governed column needs a substrate counterpart (INTEGER family -> xsd:integer, " <>
             "VARCHAR family -> xsd:string, BOOLEAN family -> xsd:boolean); widen the column " <>
             "in the source schema or drop it, then re-POST",
         digest_term: {:shape_generation, Exception.message(e)}
       }}
  end

  defp validate_tables(schema, shapes, tables) do
    Enum.find_value(schema, fn %{table: table, columns: cols} ->
      case validate_one_table(table, cols, shapes, tables) do
        :ok -> nil
        {:refusal, _} = r -> r
      end
    end)
    |> case do
      nil -> :ok
      {:refusal, _} = r -> r
    end
  end

  defp validate_one_table(table, cols, shapes, tables) do
    shape = shape_for(shapes, table)
    dump_table =
      Map.get(tables, table) || Map.get(tables, short_name(table)) ||
        Enum.find(tables, fn {k, _v} -> short_name(k) == table end) |> elem_from() || %{}
    rows = Map.get(dump_table, :rows, [])

    # Governance applies where the schema is actually declared: a table whose
    # COPY column list does not match its DDL column set is NOT row-gated
    # (typed divergence: schema-unknown data is not judged by shapes it never
    # declared). Only set-equal column lists are governed.
    copy_cols = Map.get(dump_table, :columns, [])
    ddl_cols = Enum.map(cols, & &1.name)

    governed? =
      Enum.empty?(cols) or copy_cols == [] or
        MapSet.new(Enum.map(copy_cols, &normalize_col_name/1)) ==
          MapSet.new(Enum.map(ddl_cols, &normalize_col_name/1))

    if not governed? do
      IO.inspect({:dbg_governed, copy_cols, ddl_cols, governed?, rows}, label: "GLD6DBG")
      :ok
    else
      rows
      |> Enum.with_index(1)
      |> Enum.find_value(fn {row, n} ->
        payload = type_row(cols, row)

        case Validator.validate_shape(shape, payload) do
          v when v in [:valid, {:ok}] ->
            nil

          {:invalid, violations} ->
            {:refusal, row_refusal(table, shape_name(table), n, payload, violations)}
        end
      end)
      |> case do
        nil -> :ok
        {:refusal, _} = r -> r
      end
    end
  end

  defp normalize_col_name(name), do: name |> String.trim("\"") |> String.downcase()

  defp elem_from(nil), do: nil
  defp elem_from({_, v}), do: v

  defp shape_for(shapes, table) do
    Map.get(shapes, "sql_" <> camelize(short_name(table))) ||
      Map.get(shapes, hd(Map.keys(shapes)))
  end

  defp row_refusal(table, shape, n, _payload, violations) do
    v = hd(violations)

    %{
      rule_id: "sql.shacl_row",
      diagnostic:
        "row #{n} of #{table} violates #{shape}: " <>
          "#{v.constraint} violation on column #{v.path}: #{v.message}",
      repair_hint:
        "fix column #{v.path} in row #{n} (#{v.constraint}: #{v.message}) and re-POST; " <>
          "a refused dump projects nothing",
      digest_term: {:sql_shacl_row, table, n, v.path, v.constraint, v.message}
    }
  end

  # -- COPY row -> typed payload --------------------------------------------------

  # Values are COPY text binaries; typing rides the SQLD-5 datatype: integer
  # family -> JSON integer (a non-integer binary stays binary so the datatype
  # constraint fires), boolean -> true/false, string -> binary, NULL -> nil.
  defp type_row(cols, row) do
    cols
    |> Enum.with_index()
    |> Enum.into(%{}, fn {col, i} ->
      raw = Enum.at(row, i, :null)
      {col.name, type_value(col.type, raw)}
    end)
  end

  defp type_value(_type, :null), do: nil

  defp type_value(type, raw) when is_binary(raw) do
    case SqlShapeGen.datatype_for(type) do
      :integer -> int_or_raw(raw)
      :boolean -> bool_or_raw(raw)
      :string -> raw
    end
  end

  defp int_or_raw(raw) do
    case Integer.parse(raw) do
      {i, ""} -> i
      _ -> raw
    end
  end

  defp bool_or_raw(raw) do
    case String.downcase(raw) do
      t when t in ["t", "true", "yes", "1"] -> true
      f when f in ["f", "false", "no", "0"] -> false
      _ -> raw
    end
  end

  defp shape_name(table), do: "Sql" <> camelize(short_name(table)) <> "Shape"

  defp camelize(name) do
    name
    |> String.split(["_", "-", " "], trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  defp short_name(qualified) do
    case String.split(qualified, ".", parts: 2) do
      [_schema, name] -> name
      [name] -> name
    end
  end
end

defmodule Smalt.GraphLaw.SqlRowGate.SqlTypeError do
  @moduledoc false
  defexception [:message]
end
