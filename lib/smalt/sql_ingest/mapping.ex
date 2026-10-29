defmodule Smalt.SqlIngest.Mapping do
  @moduledoc """
  SQLD-4: relational → OCEL projection DSL — "SQL data before arrives as
  migrations, not dumps": a `sql:TableMapping` Turtle DSL declaring how a
  source table projects into the COLD-1 OCEL v2 schema, compiled to a
  projection spec the ingest pipeline consumes.

  ## DSL (Turtle subset, the SQL-AST-in-RDF pattern from the case study)

      @prefix ex:  <http://example.org/> .
      @prefix sql: <http://example.org/sql#> .

      ex:OrdersMapping a sql:TableMapping ;
        sql:sourceTable     "orders" ;
        sql:role            "event" ;
        sql:eventKeyColumn  "order_id" ;
        sql:eventTypeColumn "status" ;
        sql:timestampColumn "created_at" ;
        sql:objectColumns   "customer_id" ;
        sql:qualifier       "placed_by" .

  ## Roles

    * `event` — each row becomes one OCEL event: id from
      `sql:eventKeyColumn`, type from `sql:eventTypeColumn`, time from
      `sql:timestampColumn`, one relationship per `sql:objectColumns`
      value with `sql:qualifier`. All remaining columns land in event
      attributes, typed — unmapped columns included, never dropped.
    * `object` — each row becomes one OCEL object: id from
      `sql:keyColumn`, type `sql:objectType`; remaining columns land in
      object attributes, typed.
    * `rel` — each row names an EXISTING event and mints the object it
      relates it to: relationship (event ↔ object) attached to the
      projected event, plus the object itself (the standard OCEL pattern
      where relationship rows double as object observations, so
      referential integrity holds without a fourth mapping). Remaining
      columns become object attributes, typed.
  """

  alias Smalt.Ocel

  @roles ~w(event object rel)

  defstruct table: nil,
            role: nil,
            # role=event
            event_key: nil,
            event_type_column: nil,
            timestamp_column: nil,
            object_columns: [],
            qualifier: nil,
            # role=object
            key: nil,
            object_type: nil,
            # role=rel
            rel_event_key: nil,
            rel_object_key: nil,
            # filled by compile/1
            typed_columns: %{}

  @typedoc "One sql:TableMapping (typed_columns filled by compile/1)."
  @type t :: %__MODULE__{}

  # ---------------------------------------------------------------------------
  # Public API: parse / compile / shacl_gate / project / to_cold1_csvs
  # ---------------------------------------------------------------------------

  @doc """
  Parse the mapping Turtle (stdlib-only Turtle subset: `@prefix`,
  predicate lists, object lists, `a`, string/integer/float/boolean
  literals, IRIs) into mappings in document order. Anything outside the
  subset is `{:error, _}`, never a silent skip.
  """
  @spec parse(String.t()) :: {:ok, [t()]} | {:error, term()}
  def parse(ttl) when is_binary(ttl) do
    with {:ok, tokens} <- tokenize(ttl),
         {:ok, {_prefixes, stmts}} <- parse_document(tokens),
         {:ok, mappings} <- build_mappings(stmts) do
      {:ok, mappings}
    end
  rescue
    e -> {:error, {:parse_failed, Exception.message(e)}}
  end

  @doc """
  Compile parsed mappings to the projection spec
  (`%{tables: %{table => mapping}}` with `typed_columns` filled: every
  DECLARED column keeps its declared type; columns not declared in the
  mapping are absent here and typed by value at projection time — the
  "unmapped columns typed, not dropped" law). Runs `shacl_gate/1`
  first: a mapping that fails the gate refuses to compile.
  """
  @spec compile([t()]) :: {:ok, %{tables: %{String.t() => t()}}} | {:error, term()}
  def compile(mappings) when is_list(mappings) do
    with :ok <- shacl_gate(mappings) do
      tables =
        Map.new(mappings, fn m ->
          typed = declared_columns(m) |> Map.new(&{&1, declared_type(m, &1)})
          {m.table, %{m | typed_columns: typed}}
        end)

      {:ok, %{tables: tables}}
    end
  end

  @doc """
  Fail-closed SHACL-shaped gate on the mapping itself. Returns `:ok` or
  `{:error, [{table, property, diagnostic}]}`. Rules — a gate that
  cannot refuse is the failure:

    * every `sql:TableMapping` MUST declare `sql:sourceTable` and a
      `sql:role` in #{inspect(@roles)}
    * role=event MUST declare `sql:eventTypeColumn` AND
      `sql:timestampColumn` — an untyped, timeless event is laundered
      nowhere
    * role=event MUST declare `sql:eventKeyColumn`
    * role=object MUST declare `sql:keyColumn` AND `sql:objectType`
    * role=rel MUST declare `sql:objectType`, `sql:eventKeyColumn` and
      `sql:objectKeyColumn`
    * source tables MUST be unique across the mapping document
  """
  @spec shacl_gate([t()]) :: :ok | {:error, [{atom(), atom(), String.t()}]}
  def shacl_gate(mappings) when is_list(mappings) do
    violations = Enum.flat_map(mappings, &gate_mapping/1) ++ dup_tables(mappings)

    case violations do
      [] -> :ok
      v -> {:error, v}
    end
  end

  @doc """
  Project parsed dump tables through the compiled spec into the COLD-1
  OCEL v2 schema: `%{events: [...], objects: [...]}` — the exact event/
  object maps `Smalt.Ocel.encode/1` consumes. Rows are `%{"col" =>
  value}` maps with binary values (as produced by
  `Smalt.SqlIngest.parse_dump/1`); numeric/boolean values are also
  accepted (typing follows the value).

  Referential integrity is enforced with
  `Smalt.Ocel.validate_envelope/2` — a projection with a dangling
  relationship is `{:error, _}`, never a partial envelope.
  """
  @spec project(%{tables: %{String.t() => t()}}, %{
          optional(String.t()) => [%{optional(String.t()) => term()}]
        }) ::
          {:ok, %{events: [map()], objects: [map()]}} | {:error, term()}
  def project(%{tables: tables}, rows) when is_map(rows) do
    with {:ok, %{events: events, objects: objects}} <- do_project(tables, rows),
         :ok <- Ocel.validate_envelope(events, objects) do
      {:ok, %{events: events, objects: objects}}
    end
  end

  @doc """
  Render a projected envelope into the COLD-1 OCEL v2 CSV contents
  (`ocel_events.csv` / `ocel_event_object_rel.csv` / `ocel_objects.csv`),
  COLD-1 core columns leading, attribute tail in first-seen order.
  """
  @spec to_cold1_csvs(%{events: [map()], objects: [map()]}) :: %{
          optional(String.t()) => String.t()
        }
  def to_cold1_csvs(%{events: events, objects: objects}) do
    event_attr_cols = attr_columns(events)
    object_attr_cols = attr_columns(objects)

    events_csv =
      csv(
        ["event_id", "event_type", "timestamp" | event_attr_cols],
        events,
        fn e -> [e["id"], e["type"], e["time"] | attr_values(e["attributes"], event_attr_cols)] end
      )

    rel_csv =
      csv(["event_id", "object_id", "qualifier"], rel_rows(events), fn r ->
        [r.event_id, r.object_id, r.qualifier]
      end)

    objects_csv =
      csv(
        ["object_id", "object_type" | object_attr_cols],
        objects,
        fn o -> [o["id"], o["type"] | attr_values(o["attributes"], object_attr_cols)] end
      )

    %{
      "ocel_events.csv" => events_csv,
      "ocel_event_object_rel.csv" => rel_csv,
      "ocel_objects.csv" => objects_csv
    }
  end

  # ---------------------------------------------------------------------------
  # Turtle tokenizer (stdlib only)
  # token forms: {:word, bin} | {:string, bin} | {:iri, bin}
  #              | {:punct, ";"} | {:punct, ","} | :dot
  # ---------------------------------------------------------------------------

  defp tokenize(text) do
    case tok(String.to_charlist(text), [], []) do
      {:tokens, tokens} -> {:ok, Enum.reverse(tokens)}
      {:error, _} = err -> err
    end
  end

  defp tok([], [], tokens), do: {:tokens, tokens}
  defp tok([], acc, tokens), do: {:tokens, flush_word(acc, tokens)}

  defp tok([c | rest], acc, tokens) when c in ~c' \t\r\n',
    do: tok(rest, [], flush_word(acc, tokens))

  defp tok([?. | rest], acc, tokens), do: tok(rest, [], [:dot | flush_word(acc, tokens)])
  defp tok([?; | rest], acc, tokens), do: tok(rest, [], [{:punct, ";"} | flush_word(acc, tokens)])
  defp tok([?, | rest], acc, tokens), do: tok(rest, [], [{:punct, ","} | flush_word(acc, tokens)])

  defp tok([?" | rest], acc, tokens) do
    case read_string(rest, []) do
      # error clause first: {string, rest2} matches ANY 2-tuple, so a later
      # {:error, _} clause is dead and error tuples tokenize as garbage.
      {:error, _} = err -> err
      {string, rest2} -> tok(rest2, [], [{:string, string} | flush_word(acc, tokens)])
    end
  end

  defp tok([?< | rest], acc, tokens) do
    case read_iri(rest, []) do
      {:error, _} = err -> err
      {iri, rest2} -> tok(rest2, [], [{:iri, iri} | flush_word(acc, tokens)])
    end
  end

  # comments run from an unquoted `#` to end of line; the tokenizer sees
  # them, so a "#" inside an IRI (sql#) or string literal is never a comment
  defp tok([?# | rest], acc, tokens), do: tok(skip_line(rest), [], flush_word(acc, tokens))

  defp tok([c | rest], acc, tokens), do: tok(rest, [c | acc], tokens)

  defp skip_line([]), do: []

  defp skip_line([?\n | rest]), do: rest
  defp skip_line([_c | rest]), do: skip_line(rest)


  defp flush_word([], tokens), do: tokens

  defp flush_word(acc, tokens) do
    [{:word, acc |> Enum.reverse() |> List.to_string()} | tokens]
  end

  defp read_string([], _acc), do: {:error, :unterminated_string}

  defp read_string([?" | rest], acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp read_string([?\\, e | rest], acc), do: read_string(rest, [escape(e) | acc])
  defp read_string([c | rest], acc), do: read_string(rest, [c | acc])

  defp escape(?n), do: ?\n
  defp escape(?t), do: ?\t
  defp escape(?r), do: ?\r
  defp escape(?"), do: ?"
  defp escape(?\\), do: ?\\
  defp escape(other), do: raise("bad string escape: \\#{[other]}")

  defp read_iri([], _acc), do: {:error, :unterminated_iri}
  defp read_iri([?> | rest], acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}
  defp read_iri([c | rest], acc), do: read_iri(rest, [c | acc])

  # ---------------------------------------------------------------------------
  # Document structure: @prefix directives + statements
  # ---------------------------------------------------------------------------

  defp parse_document(tokens), do: parse_directives(tokens, %{}, [])

  defp parse_directives([], prefixes, stmts), do: {:ok, {prefixes, Enum.reverse(stmts)}}

  defp parse_directives(
         [{:word, "@prefix"}, {:word, pfx}, {:iri, ns}, :dot | rest],
         prefixes,
         stmts
       ) do
    parse_directives(rest, Map.put(prefixes, String.trim_trailing(pfx, ":"), ns), stmts)
  end

  defp parse_directives(tokens, prefixes, stmts) do
    with {:ok, subject, rest} <- pop_term(tokens),
         {:ok, pairs, rest} <- pop_predicate_objects(rest, prefixes) do
      parse_directives(rest, prefixes, [{expand(subject, prefixes), pairs} | stmts])
    end
  end

  defp pop_term([{t, _} = token | rest]) when t in [:word, :iri, :string], do: {:ok, token, rest}
  defp pop_term(_), do: {:error, :expected_term}

  defp pop_predicate_objects(tokens, prefixes), do: pop_predicates(tokens, prefixes, [])

  defp pop_predicates([{:word, verb} | rest], prefixes, acc) do
    with {:ok, objects, rest} <- pop_objects(rest, prefixes, []),
         {:iri, pred} <- expand({:word, verb}, prefixes) do
      case rest do
        [{:punct, ";"} | rest2] -> pop_predicates(rest2, prefixes, [{pred, objects} | acc])
        [:dot | rest2] -> {:ok, Enum.reverse([{pred, objects} | acc]), rest2}
        _ -> {:error, {:expected_semicolon_or_dot, verb}}
      end
    end
  end

  defp pop_predicates(_, _, _), do: {:error, :expected_predicate}

  defp pop_objects([token | rest], prefixes, acc) when elem(token, 0) in [:word, :iri, :string] do
    acc = [expand(token, prefixes) | acc]

    case rest do
      [{:punct, ","} | rest2] -> pop_objects(rest2, prefixes, acc)
      _ -> {:ok, Enum.reverse(acc), rest}
    end
  end

  defp pop_objects(_, _, _), do: {:error, :expected_object}

  defp expand({:word, "a"}, _prefixes),
    do: {:iri, "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"}

  defp expand({:word, name}, prefixes) do
    case String.split(name, ":", parts: 2) do
      [pfx, local] ->
        case Map.fetch(prefixes, pfx) do
          {:ok, ns} -> {:iri, ns <> local}
          :error -> {:error, {:unknown_prefix, pfx}}
        end

      [bare] ->
        literal(bare)
    end
  end

  defp expand({:iri, iri}, _prefixes), do: {:iri, iri}
  defp expand({:string, s}, _prefixes), do: {:string, s}

  defp literal("true"), do: {:word, true}
  defp literal("false"), do: {:word, false}

  defp literal(bare) do
    cond do
      Regex.match?(~r/^-?\d+$/, bare) -> {:word, String.to_integer(bare)}
      Regex.match?(~r/^-?\d+\.\d+$/, bare) -> {:word, String.to_float(bare)}
      true -> {:word, bare}
    end
  end

  # ---------------------------------------------------------------------------
  # Statement → struct
  # ---------------------------------------------------------------------------

  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @table_mapping_class "http://example.org/sql#TableMapping"

  @vocabulary %{
    "http://example.org/sql#sourceTable" => :source_table,
    "http://example.org/sql#role" => :role,
    "http://example.org/sql#eventKeyColumn" => :event_key_column,
    "http://example.org/sql#eventTypeColumn" => :event_type_column,
    "http://example.org/sql#timestampColumn" => :timestamp_column,
    "http://example.org/sql#objectColumns" => :object_columns,
    "http://example.org/sql#qualifier" => :qualifier,
    "http://example.org/sql#keyColumn" => :key_column,
    "http://example.org/sql#objectType" => :object_type,
    "http://example.org/sql#objectKeyColumn" => :object_key_column,
    # rdf:type ("a sql:TableMapping") is consumed by build_mapping/2
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#type" => :rdf_type
  }

  defp build_mappings(stmts), do: build_mappings(stmts, [])

  defp build_mappings([], acc), do: {:ok, Enum.reverse(acc)}

  defp build_mappings([{subject, pairs} | rest], acc) do
    with {:ok, mapping} <- build_mapping(subject, pairs) do
      build_mappings(rest, [mapping | acc])
    end
  end

  defp build_mapping(subject, pairs) do
    if Enum.any?(pairs, fn {p, objs} -> p == @rdf_type and {:iri, @table_mapping_class} in objs end) do
      mapping = %__MODULE__{}

      mapping =
        Enum.reduce(pairs, mapping, fn {pred, objs}, acc ->
          apply_pair(subject, pred, objs, acc)
        end)

      {:ok, resolve_keys(mapping)}
    else
      {:error, {:not_a_table_mapping, subject}}
    end
  end

  defp apply_pair(subject, pred, objs, %__MODULE__{} = m) do
    case Map.fetch(@vocabulary, pred) do
      :error ->
        raise ArgumentError,
              "unknown sql: predicate #{inspect(pred)} on #{inspect(subject)} " <>
                "(mapping DSL vocabulary: #{inspect(Map.keys(@vocabulary) -- [@rdf_type])})"

      {:ok, :rdf_type} ->
        m

      {:ok, :source_table} ->
        %{m | table: literal_string!(subject, pred, objs)}

      {:ok, :role} ->
        %{m | role: literal_string!(subject, pred, objs)}

      {:ok, :event_type_column} ->
        %{m | event_type_column: literal_string!(subject, pred, objs)}

      {:ok, :timestamp_column} ->
        %{m | timestamp_column: literal_string!(subject, pred, objs)}

      {:ok, :qualifier} ->
        %{m | qualifier: literal_string!(subject, pred, objs)}

      {:ok, :key_column} ->
        %{m | key: literal_string!(subject, pred, objs)}

      {:ok, :object_type} ->
        %{m | object_type: literal_string!(subject, pred, objs)}

      {:ok, :object_key_column} ->
        %{m | rel_object_key: literal_string!(subject, pred, objs)}

      {:ok, :event_key_column} ->
        # role-relative: resolved after the document is read (see resolve_keys/1)
        %{m | event_key: literal_string!(subject, pred, objs)}

      {:ok, :object_columns} ->
        cols = Enum.map(objs, &literal_string!(subject, pred, [&1]))
        %{m | object_columns: m.object_columns ++ cols}
    end
  end

  defp resolve_keys(%__MODULE__{role: "rel", event_key: k} = m), do: %{m | rel_event_key: k, event_key: nil}
  defp resolve_keys(m), do: m

  defp literal_string!(_subject, _pred, [{:string, s}]) when is_binary(s), do: s

  defp literal_string!(subject, pred, objs) do
    raise {:expected_string_literal, subject, pred, objs}
  end

  # ---------------------------------------------------------------------------
  # SHACL gate
  # ---------------------------------------------------------------------------

  defp gate_mapping(%__MODULE__{table: nil}), do: [{:mapping, :sourceTable, "missing sql:sourceTable"}]

  defp gate_mapping(%__MODULE__{table: t, role: nil}),
    do: [{t, :role, "missing sql:role"}]

  defp gate_mapping(%__MODULE__{table: t, role: role} = m) when role in @roles do
    checks = [
      {m.role == "event" and not is_binary(m.event_type_column), t, :eventTypeColumn,
       "role=event requires sql:eventTypeColumn"},
      {m.role == "event" and not is_binary(m.timestamp_column), t, :timestampColumn,
       "role=event requires sql:timestampColumn"},
      {m.role == "event" and not is_binary(m.event_key), t, :eventKeyColumn,
       "role=event requires sql:eventKeyColumn"},
      {m.role == "object" and not is_binary(m.key), t, :keyColumn,
       "role=object requires sql:keyColumn"},
      {m.role == "object" and not is_binary(m.object_type), t, :objectType,
       "role=object requires sql:objectType"},
      {m.role == "rel" and not is_binary(m.rel_event_key), t, :eventKeyColumn,
       "role=rel requires sql:eventKeyColumn"},
      {m.role == "rel" and not is_binary(m.rel_object_key), t, :objectKeyColumn,
       "role=rel requires sql:objectKeyColumn"},
      {m.role == "rel" and not is_binary(m.object_type), t, :objectType,
       "role=rel requires sql:objectType"}
    ]

    for {failed, table, prop, msg} <- checks, failed, do: {table, prop, msg}
  end

  defp gate_mapping(%__MODULE__{table: t, role: role}),
    do: [{t, :role, "unknown role #{inspect(role)} (expected one of #{inspect(@roles)})"}]

  defp dup_tables(mappings) do
    mappings
    |> Enum.map(& &1.table)
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_t, n} -> n > 1 end)
    |> Enum.map(fn {t, _n} -> {t, :sourceTable, "duplicate sql:sourceTable in mapping document"} end)
  end

  # ---------------------------------------------------------------------------
  # Projection
  # ---------------------------------------------------------------------------

  defp do_project(tables, rows) do
    ordered = Enum.sort_by(tables, fn {_name, m} -> role_rank(m.role) end)

    with {:ok, acc} <-
           Enum.reduce_while(ordered, {:ok, %{events: [], objects: [], rels: []}}, fn
             {_name, m}, {:ok, acc} ->
               case project_table(m, Map.get(rows, m.table, []), acc) do
                 {:ok, acc2} -> {:cont, {:ok, acc2}}
                 {:error, _} = err -> {:halt, err}
               end
           end),
         {:ok, events} <- attach_relationships(acc.events, Enum.reverse(acc.rels)) do
      # deterministic order: events by {time, id}, objects by id
      events = Enum.sort_by(events, &{&1["time"], &1["id"]})

      objects =
        acc.objects
        |> Enum.reverse()
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, type, attrs} -> object(id, type, attrs) end)

      {:ok, %{events: events, objects: objects}}
    end
  end

  defp object(id, type, attrs), do: %{"id" => id, "type" => type, "attributes" => attrs}

  defp role_rank("object"), do: 0
  defp role_rank("rel"), do: 1
  defp role_rank("event"), do: 2

  defp project_table(m, rows, acc) do
    Enum.reduce_while(rows, {:ok, acc}, fn row, {:ok, acc} ->
      case project_row(m, row) do
        {:ok, event, object, rel} ->
          {:cont,
           {:ok,
            %{
              events: List.wrap(event) ++ acc.events,
              objects: List.wrap(object) ++ acc.objects,
              rels: List.wrap(rel) ++ acc.rels
            }}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp project_row(%__MODULE__{role: "object"} = m, row) do
    with {:ok, attrs} <- attributes(m, row),
         {:ok, id} <- row_value(m.table, row, m.key) do
      {:ok, nil, {id, m.object_type, attrs}, nil}
    end
  end

  defp project_row(%__MODULE__{role: "rel"} = m, row) do
    with {:ok, attrs} <- attributes(m, row),
         {:ok, event_id} <- row_value(m.table, row, m.rel_event_key),
         {:ok, object_id} <- row_value(m.table, row, m.rel_object_key) do
      qualifier = Map.get(row, "__qualifier__", m.qualifier || "related_to")
      object = {object_id, m.object_type, attrs}
      relationship = %{event_id: event_id, object_id: object_id, qualifier: qualifier}
      {:ok, nil, object, relationship}
    end
  end

  defp project_row(%__MODULE__{role: "event"} = m, row) do
    with {:ok, attrs} <- attributes(m, row),
         {:ok, id} <- row_value(m.table, row, m.event_key),
         {:ok, type} <- row_value(m.table, row, m.event_type_column),
         {:ok, time} <- row_value(m.table, row, m.timestamp_column) do
      rels =
        for col <- m.object_columns do
          %{objectId: Map.fetch!(row, col), qualifier: m.qualifier || "related_to"}
        end

      event = %{
        "id" => id,
        "type" => type,
        "time" => time,
        "attributes" => attrs,
        "relationships" =>
          Enum.map(rels, fn r -> %{"objectId" => r.objectId, "qualifier" => r.qualifier} end)
      }

      {:ok, event, nil, nil}
    end
  end

  # rel rows reference events projected from other tables; attach them
  # after all event tables are projected. An unknown event id is a
  # referential failure (also re-caught by validate_envelope).
  defp attach_relationships(events, rels) do
    Enum.reduce(rels, {:ok, events}, fn rel, {:ok, acc} ->
      case Enum.find_index(acc, &(&1["id"] == rel.event_id)) do
        nil ->
          {:error, {:dangling_relationship, rel.event_id, rel.object_id}}

        idx ->
          List.update_at(acc, idx, fn e ->
            %{
              e
              | "relationships" =>
                  e["relationships"] ++
                    [%{"objectId" => rel.object_id, "qualifier" => rel.qualifier}]
            }
          end)
          |> then(&{:ok, &1})
      end
    end)
  end

  defp row_value(table, row, col) do
    case Map.fetch(row, col) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, {:missing_column, table, col}}
    end
  end

  defp attributes(m, row) do
    mapped =
      MapSet.new(
        [m.event_key, m.event_type_column, m.timestamp_column, m.key, m.rel_event_key, m.rel_object_key] ++
          m.object_columns
      )

    attrs =
      row
      |> Enum.reject(fn {col, _} -> MapSet.member?(mapped, col) end)
      |> Map.new(fn {col, value} -> {col, typed_value(value)} end)

    {:ok, attrs}
  end

  defp typed_value(v) when is_boolean(v), do: %{value: v, type: "xsd:boolean"}
  defp typed_value(v) when is_integer(v), do: %{value: v, type: "xsd:integer"}
  defp typed_value(v) when is_float(v), do: %{value: v, type: "xsd:double"}

  defp typed_value(v) when is_binary(v) do
    cond do
      Regex.match?(~r/^-?\d+$/, v) -> %{value: String.to_integer(v), type: "xsd:integer"}
      Regex.match?(~r/^-?\d+\.\d+$/, v) -> %{value: String.to_float(v), type: "xsd:double"}
      v in ["true", "false"] -> %{value: v == "true", type: "xsd:boolean"}
      true -> %{value: v, type: "xsd:string"}
    end
  end

  defp typed_value(nil), do: %{value: nil, type: "xsd:string"}
  defp typed_value(v), do: %{value: v, type: "xsd:string"}

  defp declared_columns(m) do
    [
      m.event_key,
      m.event_type_column,
      m.timestamp_column,
      m.key,
      m.rel_event_key,
      m.rel_object_key
    ]
    |> Enum.concat(m.object_columns)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp declared_type(m, col) do
    cond do
      col == m.timestamp_column -> "xsd:dateTime"
      col in m.object_columns -> "xsd:string"
      col == m.event_type_column -> "xsd:string"
      true -> "inferred"
    end
  end

  # ---------------------------------------------------------------------------
  # COLD-1 CSV rendering
  # ---------------------------------------------------------------------------

  defp rel_rows(events) do
    for e <- events,
        rel <- e["relationships"] || [],
        do: %{event_id: e["id"], object_id: rel["objectId"], qualifier: rel["qualifier"]}
  end

  defp attr_columns(records) do
    records
    |> Enum.flat_map(&Map.keys(&1["attributes"] || %{}))
    |> Enum.uniq()
  end

  defp attr_values(attrs, cols), do: Enum.map(cols, &(format_attr(attrs[&1]) || ""))

  defp format_attr(nil), do: ""
  defp format_attr(%{value: v}), do: to_string(v)

  defp csv(header, rows, f) do
    IO.iodata_to_binary([
      Enum.join(header, ","),
      "\n",
      Enum.map(rows, fn row -> [Enum.map_join(f.(row), ",", &csv_field/1), "\n"] end)
    ])
  end

  defp csv_field(v), do: v |> to_string() |> String.replace("\"", "\"\"") |> then(&"\"#{&1}\"")
end
