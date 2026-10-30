defmodule Smalt.Mcp.Tool.Catalog do
  @moduledoc """
  MCP catalog/metadata read family: `atlas.lineage.get` (Purview),
  `appconfig.snapshots.list`, `appconfig.snapshots.kv`, `dns.zones.list`.

  References the generated TTL surface (`Smalt.Mcp.Descriptor`); never
  redefines tool metadata. Returns the standard tool envelope:
  `{:ok, result}` | `{:refusal, code, message}` — `nil` when the tool id is
  not in this family (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"
  @internal_code "MCP_INTERNAL"

  def input_schema("atlas.lineage.get") do
    %{
      "type" => "object",
      "required" => ["guid"],
      "properties" => %{
        "guid" => %{"type" => "string"},
        "direction" => %{
          "type" => "string",
          "enum" => ["input", "output", "both"],
          "default" => "both"
        },
        "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 10, "default" => 1}
      }
    }
  end

  def input_schema("appconfig.snapshots.list"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("appconfig.snapshots.kv") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string", "description" => "snapshot name"}
      }
    }
  end

  def input_schema("dns.zones.list") do
    %{
      "type" => "object",
      "required" => ["rg"],
      "properties" => %{"rg" => %{"type" => "string"}}
    }
  end

  def input_schema(_other), do: nil

  def invoke("atlas.lineage.get", args) do
    case args do
      %{"guid" => guid} when is_binary(guid) ->
        direction = args["direction"] || "both"
        depth = args["depth"] || 1

        cond do
          direction not in ["input", "output", "both"] ->
            {:refusal, @invalid_params_code,
             "refused: atlas.lineage.get direction must be one of input, output, both"}

          not is_integer(depth) or depth < 1 or depth > 10 ->
            {:refusal, @invalid_params_code,
             "refused: atlas.lineage.get depth must be an integer between 1 and 10"}

          true ->
            case Smalt.DataPlane.Purview.lineage(guid, direction, depth) do
              {:ok, 200, body} ->
                {:ok, body}

              {:error, 400, %{"error" => %{"code" => code, "message" => message}}} ->
                {:refusal, code, "atlas.lineage.get: #{message}"}

              other ->
                {:refusal, @internal_code, "atlas.lineage.get unexpected: #{inspect(other)}"}
            end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: atlas.lineage.get requires guid"}
    end
  end

  def invoke("appconfig.snapshots.list", _args) do
    snapshots = Smalt.DataPlane.AppConfigSnapshots.list()

    {:ok, %{"snapshots" => snapshots, "count" => length(snapshots)}}
  end

  def invoke("appconfig.snapshots.kv", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.DataPlane.AppConfigSnapshots.kv_view(name) do
          {:ok, items} ->
            {:ok, %{"name" => name, "items" => items, "count" => length(items)}}

          {:error, {code, message}} ->
            {:refusal, code, "appconfig.snapshots.kv: #{message}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: appconfig.snapshots.kv requires name"}
    end
  end

  def invoke("dns.zones.list", args) do
    case args do
      %{"rg" => rg} when is_binary(rg) ->
        case Smalt.Arm.Dns.list_zones("sub", rg) do
          {:ok, zones} when is_list(zones) ->
            {:ok, %{"rg" => rg, "zones" => zones, "count" => length(zones)}}

          other ->
            {:refusal, @internal_code, "dns.zones.list unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: dns.zones.list requires rg"}
    end
  end

  def invoke(_other, _args), do: nil
end
