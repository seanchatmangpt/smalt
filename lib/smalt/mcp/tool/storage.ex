defmodule Smalt.Mcp.Tool.Storage do
  @moduledoc """
  MCP blob-storage read family: `blob.list` and the Event Grid DLQ scan
  `eg.dlq.list`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"

  def input_schema("blob.list") do
    %{
      "type" => "object",
      "required" => ["account", "container"],
      "properties" => %{
        "account" => %{"type" => "string"},
        "container" => %{"type" => "string"}
      }
    }
  end

  def input_schema("eg.dlq.list") do
    %{
      "type" => "object",
      "properties" => %{
        "account" => %{"type" => "string", "default" => "eg-dlq"},
        "subscriber" => %{
          "type" => "string",
          "description" => "optional subscriber name; narrows to container eg-dlq-<subscriber>"
        }
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("blob.list", args) do
    case args do
      %{"account" => account, "container" => container}
      when is_binary(account) and is_binary(container) ->
        prefix = "#{account}/#{container}/"

        # Keys-only-class scan (blob_storage.list_blobs_xml pattern): walk
        # KEYS via Store.prefix_keys/2 and fetch+project one record at a
        # time, so the full content of every blob is never held in a single
        # intermediate list. Behavioral no-op: same keys, same order,
        # churn-safe skip preserved (deleted mid-walk entries drop out).
        blobs =
          :smalt_blobs
          |> Smalt.Store.prefix_keys(prefix)
          |> Enum.flat_map(fn key ->
            case Smalt.Store.get(:smalt_blobs, key) do
              {:ok, blob} -> [Smalt.DataPlane.BlobStorage.blob_metadata(blob)]
              _ -> []
            end
          end)

        {:ok,
         %{"container" => "#{account}/#{container}", "blobs" => blobs, "count" => length(blobs)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: blob.list requires account and container"}
    end
  end

  def invoke("eg.dlq.list", args) do
    account = args["account"]

    if account != nil and not is_binary(account) do
      {:refusal, @invalid_params_code, "refused: eg.dlq.list account must be a string"}
    else
      account = account || "eg-dlq"

      prefix =
        case args["subscriber"] do
          sub when is_binary(sub) ->
            "#{account}/eg-dlq-#{sub}/"

          nil ->
            "#{account}/"

          _ ->
            {:refusal, @invalid_params_code, "refused: eg.dlq.list subscriber must be a string"}
        end

      if is_binary(prefix) do
        blobs =
          :smalt_blobs
          |> Smalt.Store.prefix_keys(prefix)
          |> Enum.flat_map(fn key ->
            case Smalt.Store.get(:smalt_blobs, key) do
              {:ok, blob} -> [dlq_blob_row(blob)]
              _ -> []
            end
          end)

        {:ok, %{"prefix" => prefix, "dead_lettered" => blobs, "count" => length(blobs)}}
      else
        prefix
      end
    end
  end

  def invoke(_other, _args), do: nil

  # DLQ rows are CONTENT-FREE and header-free: the stored blob record keeps
  # the original PUT request headers, which carry the caller's Authorization
  # bearer — a read-only surface must never project credential material
  # across the wire. Only blob-identity + x-ms-meta-* ride the MCP response.
  defp dlq_blob_row(blob) do
    metadata = Smalt.DataPlane.BlobStorage.blob_metadata(blob)

    meta =
      metadata
      |> Map.get("headers", %{})
      |> Enum.filter(fn {k, _v} -> is_binary(k) and String.starts_with?(k, "x-ms-meta-") end)
      |> Map.new()

    metadata
    |> Map.drop(["headers"])
    |> Map.put("metadata", meta)
  end
end
