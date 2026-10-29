defmodule Smalt.ArmGateway.Deployments do
  @moduledoc """
  ARM deployment materialization layer (AZURE-FIDELITY lane 2, v26.10.25).

  Companion to `Smalt.Arm.Deployments` (wave-6 record store + routes in
  `Smalt.ArmGateway.Router`). This module owns the part wave-6 left as an
  echo face: a PUT deployment MATERIALIZES its template resources into the
  real provider store (`:smalt_resources`), so deployed resources appear in
  RG listings (`GET .../resourceGroups/{rg}/resources`) exactly like a
  directly-PUT resource does.

  Contract (documented Microsoft.Resources/deployments REST shape):

    - Each `properties.template.resources[]` entry must be a map with binary
      `type` and `name`. The `type` must be an admitted Registry type
      (`Smalt.Registry.admitted?/1`); anything else is an `InvalidTemplate`
      validation error (400, details array naming the offending type) — the
      same refusal shape real ARM validate returns for an unknown resource
      type.
    - Each admitted resource is persisted through
      `Smalt.ArmGateway.Defaults.apply/2` + `enrich/5` (the same hydration
      the generic resource PUT uses), keyed by lowercased ARM id in
      `:smalt_resources`.
    - One deploymentOperations entry per template resource, each with
      `properties.provisioningState = "Succeeded"`, a timestamp, and a
      `targetResource` (id + resourceType + resourceName).

  Storage: reads/writes only `Smalt.Store` (`:smalt_resources`) — no new
  table; the deployment record itself stays in `Smalt.Arm.Deployments`.
  """

  alias Smalt.ArmGateway.Defaults
  alias Smalt.Store
  alias Smalt.Registry

  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  @doc """
  Validate the template's resources array shape + admission. `:ok` |
  `{:error, 400, error_map}` where error_map is the ARM InvalidTemplate
  envelope (code/message/details).

  Checks:

    - `resources` present and a list (default `[]` when absent — an
      empty-resources template is valid).
    - every entry a map with binary `type` and `name`.
    - every `type` admitted (`Smalt.Registry.admitted?/1`).
  """
  @spec validate_resources(map()) :: :ok | {:error, 400, map()}
  def validate_resources(template) when is_map(template) do
    resources = template["resources"] || []

    if is_list(resources) do
      resources
      |> Enum.reduce_while(:ok, fn res, :ok ->
        case validate_resource_entry(res) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, 400,
       invalid_template("template.resources must be an array", [
         invalid_detail("properties.template.resources", "must be an array")
       ])}
    end
  end

  @doc """
  Materialize a template's resources into `:smalt_resources` at RG scope.

  `{:ok, [op_maps]}` with one deploymentOperations entry per template
  resource, or `{:error, 400, error_map}` (caller decides whether to reject).
  Callers must have run `validate_resources/1` first (the router PUT/validate
  faces do), so materialize sees only admitted shapes.
  """
  @spec materialize(String.t(), String.t(), String.t(), map()) ::
          {:ok, [map()]} | {:error, 400, map()}
  def materialize(sub, rg, dep_name, template) when is_binary(rg) do
    resources = template["resources"] || []

    now = now_iso()

    ops =
      Enum.map(resources, fn res ->
        type = res["type"]
        name = res["name"]
        id = template_resource_id(res, sub, rg)
        key = String.downcase(id)

        record = projected(res, sub, rg)

        Store.put(:smalt_resources, key, record)

        op(dep_name, sub, rg, id, type, name, now)
      end)

    {:ok, %{ops: ops, deployment: dep_link(dep_name, sub, rg)}}
  end

  @doc """
  The record `materialize/4` WOULD store for one template resource at RG
  scope — computed with the exact same pipeline (Defaults.apply + enrich +
  record shape) but writing nothing. What-if diffs against this projection so
  an identical re-deploy reads NoChange (the stored row already carries the
  enriched form), not a spurious Modify over enrichment-only keys.
  """
  @spec projected(map(), String.t(), String.t()) :: map()
  def projected(res, sub, rg) do
    type = res["type"]
    name = res["name"]
    id = template_resource_id(res, sub, rg)
    full_type = full_type(type)
    merged = Defaults.apply(full_type, res)
    enriched = Defaults.enrich(full_type, leaf_name(name), id, merged, nil)

    record(full_type, id, leaf_name(name), res, merged, enriched)
  end

  @doc "Wire face: deploymentOperations entries from a materialize result."
  def ops(%{ops: ops}), do: ops

  # -- internals -------------------------------------------------------------

  defp validate_resource_entry(%{"type" => type, "name" => name} = _res)
       when is_binary(type) and is_binary(name) do
    if Registry.admitted?(full_type(type)),
      do: :ok,
      else:
        {:error, 400,
         invalid_template("resource type is not valid or not registered", [
           invalid_detail(
             "properties.template.resources",
             "the resource type '#{type}' is not a registered provider type in this deployment"
           )
         ])}
  end

  defp validate_resource_entry(res) do
    {:error, 400,
     invalid_template("resource entry is invalid", [
       invalid_detail(
         "properties.template.resources",
         "each resource must be an object with string 'type' and 'name' members; got: #{inspect(res)}"
       )
     ])}
  end

  # "Microsoft.KeyVault/vaults" -> the record's full type; child types
  # (vaults/keys) materialize at their parent-scoped id shape.
  defp full_type(type), do: type

  defp template_resource_id(res, sub, rg) do
    type = res["type"]
    name = res["name"]
    nsegs = length(String.split(type, "/")) - 1
    name_segs = String.split(name, "/")

    base = "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/"

    if length(name_segs) == nsegs do
      base <> type <> "/" <> Enum.join(name_segs, "/")
    else
      base <> type <> "/" <> name
    end
  end

  defp leaf_name(name), do: name |> String.split("/") |> List.last()

  defp record(full_type, id, name, res, merged, enriched) do
    %{
      "id" => id,
      "name" => name,
      "type" => full_type,
      "location" => Map.get(res, "location", "eastus"),
      "properties" =>
        enriched
        |> Map.get("properties", %{})
        |> Map.put("provisioningState", "Succeeded"),
      "tags" => tags(res["tags"]),
      "systemData" => @system_data
    }
    |> maybe_put("sku", merged["sku"])
    |> maybe_put("kind", merged["kind"])
  end

  defp tags(nil), do: nil

  defp tags(%{} = t), do: if(map_size(t) == 0, do: nil, else: t)

  defp maybe_put(rec, _k, nil), do: rec
  defp maybe_put(rec, k, v), do: Map.put(rec, k, v)

  defp op(dep_name, sub, rg, id, type, name, now) do
    op_id = "op-" <> uniform()
    dep_id = dep_link(dep_name, sub, rg)

    %{
      "id" => "#{dep_id}/operations/#{op_id}",
      "operationId" => op_id,
      "properties" => %{
        "provisioningOperation" => "Create",
        "provisioningState" => "Succeeded",
        "timestamp" => now,
        "targetResource" => %{
          "id" => id,
          "resourceType" => type,
          "resourceName" => leaf_name(name)
        },
        "statusMessage" => %{"status" => "Succeeded"},
        "statusPhase" => "Accepted, Running, Succeeded"
      }
    }
  end

  defp uniform, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp invalid_template(message, details) do
    %{
      "code" => "InvalidTemplate",
      "message" => message,
      "details" => details
    }
  end

  defp invalid_detail(path, msg) do
    %{"code" => "InvalidTemplate", "message" => "#{path}: #{msg}", "target" => path}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp dep_link(dep_name, sub, rg) do
    "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Resources/deployments/#{dep_name}"
  end
end
