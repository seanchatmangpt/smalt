defmodule Smalt.Mcp.Tool.ServiceBus do
  @moduledoc """
  MCP Service Bus read family: `sb.peek`, `sb.topics.list`,
  `sb.topics.subscriptions`, `sb.rules.list`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"

  def input_schema("sb.peek") do
    %{
      "type" => "object",
      "required" => ["queue"],
      "properties" => %{
        "queue" => %{"type" => "string"},
        "message_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
      }
    }
  end

  def input_schema("sb.topics.list") do
    %{
      "type" => "object",
      "properties" => %{
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  def input_schema("sb.topics.subscriptions") do
    %{
      "type" => "object",
      "required" => ["topic"],
      "properties" => %{
        "topic" => %{"type" => "string", "description" => "topic name"},
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  def input_schema("sb.rules.list") do
    %{
      "type" => "object",
      "required" => ["topic", "subscription"],
      "properties" => %{
        "topic" => %{"type" => "string", "description" => "topic name"},
        "subscription" => %{"type" => "string", "description" => "subscription name"},
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("sb.peek", args) do
    case args do
      %{"queue" => queue} when is_binary(queue) ->
        with {:ok, mc} <- message_count_arg(args["message_count"]),
             {:ok, messages} <-
               Smalt.Amqp.QueueStore.peek(queue, message_count: mc) do
          {:ok, %{"queue" => queue, "messages" => messages, "count" => length(messages)}}
        else
          :error ->
            {:refusal, @invalid_params_code,
             "refused: sb.peek message_count must be an integer between 1 and 100"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.peek requires queue"}
    end
  end

  def invoke("sb.topics.list", args) do
    ns = args["namespace"]

    if ns != nil and not is_binary(ns) do
      {:refusal, @invalid_params_code, "refused: sb.topics.list namespace must be a string"}
    else
      topics =
        :smalt_resources
        |> Smalt.Store.list()
        |> Enum.filter(&(&1["type"] == "Microsoft.ServiceBus/namespaces/topics"))
        |> Enum.filter(fn rec ->
          case ns do
            nil -> true
            ^ns -> true
            _ -> String.contains?(rec["id"] || "", "/namespaces/#{ns}/topics/")
          end
        end)
        |> Enum.sort_by(&String.downcase(&1["id"] || ""))
        |> Enum.map(&%{"id" => &1["id"], "name" => &1["name"], "properties" => &1["properties"]})

      {:ok, %{"topics" => topics, "count" => length(topics)}}
    end
  end

  def invoke("sb.topics.subscriptions", args) do
    case args do
      %{"topic" => topic} when is_binary(topic) ->
        ns = args["namespace"]

        if ns != nil and not is_binary(ns) do
          {:refusal, @invalid_params_code,
           "refused: sb.topics.subscriptions namespace must be a string"}
        else
          subs =
            :smalt_resources
            |> Smalt.Store.list()
            |> Enum.filter(
              &(&1["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions")
            )
            |> Enum.filter(fn rec ->
              id = rec["id"] || ""

              String.contains?(id, "/topics/#{topic}/subscriptions/") and
                case ns do
                  nil -> true
                  _ -> String.contains?(id, "/namespaces/#{ns}/topics/")
                end
            end)
            |> Enum.sort_by(&String.downcase(&1["id"] || ""))
            |> Enum.map(
              &%{"id" => &1["id"], "name" => &1["name"], "properties" => &1["properties"]}
            )

          {:ok, %{"topic" => topic, "subscriptions" => subs, "count" => length(subs)}}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.topics.subscriptions requires topic"}
    end
  end

  def invoke("sb.rules.list", args) do
    case args do
      %{"topic" => topic, "subscription" => sub} when is_binary(topic) and is_binary(sub) ->
        ns = args["namespace"]

        if ns != nil and not is_binary(ns) do
          {:refusal, @invalid_params_code, "refused: sb.rules.list namespace must be a string"}
        else
          # Rules live in :smalt_sb_rules keyed by the downcased full ARM rule
          # scope ("<base>/namespaces/<ns>/topics/<topic>/subscriptions/<sub>/rules/<rule>"),
          # the same key contract Smalt.SbRules.fan_out/4 reads. Suffix
          # contains-match, so any resource-group/subscription base works.
          suffix = "/topics/#{topic}/subscriptions/#{sub}/rules/"

          rules =
            :smalt_sb_rules
            |> Smalt.Store.keys()
            |> Enum.filter(fn key -> is_binary(key) end)
            |> Enum.filter(fn key ->
              String.contains?(key, String.downcase(suffix)) and
                case ns do
                  nil -> true
                  _ -> String.contains?(key, "/namespaces/#{ns}/topics/")
                end
            end)
            |> Enum.sort()
            |> Enum.flat_map(fn key ->
              case Smalt.Store.get(:smalt_sb_rules, key) do
                {:ok, rec} -> [Map.put(rec, "name", key |> String.split("/") |> List.last())]
                _ -> []
              end
            end)

          {:ok,
           %{
             "topic" => topic,
             "subscription" => sub,
             "rules" => rules,
             "count" => length(rules)
           }}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.rules.list requires topic and subscription"}
    end
  end

  def invoke(_other, _args), do: nil

  # message_count is schema-bounded (integer 1..100): out-of-schema values are
  # refused at dispatch, never forwarded to the substrate's silent clamp.
  defp message_count_arg(nil), do: {:ok, 10}

  defp message_count_arg(n) when is_integer(n) and n >= 1 and n <= 100, do: {:ok, n}
  defp message_count_arg(_), do: :error
end
