defmodule Smalt.Enclave.Hcl do
  @moduledoc """
  Minimal HCL2-subset parser for the enclave's terraform plan fixtures.

  Covers exactly the fixture grammar surface: `terraform` / `provider` /
  `resource` blocks with quoted or bare labels, scalar attributes
  (string / number / bool), inline maps (`{ k = v }`), lists (`[v, ...]`),
  dotted references (`azurerm_label.label.attr` tokenized as
  `{:ref, "<type>.<name>", attr}` — never resolved here), and nested
  blocks (`features {}`, `consistency_policy {}`, ...).

  Out of scope by design: heredocs, expressions, functions, `dynamic`,
  multi-line strings.

  Deterministic: plain term-ordered maps; resource list in file order.

  Line numbers: each summarized block carries `:line` for diagnostics;
  failures return the typed error `{:error, {:hcl_parse, line, message}}`.
  """

  @type ref :: {:ref, String.t(), String.t()}

  @type value ::
          String.t()
          | number()
          | boolean()
          | [value()]
          | %{optional(String.t()) => value()}
          | ref()

  @type doc :: %{
          provider: %{String.t() => %{attrs: map(), line: pos_integer()}},
          resources: [
            %{
              type: String.t(),
              labels: [String.t()],
              name: String.t(),
              attrs: map(),
              line: pos_integer()
            }
          ]
        }

  @doc "Parses an HCL file at `path`."
  @spec parse(Path.t() | String.t()) ::
          {:ok, doc()} | {:error, {:hcl_parse, pos_integer(), String.t()}}
  def parse(path) do
    with {:ok, contents} <- File.read(path) do
      parse_string(contents)
    end
  end

  @doc "Parses HCL text directly (tests and diagnostics)."
  @spec parse_string(String.t()) ::
          {:ok, doc()} | {:error, {:hcl_parse, pos_integer(), String.t()}}
  def parse_string(contents) when is_binary(contents) do
    case parse_body(%{bin: contents, line: 1}, :eof) do
      {_state, entries} -> summarize(entries)
      {:error, _state, line, msg} -> {:error, {:hcl_parse, line, msg}}
    end
  end

  ## Character-level helpers. State: %{bin: binary, line: pos_integer()}.

  defp line(%{line: line}), do: line

  defp peek(%{bin: <<ch::utf8, _::binary>>}), do: {:ok, <<ch::utf8>>}
  defp peek(%{bin: <<>>}), do: {:eof}

  defp take(%{bin: <<ch::utf8, rest::binary>>, line: line} = state) do
    line = if ch == ?\n, do: line + 1, else: line
    {%{state | bin: rest, line: line}, <<ch::utf8>>}
  end

  defp take_while(state, pred, acc \\ [])

  defp take_while(%{bin: <<ch::utf8, _::binary>>} = state, pred, acc) do
    if pred.(<<ch::utf8>>) do
      {state, c} = take(state)
      take_while(state, pred, [c | acc])
    else
      {state, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp take_while(state, _pred, acc) do
    {state, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  # lane-398 unblock fix (compile-freeze SLA disclosure): defguardp so the
  # guards at parse_value/collect_ref_segments can invoke it; defguardp also
  # emits the runtime function the take_while/2 call-sites use.
  defguardp ident_char?(ch)
            when ch in ["_", "-"] or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or
                   (ch >= "0" and ch <= "9")

  defp parse_ident(state) do
    case peek(state) do
      {:ok, ch} ->
        if ident_char?(ch) do
          {state, name} = take_while(state, &ident_char?/1)
          {:ok, state, name}
        else
          {:error, state, line(state), "expected identifier, got #{inspect(ch)}"}
        end

      {:eof} ->
        {:error, state, line(state), "unexpected end of input, expected identifier"}
    end
  end

  # Whitespace + line comments (# and //). Returns state.
  defp skip_trivia(state) do
    case skip_inline(state) do
      {state, :nl} -> skip_trivia(state)
      {state, :done} -> state
    end
  end

  defp skip_inline(state) do
    case peek(state) do
      {:ok, w} when w in [" ", "\t", "\r", "\n"] ->
        {elem(take(state), 0), :nl}

      {:ok, "#"} ->
        {elem(take_while(state, &(&1 != "\n")), 0), :nl}

      {:ok, "/"} ->
        case state.bin do
          <<"/", "/", _::binary>> ->
            {elem(take_while(state, &(&1 != "\n")), 0), :nl}

          _ ->
            {state, :done}
        end

      _ ->
        {state, :done}
    end
  end

  ## Body parsing. A body is a list of {:attr, name, value} | {:block, name, meta, body}.

  defp parse_body(state, terminator) do
    parse_entries(skip_trivia(state), terminator, [])
  end

  defp parse_entries(state, terminator, acc) do
    state = skip_trivia(state)

    case peek(state) do
      {:eof} when terminator == :eof ->
        {state, Enum.reverse(acc)}

      {:eof} ->
        {:error, state, line(state), "unexpected end of input inside block, expected }"}

      {:ok, "}"} when terminator == {:until, "}"} ->
        {state, Enum.reverse(acc)}

      {:ok, _} ->
        case parse_entry(state) do
          {state, entry} -> parse_entries(state, terminator, [entry | acc])
          {:error, _, _, _} = err -> err
        end
    end
  end

  # An entry is `ident = value` or `ident labels* { body }`.
  defp parse_entry(state) do
    start_line = line(state)

    with {:ok, state, ident} <- parse_ident(state),
         state <- skip_trivia(state) do
      case peek(state) do
        {:ok, "="} ->
          state = elem(take(state), 0)
          parse_attr_value(state, ident, start_line)

        _ ->
          {state, labels} = parse_labels(state)

          with state <- skip_trivia(state),
               {:ok, state, _} <- expect_char(state, "{") do
            case parse_body(state, {:until, "}"}) do
              {state, body} ->
                with {:ok, state, _} <- expect_char(state, "}") do
                  {state, {:block, ident, %{__line__: start_line, __labels__: labels}, body}}
                end

              {:error, _, _, _} = err ->
                err
            end
          end
      end
    end
  end

  defp parse_attr_value(state, ident, start_line) do
    case parse_value(state) do
      {:ok, state, value} -> {state, {:attr, ident, value, start_line}}
      {:error, _, _, _} = err -> err
    end
  end

  defp parse_labels(state) do
    state = state |> skip_inline() |> elem(0)

    case peek(state) do
      {:ok, "\""} ->
        case parse_string_literal(state) do
          {:ok, state, s} ->
            case parse_labels(state) do
              {state, rest} -> {state, [s | rest]}
              {:error, _, _, _} = err -> err
            end

          {:error, _, _, _} = err ->
            err
        end

      {:ok, ch} when ident_char?(ch) and ch != "=" ->
        {state, name} = take_while(state, &ident_char?/1)
        {state, [name | parse_labels_unsafe(state)]}

      _ ->
        {state, []}
    end
  end

  defp parse_labels_unsafe(state) do
    case parse_labels(state) do
      {_state, labels} -> labels
      _ -> []
    end
  end

  defp expect_char(state, c) do
    case peek(state) do
      {:ok, ^c} ->
        {:ok, elem(take(state), 0), c}

      _ ->
        {:error, state, line(state), "expected #{inspect(c)}"}
    end
  end

  ## Values

  defp parse_value(state) do
    state = skip_trivia(state)

    case peek(state) do
      {:ok, "\""} ->
        parse_string_literal(state)

      {:ok, "["} ->
        parse_list(state)

      {:ok, "{"} ->
        parse_inline_map(state)

      {:ok, ch} when ch in ["t", "f"] ->
        parse_bool(state)

      {:ok, ch} when ch >= "0" and ch <= "9" ->
        parse_number(state)

      {:ok, ch} when ident_char?(ch) ->
        parse_reference(state)

      {:ok, ch} ->
        {:error, state, line(state), "unexpected character #{inspect(ch)} in value"}

      {:eof} ->
        {:error, state, line(state), "unexpected end of input in value"}
    end
  end

  defp parse_string_literal(state) do
    state = elem(take(state), 0)
    read_string_chars(state, [])
  end

  defp read_string_chars(%{line: line} = state, _chars) do
    case state.bin do
      <<>> -> {:error, state, line, "unterminated string literal"}
      _ -> do_read_string_chars(state, [])
    end
  end

  defp do_read_string_chars(state, chars) do
    case peek(state) do
      {:ok, "\""} ->
        state = elem(take(state), 0)
        {:ok, state, chars |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, "\\"} ->
        state = elem(take(state), 0)

        case take(state) do
          {state, "n"} -> do_read_string_chars(state, ["\n" | chars])
          {state, "t"} -> do_read_string_chars(state, ["\t" | chars])
          {state, "\""} -> do_read_string_chars(state, ["\"" | chars])
          {state, "\\"} -> do_read_string_chars(state, ["\\" | chars])
          {state, other} -> do_read_string_chars(state, [other | chars])
        end

      {:ok, ch} ->
        state = elem(take(state), 0)
        do_read_string_chars(state, [ch | chars])

      {:eof} ->
        {:error, state, line(state), "unterminated string literal"}
    end
  end

  defp parse_bool(state) do
    {state, word} = take_while(state, &ident_char?/1)

    case word do
      "true" -> {:ok, state, true}
      "false" -> {:ok, state, false}
      other -> {:error, state, line(state), "unknown literal #{inspect(other)}"}
    end
  end

  defp parse_number(state) do
    {state, digits} = take_while(state, &(&1 >= "0" and &1 <= "9"))

    case state do
      %{bin: <<".", ch::utf8, _::binary>>} when ch >= ?0 and ch <= ?9 ->
        state = elem(take(state), 0)
        {state, frac} = take_while(state, &(&1 >= "0" and &1 <= "9"))
        {:ok, state, String.to_float(digits <> "." <> frac)}

      _ ->
        {:ok, state, String.to_integer(digits)}
    end
  end

  # Dotted reference: `type.name.attr` -> {:ref, "type.name", "attr"}.
  # Multi-hop paths keep every segment but the last in the prefix.
  defp parse_reference(state) do
    {state, first} = take_while(state, &ident_char?/1)
    collect_ref_segments(state, [first])
  end

  defp collect_ref_segments(%{bin: <<".", ch::utf8, _::binary>>} = state, segs)
       when ident_char?(<<ch>>) do
    # lane-403 unblock fix (compile-freeze SLA disclosure): the matched "."
    # was never consumed, so take_while returned an empty segment with the
    # state pinned at the dot — infinite recursion on any dotted ref
    # (e.g. azurerm_resource_group.rg.name). Consume the dot first.
    state = elem(take(state), 0)
    {state, seg} = take_while(state, &ident_char?/1)
    collect_ref_segments(state, [seg | segs])
  end

  defp collect_ref_segments(state, segs) do
    segs = Enum.reverse(segs)

    case segs do
      [only] ->
        {:ok, state, only}

      _ ->
        prefix = Enum.join(Enum.drop(segs, -1), ".")
        last = List.last(segs)
        {:ok, state, {:ref, prefix, last}}
    end
  end

  defp parse_list(state) do
    state = elem(take(state), 0)
    parse_list_items(state, [])
  end

  defp parse_list_items(state, acc) do
    state = skip_trivia(state)

    case peek(state) do
      {:ok, "]"} ->
        {:ok, elem(take(state), 0), Enum.reverse(acc)}

      {:eof} ->
        {:error, state, line(state), "unterminated list"}

      _ ->
        case parse_value(state) do
          {:ok, state, item} ->
            state = skip_trivia(state)

            case peek(state) do
              {:ok, "]"} ->
                {:ok, elem(take(state), 0), Enum.reverse([item | acc])}

              _ ->
                case expect_char(state, ",") do
                  {:ok, state, _} -> parse_list_items(state, [item | acc])
                  {:error, _, _, _} = err -> err
                end
            end

          {:error, _, _, _} = err ->
            err
        end
    end
  end

  defp parse_inline_map(state) do
    state = elem(take(state), 0)
    parse_map_entries(state, [])
  end

  defp parse_map_entries(state, acc) do
    state = skip_trivia(state)

    case peek(state) do
      {:ok, "}"} ->
        {:ok, elem(take(state), 0), Map.new(Enum.reverse(acc))}

      {:eof} ->
        {:error, state, line(state), "unterminated inline map"}

      _ ->
        case parse_ident(state) do
          {:ok, state, key} ->
            state = skip_trivia(state)

            case expect_char(state, "=") do
              {:ok, state, _} ->
                case parse_value(state) do
                  {:ok, state, value} ->
                    state = skip_trivia(state)

                    state =
                      case peek(state) do
                        {:ok, ","} -> elem(take(state), 0)
                        _ -> state
                      end

                    parse_map_entries(state, [{key, value} | acc])

                  {:error, _, _, _} = err ->
                    err
                end

              {:error, _, _, _} = err ->
                err
            end

          {:error, _, _, _} = err ->
            err
        end
    end
  end

  ## Summary projection.

  defp summarize(entries) do
    with {:ok, resources} <- summarize_resources(entries),
         {:ok, providers} <- summarize_providers(entries) do
      {:ok, %{provider: providers, resources: resources}}
    end
  end

  defp summarize_resources(entries) do
    entries
    |> Enum.filter(&match?({:block, "resource", _, _}, &1))
    |> Enum.reduce_while({:ok, []}, fn {:block, "resource", meta, body}, {:ok, acc} ->
      case meta.__labels__ do
        [type, name] ->
          {:cont,
           {:ok,
            [
              %{
                type: type,
                labels: meta.__labels__,
                name: name,
                attrs: project_body(body),
                line: meta.__line__
              }
              | acc
            ]}}

        labels ->
          # SHIM-COURT: malformed resource block (fewer than 2 labels) is a
          # typed parse error, not a raw MatchError.
          {:halt, {:error, {:hcl_parse, meta.__line__, "resource block needs exactly 2 labels, got #{length(labels)}"}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp summarize_providers(entries) do
    entries
    |> Enum.filter(&match?({:block, "provider", _, _}, &1))
    |> Enum.sort_by(fn {:block, _, %{__labels__: labels}, _} -> labels end)
    |> Enum.reduce_while({:ok, %{}}, fn {:block, "provider", meta, body}, {:ok, acc} ->
      case meta.__labels__ do
        [ptype] ->
          {:cont, {:ok, Map.put(acc, ptype, %{attrs: project_body(body), line: meta.__line__})}}

        labels ->
          # SHIM-COURT: malformed provider block (not exactly 1 label) is a
          # typed parse error, not a raw MatchError.
          {:halt, {:error, {:hcl_parse, meta.__line__, "provider block needs exactly 1 label, got #{length(labels)}"}}}
      end
    end)
  end

  # Attrs become a map; nested blocks fold in as maps with :__line__ kept
  # for diagnostics.
  defp project_body(body) do
    Enum.reduce(body, %{}, fn
      {:attr, name, value, _line}, acc ->
        Map.put(acc, name, value)

      {:block, name, meta, inner}, acc ->
        Map.put(acc, name, Map.put(project_body(inner), :__line__, meta.__line__))
    end)
  end
end
