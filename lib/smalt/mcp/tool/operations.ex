defmodule Smalt.Mcp.Tool.Operations do
  @moduledoc """
  MCP operations read family: `cluster.status`, `health.readiness`,
  `lro.operations.list`, `monitor.alerts.list`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"
  @internal_code "MCP_INTERNAL"

  def input_schema("cluster.status"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("health.readiness"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("lro.operations.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription" => %{
          "type" => "string",
          "description" =>
            "optional subscription id filter (Scopes to /subscriptions/<id>/operations)"
        }
      }
    }
  end

  def input_schema("monitor.alerts.list") do
    %{
      "type" => "object",
      "required" => ["sub", "rg"],
      "properties" => %{
        "sub" => %{"type" => "string"},
        "rg" => %{"type" => "string"}
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("cluster.status", _args), do: {:ok, Smalt.Cluster.cluster_status()}

  def invoke("health.readiness", _args),
    do: {:ok, Smalt.Health.to_json_map(Smalt.Health.readiness())}

  def invoke("lro.operations.list", args) do
    sub = args["subscription"]

    if sub != nil and not is_binary(sub) do
      {:refusal, @invalid_params_code,
       "refused: lro.operations.list subscription must be a string"}
    else
      ops =
        :smalt_operations
        |> Smalt.Store.list()
        |> Enum.filter(fn
          %{"id" => "/subscriptions/" <> rest} ->
            case sub do
              nil -> true
              ^sub -> true
              _ -> String.starts_with?(rest, "#{sub}/")
            end

          _ ->
            false
        end)
        |> Enum.sort_by(& &1["id"])

      {:ok, %{"operations" => ops, "count" => length(ops)}}
    end
  end

  def invoke("monitor.alerts.list", args) do
    case args do
      %{"sub" => sub, "rg" => rg} when is_binary(sub) and is_binary(rg) ->
        case Smalt.Monitor.MetricAlerts.list_alerts(sub, rg) do
          alerts when is_list(alerts) ->
            {:ok, %{"sub" => sub, "rg" => rg, "alerts" => alerts, "count" => length(alerts)}}

          other ->
            {:refusal, @internal_code, "monitor.alerts.list unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: monitor.alerts.list requires sub and rg"}
    end
  end

  def invoke(_other, _args), do: nil
end
