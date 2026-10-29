defmodule Smalt.SbRules do
  @moduledoc """
  80/20 Service Bus subscription rules: rule storage, SQL filter evaluation,
  correlation filters, and SET-only actions.

  Wire surface (ARM routes in `Smalt.ArmGateway.Router`):

      .../namespaces/:ns/topics/:topic/subscriptions/:sub/rules/:ruleName
      .../namespaces/:ns/topics/:topic/subscriptions/:sub/rules

  - A subscription with NO stored rules behaves exactly as before (default
    true-filter). The `$Default` rule is synthesized on LIST (same pattern as
    EventHub consumer-group `$default`) rather than written on create, so no
    create-path edit is needed.
  - Delivery semantics (80/20): a subscription with at least one NON-default
    rule admits a message iff it matches ANY of its filters; non-matching
    messages are skipped (not DLQ'd). `fan_out/2` implements the fan-out for
    the AMQP ingest seam: for each subscription under the topic it evaluates
    rules and enqueues matching messages into the subscription's queue
    (`"<topic>/subscriptions/<sub>"` in `Smalt.Amqp.QueueStore`).
  - SQL filter grammar (fail-closed): equality on application properties and
    `sys.label`, `EXISTS(prop)`, `AND`, `OR`, parentheses, `'string'` /
    numeric literals. ANY other construct refuses at rule-create time with a
    typed 400 (`InvalidFilter`); action refusals are `InvalidAction`.
  """

  # --- Rule storage -----------------------------------------------------------------

  @rule_type "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"
  @default_rule_name "$Default"

  def default_rule_name, do: @default_rule_name
  def rule_type, do: @rule_type

  @doc "Full ARM id (downcased) of a rule under a subscription."
  def rule_key(sub_base, ns, topic, sub, rule) do
    String.downcase(
      "#{sub_base}/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub}/rules/#{rule}"
    )
  end

  @doc """
  Rule id as rendered on the wire (no /providers/ segment, matching the
  parented-child record shape used by the ARM router for SB children).
  """
  def rule_wire_id(sub_id, rg, ns, topic, sub, rule) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg}/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub}/rules/#{rule}"
  end

  @doc "Stored rule record (or nil)."
  def get_rule(store, key), do: Smalt.Store.get(store, key)

  def put_rule(store, key, record), do: Smalt.Store.put(store, key, record)

  def delete_rule(store, key), do: Smalt.Store.delete(store, key)

  @doc "All stored rules under a subscription (list_prefix on the rules segment)."
  def list_rules(store, prefix), do: Smalt.Store.list_prefix(store, prefix)

  # --- Default rule synthesis ---------------------------------------------------------

  @doc """
  LIST payload: stored rules, plus a synthesized `$Default` true-filter rule
  when (and only when) no user rules exist for the subscription. A user rule
  literally named `$Default` renders verbatim exactly once.
  """
  def rules_payload([], sub_id, rg, ns, topic, sub) do
    [
      build_rule_record(
        @default_rule_name,
        rule_wire_id(sub_id, rg, ns, topic, sub, @default_rule_name),
        %{"trueFilter" => true}
      )
    ]
  end

  def rules_payload(stored, _, _, _, _, _), do: stored

  def build_rule_record(name, id, props) do
    %{
      "id" => id,
      "name" => name,
      "type" => @rule_type,
      "properties" => props
    }
  end

  @doc """
  True when the stored/filter properties represent the pass-through true
  filter (empty sqlExpression, trueFilter marker, or absent filter).
  """
  def true_filter?(props) when is_map(props) do
    props = unwrap_filter(props)

    case normalize_filter(props) do
      {:ok, {true, _}} -> true
      _ -> false
    end
  end

  # KD-143 adversarial leg: a partially-persisted rule (properties key lost
  # in a torn restore) is NOT a pass-through true filter — fail-closed skip,
  # never a FunctionClauseError on the fan-out path.
  def true_filter?(_props), do: false

  @doc """
  Subscription admits a message under 80/20 delivery semantics:
  - no rules (or all true-filters) -> admit;
  - any filter matches -> admit; otherwise skip (never DLQ here).
  `rules` is a list of stored rule records.
  """
  def subscription_admits?([], _msg), do: true

  def subscription_admits?(rules, msg) do
    all_true? = Enum.all?(rules, &true_filter?(&1["properties"]))

    if all_true? do
      true
    else
      Enum.any?(rules, fn rule ->
        case compile(rule["properties"]) do
          {:ok, filter} -> filter_matches?(filter, msg)
          _ -> false
        end
      end)
    end
  end

  # --- Filter/action parsing ----------------------------------------------------------

  @doc """
  Parse a rule body's filter/action into a compiled filter.

  Returns `{:ok, filter}` or `{:error, code}` where code is
  `:invalid_filter` | `:invalid_action`.
  """
  def compile(props) when is_map(props) do
    props = unwrap_filter(props)

    with {:ok, filter} <- parse_filter(props),
         :ok <- parse_action(props) do
      {:ok, filter}
    end
  end

  # KD-143 adversarial leg: a partially-persisted rule record (properties
  # missing after a torn restore) must be a typed clean skip on the fan-out
  # path, never a FunctionClauseError crash. Fail-closed per the module doc:
  # malformed -> non-matching.
  def compile(_props), do: {:error, :invalid_filter, "non-map rule properties"}

  defp unwrap_filter(%{"filter" => f} = props) when is_map(f),
    do: Map.merge(props, f)

  defp unwrap_filter(props), do: props

  defp normalize_filter(props) do
    cond do
      sql = props["sqlExpression"] ->
        {:ok, {:sql, sql}}

      props["correlationId"] || props["properties"] || props["subject"] ||
        props["replyTo"] || props["to"] || props["sessionId"] ->
        {:ok, {:correlation, props}}

      props["trueFilter"] ->
        {:ok, {true, nil}}

      true ->
        {:ok, {true, nil}}
    end
  end

  defp parse_filter(props) do
    case normalize_filter(props) do
      {:ok, {true, _}} ->
        {:ok, {true, nil}}

      {:ok, {:correlation, corr}} ->
        {:ok, {:correlation, corr}}

      {:ok, {:sql, sql}} ->
        case parse_sql(sql) do
          {:ok, ast} -> {:ok, {:sql_ast, ast}}
          {:error, fragment} -> {:error, :invalid_filter, fragment}
        end
    end
  end

  defp parse_action(props) do
    case props["action"] do
      nil ->
        :ok

      %{"sqlExpression" => sql} when is_binary(sql) and sql != "" ->
        case parse_set_action(sql) do
          {:ok, _sets} -> :ok
          {:error, fragment} -> {:error, :invalid_action, fragment}
        end

      _ ->
        :ok
    end
  end

  # --- Correlation filter matching ------------------------------------------------

  defp filter_matches?({true, _}, _msg), do: true

  defp filter_matches?({:correlation, corr}, msg) do
    corr_id = corr["correlationId"]
    app = msg[:app_props] || %{}

    id_ok =
      is_nil(corr_id) or
        (is_binary(corr_id) and (msg[:message_id] == corr_id or app["correlation-id"] == corr_id))

    props_ok =
      case corr["properties"] do
        p when is_map(p) and p != %{} ->
          Enum.all?(p, fn {k, v} -> Map.get(app, k) == v end)

        _ ->
          true
      end

    subject_ok =
      case corr["subject"] do
        nil -> true
        s -> msg[:subject] == s or Map.get(app, "subject") == s
      end

    id_ok and props_ok and subject_ok
  end

  defp filter_matches?({:sql_ast, ast}, msg) do
    eval(ast, msg)
  end

  @doc "Test/inspection seam: evaluate a parsed SQL AST against a message map."
  def filter_matches_for_test?(ast, msg) do
    eval(ast, msg)
  end

  defp eval({:eq, path, lit}, msg) do
    case lookup(path, msg) do
      {:ok, v} -> values_equal?(v, lit)
      :missing -> false
    end
  end

  defp eval({:ne, path, lit}, msg) do
    case lookup(path, msg) do
      {:ok, v} -> not values_equal?(v, lit)
      :missing -> false
    end
  end

  defp eval({:exists, path}, msg), do: match?({:ok, _}, lookup(path, msg))

  defp eval({:and, a, b}, msg), do: eval(a, msg) and eval(b, msg)
  defp eval({:or, a, b}, msg), do: eval(a, msg) or eval(b, msg)

  defp lookup("sys.label", msg),
    do: if(is_nil(msg[:label]), do: :missing, else: {:ok, msg[:label]})

  defp lookup("sys." <> _rest, _msg), do: :missing

  defp lookup(path, msg) do
    app = msg[:app_props] || %{}

    cond do
      Map.has_key?(app, path) -> {:ok, Map.get(app, path)}
      Map.has_key?(app, to_string(path)) -> {:ok, Map.get(app, to_string(path))}
      true -> :missing
    end
  end

  defp values_equal?(v, v2) when is_number(v) and is_number(v2), do: v == v2
  defp values_equal?(v, v2) when is_binary(v) and is_binary(v2), do: v == v2
  defp values_equal?(v, v2) when is_boolean(v), do: v == v2
  defp values_equal?(_, _), do: false

  # --- SQL filter tokenizer/parser (80/20, fail-closed) -----------------------------

  @doc false
  def parse_sql(sql) when is_binary(sql) do
    case tokenize(String.trim(sql)) do
      {:ok, tokens} ->
        case parse_or(tokens) do
          {:ok, ast, []} -> {:ok, ast}
          {:ok, _ast, rest} -> {:error, "unexpected trailing input: " <> inspect(rest)}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp tokenize(""), do: {:ok, []}

  defp tokenize(sql) do
    chars = String.to_charlist(sql)

    case tokens(chars, []) do
      {:ok, toks} -> {:ok, Enum.reverse(toks)}
      {:error, _} = err -> err
    end
  end

  defp tokens([], acc), do: {:ok, acc}

  defp tokens([c | rest], acc) when c in [?\s, ?\t, ?\r, ?\n], do: tokens(rest, acc)

  defp tokens([?( | rest], acc), do: tokens(rest, [{:lparen, "("} | acc])
  defp tokens([?) | rest], acc), do: tokens(rest, [{:rparen, ")"} | acc])

  defp tokens([?' | rest], acc) do
    case string_lit(rest, []) do
      {:ok, s, rest2} -> tokens(rest2, [{:lit, s} | acc])
      {:error, _} = err -> err
    end
  end

  defp tokens([c | rest], acc) when c in ?0..?9 or c == ?- do
    case number_lit([c | rest], []) do
      {:ok, n, rest2} -> tokens(rest2, [{:lit, n} | acc])
      {:error, _} = err -> err
    end
  end

  defp tokens([c | rest], acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest2} = ident([c | rest], [])
    down = String.downcase(word)

    cond do
      down == "and" -> tokens(rest2, [{:and_kw, word} | acc])
      down == "or" -> tokens(rest2, [{:or_kw, word} | acc])
      down == "exists" -> tokens(rest2, [{:exists_kw, word} | acc])
      true -> tokens(rest2, [{:ident, word} | acc])
    end
  end

  # '=' and '!='
  defp tokens([?= | rest], acc), do: tokens(rest, [{:op, "="} | acc])

  defp tokens([?! | rest], acc) do
    case rest do
      [?= | rest2] -> tokens(rest2, [{:op, "!="} | acc])
      _ -> {:error, "expected '=' after '!'"}
    end
  end

  defp tokens([c | _], _acc), do: {:error, "unsupported filter character: <<#{c}>>"}

  defp string_lit([?' | rest], acc) do
    case rest do
      [?' | rest2] -> string_lit(rest2, [?' | acc])
      _ -> {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}
    end
  end

  defp string_lit([], _acc), do: {:error, "unterminated string literal"}

  defp string_lit([c | rest], acc), do: string_lit(rest, [c | acc])

  defp number_lit(rest, acc) do
    {digits, rest2} = Enum.split_while(rest, fn c -> c in ?0..?9 or c == ?. end)
    text = IO.iodata_to_binary(acc ++ digits)

    if text == "" or text == "-" do
      {:error, "invalid numeric literal"}
    else
      n =
        if String.contains?(text, ".") do
          {f, _} = Float.parse(text)
          f
        else
          {i, _} = Integer.parse(text)
          i
        end

      {:ok, n, rest2}
    end
  end

  defp ident(rest, acc) do
    case rest do
      [c | r] when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c == ?. ->
        ident(r, [c | acc])

      _ ->
        {IO.iodata_to_binary(Enum.reverse(acc)), rest}
    end
  end

  # expr := and_expr (OR and_expr)*
  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      case rest do
        [{:or_kw, _} | rest2] ->
          with {:ok, right, rest3} <- parse_and(rest2) do
            {:ok, {:or, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  # and_expr := primary (AND primary)*
  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_primary(tokens) do
      case rest do
        [{:and_kw, _} | rest2] ->
          with {:ok, right, rest3} <- parse_primary(rest2) do
            {:ok, {:and, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_primary([{:lparen, _} | rest]) do
    with {:ok, inner, rest2} <- parse_or(rest) do
      case rest2 do
        [{:rparen, _} | rest3] -> {:ok, inner, rest3}
        _ -> {:error, "expected ')'"}
      end
    end
  end

  defp parse_primary([{:exists_kw, _}, {:lparen, _} | rest]) do
    case parse_primary([{:lparen, "("} | rest]) do
      {:ok, {:eq, path, _}, rest2} -> {:ok, {:exists, path}, rest2}
      {:ok, {:ne, path, _}, rest2} -> {:ok, {:exists, path}, rest2}
      {:ok, {:ident_only, path}, rest2} -> {:ok, {:exists, path}, rest2}
      _ -> {:error, "EXISTS requires a property reference"}
    end
  end

  defp parse_primary([{:ident, name} | rest]) do
    case rest do
      [{:op, "="} | [{:lit, lit} | rest2]] -> {:ok, {:eq, name, lit}, rest2}
      [{:op, "!="} | [{:lit, lit} | rest2]] -> {:ok, {:ne, name, lit}, rest2}
      [] -> {:ok, {:ident_only, name}, []}
      [{:rparen, _} | _] = r -> {:ok, {:ident_only, name}, r}
      _ -> {:error, "unsupported filter construct near: #{name}"}
    end
  end

  defp parse_primary(_), do: {:error, "unsupported or malformed filter expression"}

  # --- Actions: SET ident = literal [, ident = literal]* ----------------------------

  @doc false
  def parse_set_action(sql) when is_binary(sql) do
    trimmed = String.trim(sql)

    with {:ok, body} <- strip_set(trimmed),
         {:ok, sets} <- parse_set_list(body) do
      {:ok, sets}
    end
  end

  defp strip_set(sql) do
    case Regex.run(~r/^SET\s+(.+)$/i, sql) do
      [_, body] -> {:ok, body}
      nil -> {:error, "unsupported action (only SET assignments are supported): " <> sql}
    end
  end

  defp parse_set_list(body) do
    parts = split_top_commas(body)

    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case Regex.run(~r/^\s*([\w.]+)\s*=\s*('.*?'|-?\d+(\.\d+)?)\s*$/, part) do
        [_, name, lit] -> {:cont, {:ok, [{name, unquote_lit(lit)} | acc]}}
        nil -> {:halt, {:error, "unsupported action construct near: " <> part}}
      end
    end)
  end

  defp split_top_commas(body) do
    # String literals in this 80/20 grammar cannot contain commas, so a naive
    # split is exact for the supported subset (and anything the split mangles
    # is refused by the per-part regex, fail-closed).
    body
    |> String.split(",")
    |> Enum.reject(&(&1 == ""))
  end

  defp unquote_lit("'" <> rest) do
    lit = String.trim_trailing(rest, "'")
    lit
  end

  defp unquote_lit(lit) do
    case Integer.parse(lit) do
      {n, ""} ->
        n

      _ ->
        {f, _} = Float.parse(lit)
        f
    end
  end

  # --- Action application ----------------------------------------------------------

  @doc """
  Apply a rule's SET action to a message map (keys :app_props / :label).
  Only SET overrides; anything else is a no-op here (already refused at
  rule-create time).
  """
  def apply_action(nil, msg), do: msg

  def apply_action(props, msg) when is_map(props) do
    case props["action"] do
      %{"sqlExpression" => sql} when is_binary(sql) and sql != "" ->
        case parse_set_action(sql) do
          {:ok, sets} -> Enum.reduce(sets, msg, fn {k, v}, m -> set_path(k, v, m) end)
          _ -> msg
        end

      _ ->
        msg
    end
  end

  defp set_path("sys.label", v, msg) do
    # QueueStore carries no dedicated label column in the 80/20; the Label
    # system property rides application properties on delivered messages.
    Map.update(msg, :app_props, %{"label" => v}, fn app -> Map.put(app, "label", v) end)
  end

  defp set_path(path, v, msg) do
    Map.update(msg, :app_props, %{path => v}, fn app -> Map.put(app, path, v) end)
  end

  # --- Delivery fan-out ------------------------------------------------------------

  @doc """
  Fan a message out to a topic's subscriptions: for each subscription, apply
  its rules; matching (or default) subscriptions get the message enqueued into
  the subscription's queue in `Smalt.Amqp.QueueStore` under
  `"<topic>/subscriptions/<sub>"`. Returns the list of subscription names the
  message was delivered to.
  """
  def fan_out(sub_base, ns, topic, msg) do
    subs_prefix =
      String.downcase("#{sub_base}/namespaces/#{ns}/topics/#{topic}/subscriptions/")

    # Subscriptions are ARM resources (:smalt_resources); rules live in
    # :smalt_sb_rules — two different tables, never one `store` param.
    subs = Smalt.Store.list_prefix(:smalt_resources, subs_prefix)

    Enum.flat_map(subs, fn sub_record ->
      sub_name = sub_record["name"]
      rules_prefix = subs_prefix <> String.downcase(sub_name) <> "/rules/"

      rules = Smalt.Store.list_prefix(:smalt_sb_rules, rules_prefix)

      if subscription_admits?(rules, msg) do
        msg2 = apply_first_action(rules, msg)

        queue = "#{topic}/subscriptions/#{sub_name}"

        # KD-86: the subscription fan-out target is an internal emulator seam
        # (ARM-materialized, possibly different casing) — materialize before
        # enqueue so the KD-86 send-path gate doesn't drop rule deliveries.
        Smalt.Amqp.QueueStore.ensure_queue(queue)

        {:ok, _seq} =
          Smalt.Amqp.QueueStore.enqueue(queue, msg[:body] || "",
            message_id: msg[:message_id],
            app_props: msg2[:app_props] || %{}
          )

        [sub_name]
      else
        []
      end
    end)
  end

  defp apply_first_action(rules, msg) do
    Enum.find_value(rules, msg, fn rule ->
      props = rule["properties"]

      if props && props["action"] &&
           match?(%{"sqlExpression" => sql} when is_binary(sql) and sql != "", props["action"]) do
        apply_action(props, msg)
      else
        nil
      end
    end)
  end
end
