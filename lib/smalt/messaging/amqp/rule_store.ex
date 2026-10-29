defmodule Smalt.Amqp.RuleStore do
  @moduledoc """
  Topic-subscription RULES (lane w6m, v26.10.20): SQL filter subset +
  correlation filter, stored per `{topic, sub}` in `:smalt_sb_rules` and
  enforced on the topic fan-out path in `Smalt.Amqp.QueueStore` — a rule
  that excludes must NOT deliver (true Chicago: the gate is the delivery
  path, not the test).

  Wire dialect (measured against @azure/service-bus 7.10.0
  managementClient.js + rhea decode behavior):

    * add-rule      — body {"rule-name": str, "rule-description": map} where
                      the map carries "sql-filter": {"expression": s} or
                      "correlation-filter": {..} (rhea wrap_map decodes to a
                      plain map; no described types on the request side).
    * remove-rule   — body {"rule-name": str}.
    * enumerate-rules — reply {"rules": [map]} where each map is
                        {"rule-name": str, "rule-description": described}
                        with ulong descriptors (ruleDescriptionList
                        1335734829060 wrapping [filter, action, name]); the
                        SDK reads `.descriptor.value` and `.value` on these,
                        and rhea leaves described values NESTED IN LISTS as
                        Typed objects so descriptors survive the decode.

  Store: `:smalt_sb_rules` ETS, key `{topic, sub, rule_name}`, created
  lazily by this module's own lazily-started named GenServer with a 3-tuple
  heir to the kernel `:init` process (house shadow-table law).

  SQL subset: predicates on `sys.messageId`, `sys.sessionId`, `sys.label`,
  `sys.correlationId` and bare application property identifiers; ops
  `= <> != > < >= <=`; string literals 'x', integers, floats; joined by
  top-level `AND`/`OR` (OR loosest; quoted literals may not contain the
  words and/or). `1=1` / `1=0` evaluate naturally as literal predicates.
  A predicate on a missing property is FALSE; a malformed expression is
  FALSE — fan-out never crashes on a stored filter.
  """

  use GenServer

  @table :smalt_sb_rules

  # Microsoft rule descriptor codes (@azure/core-amqp Constants.descriptorCodes).
  @rule_desc 1_335_734_829_060
  @sql_filter_list 83_483_426_822
  @true_filter_list 83_483_426_823
  @false_filter_list 83_483_426_824
  @corr_filter_list 83_483_426_825
  @sql_action_list 1_335_734_829_062

  # -- Rule CRUD ----------------------------------------------------------------

  @doc """
  Add (or replace) a rule. `filter` is `{:sql, expr}` | `{:correlation, map}` |
  `:true` | `:false`; `action` is a stored binary or nil (echoed on
  enumerate, never evaluated).
  """
  @spec add_rule(String.t(), String.t(), String.t(), term(), String.t() | nil) ::
          {:ok, map()} | {:error, :bad_filter}
  def add_rule(topic, sub, name, filter, action \\ nil)
      when is_binary(topic) and is_binary(sub) and is_binary(name) do
    if valid_filter?(filter) do
      GenServer.call(server(), {:add_rule, topic, sub, name, filter, action})
    else
      {:error, :bad_filter}
    end
  end

  @doc "Remove a rule; `{:error, :not_found}` when absent."
  @spec remove_rule(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_rule(topic, sub, name) do
    GenServer.call(server(), {:remove_rule, topic, sub, name})
  end

  @doc "List rules for {topic, sub}, name-ordered. `[]` = implicit $Default."
  @spec list_rules(String.t(), String.t()) :: {:ok, [map()]}
  def list_rules(topic, sub) do
    ensure()

    {:ok,
     @table
     |> :ets.match_object({{topic, sub, :_}, :_})
     |> Enum.map(fn {_, rule} -> rule end)
     |> Enum.sort_by(& &1.name)}
  end

  @doc """
  Fan-out gate: does the message (fan-out opts) match ANY rule on the
  subscription addressed as `"topic/Subscriptions/<sub>"`? Empty rule set =
  implicit $Default = always true.
  """
  @spec rules_match?(String.t(), keyword()) :: boolean()
  def rules_match?(sub_path, opts) when is_binary(sub_path) do
    case split_sub_path(sub_path) do
      {topic, sub} ->
        case list_rules(topic, sub) do
          {:ok, []} -> true
          {:ok, rules} -> Enum.any?(rules, &rule_matches?(&1, opts))
        end

      nil ->
        true
    end
  end

  # -- Wire description (enumerate-rules reply) ----------------------------------

  @doc """
  Wire form for the enumerate-rules reply: the SDK parses
  `ruleDescriptor.descriptor.value` and array elements' `.value`, so filter,
  action and name ride as described types (ulong/symbol descriptors).
  """
  @spec wire_description(map()) :: map()
  def wire_description(rule) do
    %{
      "rule-name" => rule.name,
      "rule-description" =>
        {:described, @rule_desc,
         [
           filter_wire(rule.filter),
           action_wire(rule[:action]),
           {:described, {:symbol, "com.microsoft:rule-name:string"}, rule.name}
         ]}
    }
  end

  defp filter_wire({:sql, expr}), do: {:described, @sql_filter_list, [expr]}
  defp filter_wire(:true), do: {:described, @true_filter_list, []}
  defp filter_wire(:false), do: {:described, @false_filter_list, []}

  defp filter_wire({:correlation, corr}) do
    {:described, @corr_filter_list,
     [
       corr["correlation-id"],
       corr["message-id"],
       corr["to"],
       corr["reply-to"],
       corr["label"],
       corr["session-id"],
       corr["reply-to-session-id"],
       corr["content-type"],
       corr_elem(corr["properties"])
     ]}
  end

  defp corr_elem(nil), do: nil

  defp corr_elem(props) when is_map(props),
    do: {:described, {:symbol, "amqp:application-properties:map"}, props}

  defp action_wire(nil), do: {:described, @sql_action_list, []}

  defp action_wire(expr) when is_binary(expr) do
    {:described, @sql_action_list,
     [{:described, {:symbol, "com.microsoft:action:string"}, expr}]}
  end

  # -- Matching ----------------------------------------------------------------

  defp rule_matches?(%{filter: {:sql, expr}}, opts) do
    sql_match?(expr, %{
      "sys.messageid" => opts[:message_id],
      "sys.sessionid" => opts[:session_id],
      "sys.label" => opts[:app_props]["subject"],
      "sys.correlationid" => opts[:app_props]["correlation-id"],
      "props" => opts[:app_props] || %{}
    })
  end

  defp rule_matches?(%{filter: :true}, _opts), do: true
  defp rule_matches?(%{filter: :false}, _opts), do: false

  defp rule_matches?(%{filter: {:correlation, corr}}, opts) do
    props = opts[:app_props] || %{}

    fields_all_match?(
      [
        {"message-id", opts[:message_id]},
        {"session-id", opts[:session_id]},
        {"correlation-id", props["correlation-id"]},
        {"label", props["subject"]},
        {"to", props["to"]},
        {"reply-to", props["reply-to"]},
        {"content-type", props["content-type"]}
      ],
      corr
    ) and props_match?(corr["properties"], props)
  end

  defp fields_all_match?(fields, corr) do
    Enum.all?(fields, fn {wire, value} ->
      case corr[wire] do
        nil -> true
        v -> v == value
      end
    end)
  end

  defp props_match?(nil, _props), do: true

  defp props_match?(corr_props, props) when is_map(corr_props) and is_map(props) do
    Enum.all?(corr_props, fn {k, v} -> props[k] == v end)
  end

  defp props_match?(_, _), do: false

  # -- SQL filter evaluation (subset) --------------------------------------------

  @doc "Evaluate a SQL filter expression against a context map (witness tier entry)."
  @spec sql_match?(String.t(), map()) :: boolean()
  def sql_match?(expr, ctx) when is_binary(expr) do
    case extract_literals(expr) do
      {stripped, lits} ->
        stripped
        |> String.split(~r/\bor\b/i)
        |> Enum.any?(fn arm ->
          arm
          |> String.split(~r/\band\b/i)
          |> Enum.all?(&eval_predicate(String.trim(&1), lits, ctx) == true)
        end)

      :error ->
        false
    end
  end

  def sql_match?(_expr, _ctx), do: false

  # 'x' literals -> \x00N placeholders so and/or inside quotes never split.
  defp extract_literals(bin), do: extract_literals(bin, {"", []})

  defp extract_literals(bin, {prefix, lits}) do
    case :binary.split(bin, "'") do
      [rest] ->
        {prefix <> rest, Enum.reverse(lits)}

      [before, rest] ->
        case :binary.split(rest, "'") do
          [lit, rest2] ->
            placeholder = "\x00" <> Integer.to_string(length(lits))
            extract_literals(rest2, {prefix <> before <> placeholder, [lit | lits]})

          _ ->
            :error
        end
    end
  end

  @pred_re ~r/^[\s]*([\w.]+)\s*(>=|<=|<>|!=|=|>|<)\s*([\w.\x00\-]+)[\s]*$/

  defp eval_predicate(pred, lits, ctx) do
    case Regex.run(@pred_re, pred, capture: :all_names) do
      [lhs, op, rhs] ->
        compare(resolve(lhs, lits, ctx), op, resolve(rhs, lits, ctx))

      [] ->
        false
    end
  end

  # resolve a token: placeholder -> literal string; number -> number;
  # sys.* / bare ident -> context lookup (missing = nil).
  defp resolve(token, lits, ctx) do
    cond do
      String.contains?(token, "\x00") ->
        idx = String.replace(token, "\x00", "")

        case Integer.parse(idx) do
          {n, ""} -> Enum.at(lits, n)
          _ -> nil
        end

      Regex.match?(~r/^-?\d+$/, token) ->
        String.to_integer(token)

      Regex.match?(~r/^-?\d+\.\d+$/, token) ->
        String.to_float(token)

      true ->
        case token do
          "sys.messageid" -> ctx["sys.messageid"]
          "sys.sessionid" -> ctx["sys.sessionid"]
          "sys.label" -> ctx["sys.label"]
          "sys.correlationid" -> ctx["sys.correlationid"]
          _ -> ctx["props"][token]
        end
    end
  end

  defp compare(nil, _op, _rhs), do: false

  defp compare(lhs, op, rhs) do
    {a, b} = coerce_pair(lhs, rhs)

    cond do
      is_number(a) and is_number(b) -> num_cmp(a, op, b)
      true -> str_cmp(to_string(a), op, to_string(b))
    end
  end

  defp coerce_pair(a, b) do
    cond do
      is_number(a) and is_binary(b) -> {a, parse_num(b, a)}
      is_number(b) and is_binary(a) -> {parse_num(a, b), b}
      true -> {a, b}
    end
  end

  defp parse_num(bin, other) do
    cond do
      Regex.match?(~r/^-?\d+$/, bin) -> String.to_integer(bin)
      Regex.match?(~r/^-?\d+\.\d+$/, bin) -> String.to_float(bin)
      true -> other
    end
  end

  defp num_cmp(a, "=", b), do: a == b
  defp num_cmp(a, "!=", b), do: a != b
  defp num_cmp(a, "<>", b), do: a != b
  defp num_cmp(a, ">", b), do: a > b
  defp num_cmp(a, "<", b), do: a < b
  defp num_cmp(a, ">=", b), do: a >= b
  defp num_cmp(a, "<=", b), do: a <= b

  defp str_cmp(a, "=", b), do: a == b
  defp str_cmp(a, "!=", b), do: a != b
  defp str_cmp(a, "<>", b), do: a != b
  defp str_cmp(a, ">", b), do: a > b
  defp str_cmp(a, "<", b), do: a < b
  defp str_cmp(a, ">=", b), do: a >= b
  defp str_cmp(a, "<=", b), do: a <= b

  # -- Path helpers --------------------------------------------------------------

  @doc false
  def split_sub_path(sub_path) do
    case :binary.split(sub_path, "/Subscriptions/") do
      [topic, sub] when topic != "" and sub != "" -> {topic, sub}
      _ -> nil
    end
  end

  defp valid_filter?({:sql, expr}) when is_binary(expr), do: true
  defp valid_filter?(:true), do: true
  defp valid_filter?(:false), do: true
  defp valid_filter?({:correlation, m}) when is_map(m), do: true
  defp valid_filter?(_), do: false

  # -- GenServer (serialized add/remove) ------------------------------------------

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end

  @doc "Start the serialized rule server (idempotent, lazily used)."
  def start_link(opts \\ []) do
    _ = opts
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  defp server do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case start_link() do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @impl true
  def init(:ok) do
    if :ets.info(@table) == :undefined do
      # 3-tuple heir to the kernel :init process: the rule table survives a
      # server crash (shadow-table law) instead of vanishing with its owner.
      :ets.new(@table, [:set, :named_table, :public, {:heir, Process.whereis(:init), []}])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_rule, topic, sub, name, filter, action}, _from, state) do
    ensure()

    rule = %{name: name, filter: filter, action: action, topic: topic, sub: sub}
    :ets.insert(@table, {{topic, sub, name}, rule})
    {:reply, {:ok, rule}, state}
  end

  def handle_call({:remove_rule, topic, sub, name}, _from, state) do
    ensure()

    case :ets.lookup(@table, {topic, sub, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      _ ->
        :ets.delete(@table, {topic, sub, name})
        {:reply, :ok, state}
    end
  end

  defp ensure do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public, {:heir, Process.whereis(:init), []}])
    end

    :ok
  end
end
