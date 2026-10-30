defmodule Smalt.Mcp.Tool.Arm do
  @moduledoc """
  MCP ARM resource-read family: `arm.get`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"
  @resource_not_found_code "RESOURCE_NOT_FOUND"

  def input_schema("arm.get") do
    %{
      "type" => "object",
      "required" => ["resource_group", "resource_type", "resource_name"],
      "properties" => %{
        "subscription_id" =>
          %{"type" => "string", "default" => Smalt.Mcp.Tool.Shared.default_subscription()},
        "resource_group" => %{"type" => "string"},
        "resource_type" => %{
          "type" => "string",
          "description" => "full type, e.g. Microsoft.Storage/storageAccounts"
        },
        "resource_name" => %{"type" => "string"}
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("arm.get", args) do
    with %{"resource_group" => rg, "resource_type" => type, "resource_name" => name}
         when is_binary(rg) and is_binary(type) and is_binary(name) <-
           args,
         sub when is_binary(sub) <-
           Map.get(args, "subscription_id", Smalt.Mcp.Tool.Shared.default_subscription()),
         res_id =
           String.downcase("/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{type}/#{name}"),
         {:ok, record} <- Smalt.Store.get(:smalt_resources, res_id) do
      {:ok, record}
    else
      :error ->
        {:refusal, @resource_not_found_code, "refused: resource not found in substrate store"}

      _ ->
        {:refusal, @invalid_params_code,
         "refused: arm.get requires resource_group, resource_type, resource_name"}
    end
  end

  def invoke(_other, _args), do: nil
end
