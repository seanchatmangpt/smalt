defmodule Smalt.Arm.NameAvailability do
  @moduledoc """
  Azure CheckNameAvailability faces (wave-6 lane w6ah).

  Per-type name rules real Azure enforces on POST .../checkNameAvailability:

    - storageAccount: 3-24 lowercase alnum, uniqueness against resources
      actually stored in smalt's `:smalt_resources` Store (any RG).
    - dnsZone: valid zone-label rules; existence checked against
      `Smalt.Arm.Dns` when loaded (wave-6 w6y), else the resources store.
    - vault: 3-24, alnum+hyphen, begin letter, end alnum.
    - webSite / Microsoft.Web/sites: 1-60 chars.
    - Unknown type: typed refusal {:error, :unsupported_type}.

  Public wire helper check_wire/1 renders the Azure response shape for the
  post-split router patch (POST .../CheckNameAvailability). Module level
  only - no router edits (w6R hold).
  """

  @typedoc "Check verdict: available, or taken/invalid with a real message."
  @type verdict ::
          {:ok, :name_available}
          | {:error, {:already_exists, String.t()}}
          | {:error, {:invalid, String.t()}}

  @doc "Check a candidate name for a resource type."
  @spec check(String.t() | nil, String.t(), term()) :: verdict() | {:error, :unsupported_type}
  def check(name, resource_type, _api_version \\ nil)

  def check(name, type, api) when is_binary(name) do
    do_check(name, normalize_type(type), api)
  end

  def check(_name, _type, _api), do: {:error, {:invalid, "name must be a string"}}

  # -- per-type rules ---------------------------------------------------------

  defp do_check(name, "Microsoft.Storage/storageAccounts", _api) do
    if valid_storage_account?(name) do
      if exists?("Microsoft.Storage/storageAccounts", name) do
        {:error, {:already_exists, "The storage account '#{name}' is already taken."}}
      else
        {:ok, :name_available}
      end
    else
      msg =
        "The storage account name is invalid. Storage account names must be " <>
          "3-24 characters and use numbers and lower-case letters only."

      {:error, {:invalid, msg}}
    end
  end

  defp do_check(name, "Microsoft.Network/dnsZones", api) do
    if valid_zone_name?(name) do
      if zone_exists?(name, api) do
        {:error, {:already_exists, "Zone '#{name}' is already taken."}}
      else
        {:ok, :name_available}
      end
    else
      msg =
        "Zone name is invalid. Use labels of letters/digits/hyphens separated by dots."

      {:error, {:invalid, msg}}
    end
  end

  defp do_check(name, "Microsoft.KeyVault/vaults", _api) do
    if valid_vault?(name) do
      if exists?("Microsoft.KeyVault/vaults", name) do
        {:error, {:already_exists, "Vault '#{name}' is already taken."}}
      else
        {:ok, :name_available}
      end
    else
      msg =
        "Vault name is invalid: must be 3-24 chars, begin with a letter, " <>
          "end with letter or digit, alnum and hyphen only."

      {:error, {:invalid, msg}}
    end
  end

  defp do_check(name, "Microsoft.Web/sites", _api) do
    if valid_web?(name) do
      if exists?("Microsoft.Web/sites", name) do
        {:error, {:already_exists, "The web app '#{name}' is already in use."}}
      else
        {:ok, :name_available}
      end
    else
      {:error, {:invalid, "The web app name is invalid: 1-60 characters."}}
    end
  end

  defp do_check(_name, _type, _api), do: {:error, :unsupported_type}

  # -- type aliasing ------------------------------------------------------------

  defp normalize_type("storageAccount"), do: "Microsoft.Storage/storageAccounts"
  defp normalize_type("vault"), do: "Microsoft.KeyVault/vaults"
  defp normalize_type("dnsZone"), do: "Microsoft.Network/dnsZones"
  defp normalize_type("webSite"), do: "Microsoft.Web/sites"
  defp normalize_type("microsoft.web/sites"), do: "Microsoft.Web/sites"
  defp normalize_type(t), do: t

  # -- validators -----------------------------------------------------------------

  defp valid_storage_account?(n) do
    len = String.length(n)
    len >= 3 and len <= 24 and String.match?(n, ~r/^[a-z0-9]+$/)
  end

  defp valid_vault?(n) do
    len = String.length(n)
    len >= 3 and len <= 24 and String.match?(n, ~r/^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$/)
  end

  defp valid_web?(n), do: n != "" and String.length(n) <= 60

  defp valid_zone_name?(n) do
    String.contains?(n, ".") and
      String.match?(n, ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.?$/)
  end

  # -- existence checks -----------------------------------------------------------

  # Any-RG existence: scan the real resources store for an admitted record of
  # this type with the given name (keys are downcased resource ids).
  defp exists?(full_type, name) do
    if :ets.info(:smalt_resources) == :undefined do
      []
    else
      do_exists?(Smalt.Store.list_prefix(:smalt_resources, "/subscriptions/"), full_type, String.downcase(name))
    end
  end

  defp do_exists?(records, full_type, downcased_name) do
    Enum.any?(records, fn record ->
      record_type(record) == full_type and record_name(record) == downcased_name
    end)
  end

  defp record_type(%{"type" => t}) when is_binary(t), do: t
  defp record_type(_), do: nil

  defp record_name(%{"name" => n}) when is_binary(n), do: String.downcase(n)
  defp record_name(_), do: nil

  # dnsZones: prefer the w6y DNS module (real zone records) when loaded.
  defp zone_exists?(name, _api) do
    if Code.ensure_loaded?(Smalt.Arm.Dns) and function_exported?(Smalt.Arm.Dns, :zone, 1) do
      match?({:ok, _}, apply(Smalt.Arm.Dns, :zone, [name]))
    else
      exists?("Microsoft.Network/dnsZones", name)
    end
  end

  # -- wire shape -------------------------------------------------------------------

  @doc "Render a verdict as the Azure CheckNameAvailability response map."
  @spec check_wire(verdict() | {:error, :unsupported_type}) :: map()
  def check_wire({:ok, :name_available}) do
    %{"nameAvailable" => true}
  end

  def check_wire({:error, {:already_exists, msg}}) do
    %{"nameAvailable" => false, "reason" => "AlreadyExists", "message" => msg}
  end

  def check_wire({:error, {:invalid, msg}}) do
    %{"nameAvailable" => false, "reason" => "Invalid", "message" => msg}
  end

  def check_wire({:error, :unsupported_type}) do
    %{"nameAvailable" => false, "reason" => "Invalid", "message" => "Resource type is not supported for name availability."}
  end
end
