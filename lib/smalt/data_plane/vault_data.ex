defmodule Smalt.DataPlane.VaultData do
  @moduledoc """
  Data-plane sweep helper for the vault secrets store (`:smalt_vault_secrets`,
  the 8443 `/secrets` surface owned by `Smalt.EgressRouter`).

  Mirrors the `BlobStorage.drop_account_data/1` capture-then-sweep pattern
  (D127) for the vault branch of the FR-6 composite-fixture teardown: when a
  vault (or its enclosing resource group) is deleted on the ARM plane, its
  seeded data-plane secret rows must not orphan and stay GETable on 8443.

  Keys in `:smalt_vault_secrets` are BARE secret names (`seed_data_plane_secret/5`
  does `Store.put(:smalt_vault_secrets, name, record)`) — there is no vault
  scoping in the key, so the sweep needs the secret names captured from the
  swept ARM child records before deletion.
  """

  alias Smalt.Store

  @doc """
  Deletes the data-plane secret rows for the given bare secret names.
  Tolerates a missing table (pre-Store boot) — mirrors the
  `:ets.info/1 != :undefined` fence used by EgressRouter's secret handlers.
  """
  @spec drop_vault_secrets([binary()]) :: :ok
  def drop_vault_secrets(names) when is_list(names) do
    if :ets.info(:smalt_vault_secrets) != :undefined do
      for name <- names, do: Store.delete(:smalt_vault_secrets, name)
    end

    :ok
  end

  @doc """
  Capture-then-sweep: extracts bare secret names from swept ARM store keys.
  Matches BOTH store-key conventions — prefixed
  (`.../providers/microsoft.keyvault/vaults/<vault>/secrets/<name>/...`) and
  the child-route unprefixed form
  (`.../resourcegroups/<rg>/vaults/<vault>/secrets/<name>`).
  """
  @spec vault_secret_names([binary()]) :: [binary()]
  def vault_secret_names(keys) do
    keys
    |> List.wrap()
    |> Enum.flat_map(fn key ->
      case Regex.run(~r/vaults\/[^\/]+\/secrets\/([^\/]+)/i, key, capture: :all_but_first) do
        [name] -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end
end
