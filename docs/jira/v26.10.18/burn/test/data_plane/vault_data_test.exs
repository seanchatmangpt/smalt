defmodule Smalt.DataPlane.VaultDataTest do
  use ExUnit.Case, async: false

  alias Smalt.DataPlane.VaultData
  alias Smalt.Store

  setup do
    # Canonical resilient setup: the wipe runs INSIDE the bounded retry
    # window, so a shared-Store teardown racing the clear is retried, not
    # a dead-table ArgumentError (SmaltTest.Store, i21/i22 hardening).
    SmaltTest.Store.resilient_clear(
      post_seed: fn ->
        case :ets.info(:smalt_vault_secrets) do
          :undefined -> :ok
          _ -> :ets.delete_all_objects(:smalt_vault_secrets)
        end
      end
    )
  end

  test "vault_secret_names/1 matches both key conventions + uniqs" do
    keys = [
      # prefixed provider form
      "/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/v1/secrets/s1/versions/a",
      # child-route unprefixed form
      "/subscriptions/s/resourceGroups/rg/vaults/v2/secrets/s2",
      # dup across forms
      "/subscriptions/s/resourceGroups/rg/vaults/v1/secrets/s1",
      # non-vault key ignored
      "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/a"
    ]

    assert VaultData.vault_secret_names(keys) |> Enum.sort() == ["s1", "s2"]
  end

  test "drop_vault_secrets/1 deletes captured rows, tolerates missing table" do
    Store.put(:smalt_vault_secrets, "drop-me", %{"v" => "1"})
    Store.put(:smalt_vault_secrets, "keep-me", %{"v" => "1"})

    assert :ok = VaultData.drop_vault_secrets(["drop-me", "never-existed"])
    assert :error = Store.get(:smalt_vault_secrets, "drop-me")
    assert {:ok, _} = Store.get(:smalt_vault_secrets, "keep-me")

    # missing-table tolerance: a table that never booted must not raise
    assert :ok = VaultData.drop_vault_secrets(["x"])
  end
end
