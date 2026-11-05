defmodule Smalt.ArmGateway.StorageManagementPolicies do
  @moduledoc """
  ARM storage account managementPolicies child-resource state law
  (AZURE-#1 wire-parity face). # KD-COVERS: KD-188

  Owns the store-level logic for the
  `Microsoft.Storage/storageAccounts/{acct}/managementPolicies/{name}`
  sub-resource surface the generic child families do not cover:

  - PUT/GET/DELETE of the singleton policy — real Azure admits exactly one
    name per account (`default`); any other name is refused (typed 400,
    `ManagementPolicyNameInvalid`).
  - parent-account existence law: a PUT/GET/DELETE whose parent storage
    account row is absent answers the typed 404 `StorageAccountNotFound`
    (real-Azure error code for managementPolicies verbs on a missing
    account), never a fabricated policy.
  - the policy body rides `properties` verbatim (real Azure shape:
    `{"properties":{"policy":{...}}}`); a body without a map `properties`
    member is refused (typed 400 `InvalidRequestContent`).
  - records ride the shared `:smalt_resources` table under the downcased
    resource-id key convention (same keys as the blobServices/default
    sibling), full type
    `Microsoft.Storage/storageAccounts/managementPolicies`.
  - DELETE answers 200 with an empty body (real Azure
    ManagementPolicies_Delete is a synchronous 200, not an LRO).
  """

  alias Smalt.Store

  @full_type "Microsoft.Storage/storageAccounts/managementPolicies"
  @singleton_name "default"

  # Synthetic fixed systemData — same constant the generic resource face
  # pins (resource_providers.ex @system_data).
  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

  @doc """
  PUT law: {:ok, record, created?} | {:error, :no_account}
  | {:error, {:bad_name, name}} | {:error, :bad_properties}.
  The policy record rides `:smalt_resources` under the downcased id; a
  re-PUT is idempotent (200) and replaces the stored properties verbatim.
  """
  def put(sub_id, rg_name, acct, name, body) do
    with :ok <- check_name(name),
         {:ok, body_props} <- check_properties(body),
         :ok <- check_account(sub_id, rg_name, acct) do
      id = arm_id(sub_id, rg_name, acct, name)
      key = String.downcase(id)

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))

      record = %{
        "id" => id,
        "name" => @singleton_name,
        "type" => @full_type,
        "properties" =>
          body_props
          |> Map.put("provisioningState", "Succeeded"),
        "tags" => nil,
        "systemData" => @system_data
      }

      Store.put(:smalt_resources, key, record)
      {:ok, record, not existed?}
    end
  end

  @doc "GET law: {:ok, record} | {:error, :no_account} | {:error, :absent}."
  def get(sub_id, rg_name, acct, name) do
    with :ok <- check_name(name),
         :ok <- check_account(sub_id, rg_name, acct),
         {:ok, record} <- Store.get(:smalt_resources, String.downcase(arm_id(sub_id, rg_name, acct, name))) do
      {:ok, record}
    else
      {:error, :no_account} -> {:error, :no_account}
      :error -> {:error, :absent}
    end
  end

  @doc "DELETE law: :ok | {:error, :no_account} | {:error, :absent}."
  def delete(sub_id, rg_name, acct, name) when is_binary(name) do
    key = String.downcase(arm_id(sub_id, rg_name, acct, name))

    with :ok <- check_account(sub_id, rg_name, acct),
         {:ok, _} <- Store.get(:smalt_resources, key) do
      Store.delete(:smalt_resources, key)
      :ok
    else
      {:error, :no_account} -> {:error, :no_account}
      :error -> {:error, :absent}
    end
  end

  # -- law internals ----------------------------------------------------------

  # Real Azure admits exactly one managementPolicies name per account:
  # "default". Anything else is a typed refusal.
  defp check_name(@singleton_name), do: :ok
  defp check_name(name), do: {:error, {:bad_name, name}}

  defp check_properties(%{"properties" => %{} = props}), do: {:ok, props}
  defp check_properties(_), do: {:error, :bad_properties}

  defp check_account(sub_id, rg_name, acct) do
    acct_id =
      String.downcase(
        "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.Storage/storageAccounts/#{acct}"
      )

    case Store.get(:smalt_resources, acct_id) do
      {:ok, _} -> :ok
      :error -> {:error, :no_account}
    end
  end

  defp arm_id(sub_id, rg_name, acct, name) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.Storage/storageAccounts/#{acct}/managementPolicies/#{name}"
  end
end
