defmodule Smalt.Mcp.Tool.KeyVault do
  @moduledoc """
  MCP Key Vault read family: `kv.get`, `kv.deletedkeys.list`,
  `kv.deletedsecrets.list`, `kv.certificates.list`, `certificates.get`,
  `kv.rotationpolicy.get`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"
  @resource_not_found_code "RESOURCE_NOT_FOUND"
  @internal_code "MCP_INTERNAL"

  def input_schema("kv.get") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }
  end

  def input_schema("kv.deletedkeys.list"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("kv.deletedsecrets.list"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("kv.certificates.list"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("certificates.get") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }
  end

  def input_schema("kv.rotationpolicy.get") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}}
    }
  end

  def input_schema(_other), do: nil

  def invoke("kv.get", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.Store.get(:smalt_vault_keys, name) do
          {:ok, record} ->
            {:ok, public_vault_record(record)}

          :error ->
            {:refusal, @resource_not_found_code,
             "refused: key #{inspect(name)} not found in vault key table"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: kv.get requires name"}
    end
  end

  def invoke("kv.deletedkeys.list", _args) do
    case Smalt.DataPlane.KeyVaultActions.list_deleted_keys() do
      {:ok, 200, %{"value" => keys}} ->
        {:ok, %{"deleted_keys" => keys, "count" => length(keys)}}

      {:ok, status, body} ->
        {:refusal, "KV_ERROR", "kv.deletedkeys.list returned #{status}: #{inspect(body)}"}
    end
  end

  def invoke("kv.deletedsecrets.list", _args) do
    case Smalt.DataPlane.KeyVaultActions.list_deleted_secrets() do
      {:ok, 200, %{"value" => secrets}} ->
        {:ok, %{"deleted_secrets" => secrets, "count" => length(secrets)}}

      {:ok, status, body} ->
        {:refusal, "KV_ERROR", "kv.deletedsecrets.list returned #{status}: #{inspect(body)}"}
    end
  end

  def invoke("kv.certificates.list", _args) do
    case Smalt.DataPlane.Certificates.list() do
      {:ok, 200, %{"value" => certs}} ->
        {:ok, %{"certificates" => certs, "count" => length(certs)}}

      other ->
        {:refusal, @internal_code, "kv.certificates.list unexpected: #{inspect(other)}"}
    end
  end

  def invoke("certificates.get", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.DataPlane.Certificates.get(name) do
          {:ok, 200, record} ->
            # Attributes only, matching the list projection: never the base64
            # DER body, private-key material, or stored request headers.
            {:ok,
             %{
               "id" => record["id"],
               "name" => record["name"],
               "attributes" => record["attributes"]
             }}

          {:error, 404, %{"error" => %{"code" => code, "message" => message}}} ->
            {:refusal, code, "certificates.get: #{message}"}

          other ->
            {:refusal, @internal_code, "certificates.get unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: certificates.get requires name"}
    end
  end

  def invoke("kv.rotationpolicy.get", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.DataPlane.KeyVaultActions.get_rotation_policy(name) do
          {:ok, 200, policy} when is_map(policy) ->
            {:ok, %{"name" => name, "rotation_policy" => policy}}

          {:error, 404, _detail} ->
            {:refusal, @invalid_params_code, "refused: key #{inspect(name)} not found"}

          other ->
            {:refusal, @internal_code, "kv.rotationpolicy.get unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: kv.rotationpolicy.get requires name"}
    end
  end

  def invoke(_other, _args), do: nil

  defp public_vault_record(record) do
    record
    |> Map.delete("key_material")
    |> Map.delete("value")
  end
end
