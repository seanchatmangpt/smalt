defmodule Smalt.Amqp.ManagementRpc.Rules do
  @moduledoc """
  `com.microsoft:add-rule` / `remove-rule` / `enumerate-rules` (w6m) —
  extracted verbatim from the pre-split `Smalt.Amqp.ManagementRpc` monolith
  (tail-splits ticket T10); bodies byte-identical, `defp` promoted to `def`
  on the handler entries only.
  """

  alias Smalt.Amqp.ManagementRpc.Shared
  alias Smalt.Amqp.RuleStore

  # The entity rides the $management node address: the SDK opens
  # "<topic>/Subscriptions/<sub>/$management" (managementClient.js toPath) so
  # request[:queue] arrives as the subscription path. addRule sends body
  # {"rule-name": wrap_string, "rule-description": wrap_map} where the map is
  # {"sql-filter": {"expression": s}} or {"correlation-filter": {..}}; the
  # optional "sql-rule-action": {"expression": s} is stored and echoed on
  # enumerate, never evaluated (documented subset).
  def add(body, queue_from_request, correlation_id, _context, _now) do
    entity = Shared.bare_entity(Shared.body_field(body, "queue") || queue_from_request)
    name = Shared.body_field(body, "rule-name")
    desc = Shared.body_field(body, "rule-description")

    cond do
      Shared.blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        Shared.respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      Shared.blank?(name) ->
        Shared.respond(400, "RULE_NAME_REQUIRED", nil, correlation_id)

      not is_map(desc) ->
        Shared.respond(400, "RULE_DESCRIPTION_REQUIRED", nil, correlation_id)

      true ->
        filter = parse_rule_filter(desc)

        if filter == :error do
          Shared.respond(400, "RULE_FILTER_INVALID", nil, correlation_id)
        else
          {topic, sub} = RuleStore.split_sub_path(entity)
          action = rule_action(desc)

          case RuleStore.add_rule(topic, sub, name, filter, action) do
            {:ok, _rule} -> Shared.respond(200, "OK", nil, correlation_id)
            {:error, :bad_filter} -> Shared.respond(400, "RULE_FILTER_INVALID", nil, correlation_id)
            _other -> Shared.respond(409, "RULE_ALREADY_EXISTS", nil, correlation_id)
          end
        end
    end
  end

  defp parse_rule_filter(%{"sql-filter" => %{"expression" => expr}}) when is_binary(expr) do
    down = String.downcase(expr)

    cond do
      down == "1=1" -> :true
      down == "1=0" -> :false
      true -> {:sql, expr}
    end
  end

  defp parse_rule_filter(%{"sql-filter" => %{expression: expr}}) when is_binary(expr),
    do: parse_rule_filter(%{"sql-filter" => %{"expression" => expr}})

  defp parse_rule_filter(%{"correlation-filter" => corr}) when is_map(corr),
    do: {:correlation, corr}

  defp parse_rule_filter(_), do: :error

  defp rule_action(desc) do
    case desc["sql-rule-action"] do
      %{"expression" => expr} when is_binary(expr) -> expr
      %{expression: expr} when is_binary(expr) -> expr
      _ -> nil
    end
  end

  def remove(body, queue_from_request, correlation_id, _context, _now) do
    entity = Shared.bare_entity(Shared.body_field(body, "queue") || queue_from_request)
    name = Shared.body_field(body, "rule-name")

    cond do
      Shared.blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        Shared.respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      Shared.blank?(name) ->
        Shared.respond(400, "RULE_NAME_REQUIRED", nil, correlation_id)

      true ->
        {topic, sub} = RuleStore.split_sub_path(entity)

        case RuleStore.remove_rule(topic, sub, name) do
          :ok -> Shared.respond(200, "OK", nil, correlation_id)
          {:error, :not_found} -> Shared.respond(404, "RULE_NOT_FOUND", nil, correlation_id)
          _other -> Shared.respond(404, "RULE_NOT_FOUND", nil, correlation_id)
        end
    end
  end

  # enumerate-rules body: {top, skip} wrapped ints; reply {"rules": [...]}.
  # Each entry is {"rule-name": str, "rule-description": described}; the SDK
  # skips any entry whose rule-description lacks the expected descriptor, so
  # the described wire form is load-bearing (RuleStore.wire_description/1).
  def enumerate(body, queue_from_request, correlation_id, _context, _now) do
    entity = Shared.bare_entity(Shared.body_field(body, "queue") || queue_from_request)

    skip = Shared.coerce_long(Shared.fetch_or(body, "skip", 0))
    top = Shared.coerce_long(Shared.fetch_or(body, "top", 100))

    cond do
      Shared.blank?(entity) or is_nil(RuleStore.split_sub_path(entity)) ->
        Shared.respond(400, "SUBSCRIPTION_PATH_REQUIRED", nil, correlation_id)

      skip == :error or not is_integer(skip) or skip < 0 ->
        Shared.respond(400, "RULE_PAGING_BOUNDS", nil, correlation_id)

      top == :error or not is_integer(top) or top < 1 ->
        Shared.respond(400, "RULE_PAGING_BOUNDS", nil, correlation_id)

      true ->
        {topic, sub} = RuleStore.split_sub_path(entity)
        {:ok, rules} = RuleStore.list_rules(topic, sub)

        entries =
          rules
          |> Enum.drop(skip)
          |> Enum.take(top)
          |> Enum.map(&RuleStore.wire_description/1)

        Shared.respond(200, "OK", %{"rules" => entries}, correlation_id)
    end
  end
end
