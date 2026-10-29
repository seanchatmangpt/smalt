defmodule Smalt.ArmGateway.ResourceHealth do
  @moduledoc """
  arm_gateway seam for `Microsoft.ResourceHealth/availabilityStatuses`.

  Subscription-scope list:
      GET /subscriptions/{sub}/providers/Microsoft.ResourceHealth/availabilityStatuses

  Per-resource faces (backed by `Smalt.Arm.ResourceHealth`, the wave-6bm
  computed-health law: existing row -> synthetic-Available, unknown -> 404;
  never a fabricated outage):
      GET /subscriptions/{sub}/resourceGroups/{rg}/providers/{ns}/{type}/{name}/providers/Microsoft.ResourceHealth/availabilityStatuses
      GET .../providers/Microsoft.ResourceHealth/availabilityStatuses/current

  Response rows carry the documented availabilityStatus shape: top-level
  id/name/type + `properties.availabilityState` ("Available"), `summary`,
  `reasonType`, `occurredTime`. api-version gate rides the router's
  `check_api_version/2` (same gate class as PolicyInsights/CostManagement);
  the envelope is built here, never in the router.
  """

  alias Smalt.Arm.ResourceHealth, as: Health
  alias Smalt.Store

  @type_name "Microsoft.ResourceHealth/availabilityStatuses"

  @doc """
  Subscription-scope list. Unknown subscription -> `{:error, 404, env}`;
  known subscription -> `{:ok, 200, %{"value" => [availabilityStatus]}}` with
  one row per provisioned resource, every row `Available`.
  """
  @spec list(binary) :: {:ok, 200, map()} | {:error, 404, map()}
  def list(sub_id) do
    case Store.get(:smalt_subscriptions, sub_id) do
      {:ok, _sub} ->
        values =
          sub_id
          |> resources_in_sub()
          |> Enum.map(&row_status/1)
          |> Enum.reject(&is_nil/1)

        {:ok, 200, %{"value" => values}}

      :error ->
        {:error, 404, not_found(sub_id, "SubscriptionNotFound")}
    end
  end

  @doc """
  Per-resource current status. Unknown resource -> `{:error, 404, env}`.
  Returns the single availabilityStatus object (the documented GET current
  face), not a list envelope.
  """
  @spec get_current(binary, binary, binary, binary) ::
          {:ok, 200, map()} | {:error, 404, map()}
  def get_current(sub_id, rg, provider_type, name) do
    case Health.availability_statuses(sub_id, rg, provider_type, name) do
      {:ok, [rec]} -> {:ok, 200, status_wire(rec)}
      _ -> {:error, 404, not_found(name, "NotFound")}
    end
  end

  @doc """
  Per-resource history list face: `{"value" => [availabilityStatus]}` over
  the recorded transitions (empty list for a resource with no recorded
  transition — real ARM returns an empty value array, not a 404).
  """
  @spec list_for_resource(binary, binary, binary, binary) :: {:ok, 200, map()}
  def list_for_resource(sub_id, rg, provider_type, name) do
    {:ok, 200,
     %{"value" => Health.history(sub_id, rg, provider_type, name) |> Enum.map(&status_wire/1)}}
  end

  @doc """
  Documented availabilityStatus wire shape: id/name/type + nested
  `properties` (availabilityState/summary/reasonType/occurredTime).
  """
  @spec status_wire(map()) :: map() | nil
  def status_wire(rec) do
    id = rec["resourceId"] || rec["id"]

    if is_binary(id) do
      %{
        "id" => "#{id}/providers/#{@type_name}/current",
        "name" => "#{List.last(String.split(id, "/"))}/current",
        "type" => @type_name,
        "location" => Map.get(rec, "location"),
        "properties" => %{
          "availabilityState" => rec["availabilityState"],
          "summary" => rec["summary"],
          "reasonType" => rec["reasonType"],
          "occurredTime" => rec["occurredTime"],
          "reportedTime" => rec["occurredTime"]
        }
      }
    else
      # A stored row without a usable resource id carries no wire identity —
      # skipped in list faces, never a crash-path 500 (crash-path fence law).
      nil
    end
  end

  # -- internals ---------------------------------------------------------------

  # A subscription-list row derives its availabilityStatus through the SAME
  # computed-health law as the per-resource face (`Health.availability_statuses/4`),
  # never a parallel flat copy: parse the stored id back into (sub, rg, type,
  # name) and recompute. Rows whose id does not carry the scope shape carry no
  # wire identity — skipped, never a crash-path 500.
  defp row_status(row) do
    case parse_resource_id(row["id"]) do
      {:ok, sub, rg, pt, name} ->
        case Health.availability_statuses(sub, rg, pt, name) do
          {:ok, [rec]} -> status_wire(rec)
          _ -> nil
        end

      :error ->
        nil
    end
  end

  defp parse_resource_id(id) when is_binary(id) do
    case String.split(id, "/") do
      ["", "subscriptions", sub, rg_seg, rg, "providers", ns | type_and_name]
      when rg_seg in ["resourceGroups", "resourcegroups"] and type_and_name != [] ->
        name = List.last(type_and_name)
        type = type_and_name |> Enum.slice(0..-2//1) |> Enum.join("/")
        {:ok, sub, rg, "#{ns}/#{type}", name}

      _ ->
        :error
    end
  end

  defp parse_resource_id(_), do: :error

  # Every provisioned resource in a subscription, subscription-filter derived
  # from the stored record's id (downcase-normalized — resource keys are
  # stored downcased, the same law `Smalt.Arm.ResourceHealth.find_resource/4`
  # and the ResourceGraph subscription filter use).
  defp resources_in_sub(sub_id) do
    want = String.downcase(sub_id)

    Store.list(:smalt_resources)
    |> Enum.filter(fn row ->
      case row do
        %{"id" => "/subscriptions/" <> rest} when is_binary(rest) ->
          [sub | _] = String.split(rest, "/")
          String.downcase(sub) == want

        _ ->
          false
      end
    end)
    |> Enum.sort_by(fn row -> row["id"] end)
  end

  defp not_found(subject, code) do
    %{
      "error" => %{
        "code" => code,
        "message" =>
          "The resource '#{subject}' was not found. Availability statuses exist only for provisioned resources."
      }
    }
  end
end
