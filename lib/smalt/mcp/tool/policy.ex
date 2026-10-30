defmodule Smalt.Mcp.Tool.Policy do
  @moduledoc """
  MCP Azure Policy read family: `policy.exemptions.list`,
  `policy.remediations.list`, `policy.locks.list`,
  `policy.setdefinitions.list`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"

  def input_schema("policy.exemptions.list") do
    %{
      "type" => "object",
      "required" => ["scope"],
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "description" =>
            "scope prefix, e.g. /subscriptions/<sub> or /subscriptions/<sub>/resourceGroups/<rg>"
        }
      }
    }
  end

  def input_schema("policy.remediations.list"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("policy.locks.list") do
    %{
      "type" => "object",
      "required" => ["scope"],
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "description" =>
            "scope prefix, e.g. /subscriptions/<sub> or /subscriptions/<sub>/resourceGroups/<rg>"
        }
      }
    }
  end

  def input_schema("policy.setdefinitions.list") do
    %{
      "type" => "object",
      "required" => ["subscription_id"],
      "properties" => %{
        "subscription_id" => %{"type" => "string"}
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("policy.exemptions.list", args) do
    case args do
      %{"scope" => scope} when is_binary(scope) ->
        exemptions = Smalt.Policy.list_policy_exemptions(scope)

        {:ok, %{"scope" => scope, "value" => exemptions, "count" => length(exemptions)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: policy.exemptions.list requires scope"}
    end
  end

  def invoke("policy.remediations.list", _args) do
    remediations =
      Smalt.Enclave.Remediations.table()
      |> Enum.sort_by(fn {code, _} -> code end)
      |> Enum.map(fn {code, command} ->
        %{"code" => code, "command" => command}
      end)

    {:ok,
     %{
       "remediations" => remediations,
       "count" => length(remediations),
       "severities" => ["BLOCKING_GATE", "ADVISORY"]
     }}
  end

  def invoke("policy.locks.list", args) do
    case args do
      %{"scope" => scope} when is_binary(scope) ->
        locks = Smalt.Policy.list_locks(scope)

        {:ok, %{"scope" => scope, "value" => locks, "count" => length(locks)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: policy.locks.list requires scope"}
    end
  end

  def invoke("policy.setdefinitions.list", args) do
    case args do
      %{"subscription_id" => sub} when is_binary(sub) ->
        defs = Smalt.Policy.list_policy_set_definitions(sub)

        {:ok,
         %{
           "subscription_id" => sub,
           "value" => defs,
           "count" => length(defs)
         }}

      _ ->
        {:refusal, @invalid_params_code,
         "refused: policy.setdefinitions.list requires subscription_id"}
    end
  end

  def invoke(_other, _args), do: nil
end
