defmodule Smalt.Mcp.Tool.Eventing do
  @moduledoc """
  MCP eventing read family: the Event Grid reads `eventgrid.topics.list`,
  `eventgrid.subscriptions.list`, `eventgrid.events.recent`, the Event Hubs
  reads `eh.consumergroups.list` and `eh.geo-dr.aliases`, and the Event
  Hubs Schema Registry read `eg.schemaregistry.groups`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @internal_code "MCP_INTERNAL"

  def input_schema("eventgrid.topics.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription_id" =>
          %{"type" => "string", "default" => Smalt.Mcp.Tool.Shared.default_subscription()},
        "resource_group" => %{"type" => "string"}
      }
    }
  end

  def input_schema("eventgrid.subscriptions.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription_id" =>
          %{"type" => "string", "default" => Smalt.Mcp.Tool.Shared.default_subscription()},
        "topic" => %{"type" => "string", "description" => "optional topic or system topic name"}
      }
    }
  end

  def input_schema("eventgrid.events.recent"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("eh.consumergroups.list") do
    %{
      "type" => "object",
      "required" => ["hub"],
      "properties" => %{
        "hub" => %{"type" => "string", "description" => "Event Hub name"}
      }
    }
  end

  def input_schema("eh.geo-dr.aliases"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("eg.schemaregistry.groups"), do: %{"type" => "object", "properties" => %{}}

  def input_schema(_other), do: nil

  # T-03 (v26.10.28): Event Grid read tools — registry scans over the ARM
  # store (same source arm.get reads) and the event store, all read-only.
  def invoke("eventgrid.topics.list", args) do
    sub = Map.get(args, "subscription_id", Smalt.Mcp.Tool.Shared.default_subscription())

    rows =
      eg_scan(String.downcase("/subscriptions/#{sub}/"), args["resource_group"])
      |> Enum.filter(
        &eg_id_matches?(&1, [
          "/providers/microsoft.eventgrid/topics/",
          "/providers/microsoft.eventgrid/systemtopics/"
        ])
      )
      |> Enum.take(100)

    {:ok, %{"topics" => rows, "count" => length(rows)}}
  end

  def invoke("eventgrid.subscriptions.list", args) do
    sub = Map.get(args, "subscription_id", Smalt.Mcp.Tool.Shared.default_subscription())

    rows =
      eg_scan(String.downcase("/subscriptions/#{sub}/"), nil)
      |> Enum.filter(&eg_id_matches?(&1, ["/eventsubscriptions/"]))
      |> then(fn rs ->
        case args["topic"] do
          t when is_binary(t) and t != "" ->
            marker = "/#{String.downcase(t)}/"
            Enum.filter(rs, fn r -> String.contains?(eg_id(r), marker) end)

          _ ->
            rs
        end
      end)
      |> Enum.take(100)

    {:ok, %{"subscriptions" => rows, "count" => length(rows)}}
  end

  def invoke("eventgrid.events.recent", _args) do
    rows =
      case :ets.info(:smalt_event_messages) do
        :undefined -> []
        _ -> Smalt.Store.list_prefix(:smalt_event_messages, "")
      end
      |> Enum.filter(&is_map/1)
      |> Enum.take(-25)
      |> Enum.map(fn r ->
        r
        |> Map.take(["id", "eventType", "eventTime", "subject", "topic", "type", "data"])
        |> Map.put_new("raw_kind", "map")
      end)

    {:ok, %{"events" => rows, "count" => length(rows)}}
  end

  def invoke("eh.consumergroups.list", args) do
    case args do
      %{"hub" => hub} when is_binary(hub) ->
        groups = Smalt.Messaging.EventHubs.list_consumer_groups(hub)

        {:ok, %{"hub" => hub, "consumer_groups" => groups, "count" => length(groups)}}

      _ ->
        {:refusal, "INVALID_PARAMS", "refused: eh.consumergroups.list requires hub"}
    end
  end

  # Read-only geo-DR ALIAS list: metadata-plane records only (alias name,
  # primary/partner namespace ids, role_by_ns roles, provisioning state,
  # commit timestamps). The geo-DR module's mutations (failover, break-pairing)
  # stay off the MCP surface — this reads the same table they actuate on.
  def invoke("eh.geo-dr.aliases", _args) do
    case Smalt.Messaging.EhGeoDr.list_aliases() do
      recs when is_list(recs) ->
        {:ok, %{"aliases" => recs, "count" => length(recs)}}

      other ->
        {:refusal, @internal_code, "eh.geo-dr.aliases unexpected: #{inspect(other)}"}
    end
  end

  def invoke("eg.schemaregistry.groups", _args) do
    case Smalt.Messaging.EhSchemaRegistry.list_groups() do
      groups when is_list(groups) ->
        {:ok, %{"groups" => groups, "count" => length(groups)}}

      other ->
        {:refusal, @internal_code, "eg.schemaregistry.groups unexpected: #{inspect(other)}"}
    end
  end

  def invoke(_other, _args), do: nil

  defp eg_scan(sub_prefix, resource_group) do
    prefix =
      case resource_group do
        rg when is_binary(rg) and rg != "" ->
          sub_prefix <> "resourcegroups/#{String.downcase(rg)}/"

        _ ->
          sub_prefix
      end

    case :ets.info(:smalt_resources) do
      :undefined -> []
      _ -> Smalt.Store.list_prefix(:smalt_resources, prefix) |> Enum.filter(&is_map/1)
    end
  end

  defp eg_id(row), do: String.downcase(to_string(Map.get(row, "id", "")))

  defp eg_id_matches?(row, markers),
    do: Enum.any?(markers, &String.contains?(eg_id(row), &1))
end
