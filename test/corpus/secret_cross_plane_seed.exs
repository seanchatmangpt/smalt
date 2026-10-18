# INCIDENT → FIX → FENCE
#
# INCIDENT: an ARM secret PUT (control plane, 9443) wrote only the ARM record;
# the value was invisible on the data plane (8443) — azurerm_key_vault_secret
# apply succeeded while the consumer GET read nothing (kv cross-plane lane,
# lane 361).
#
# FIX: cross-plane seed in the ARM secret child PUT
# (lib/smalt/arm_gateway/router.ex seed_data_plane_secret/4) — a valid secret
# PUT under an existing vault also writes :smalt_vault_secrets so a data-plane
# GET /secrets/:name returns the value. Skipped when the parent vault is
# absent or the body carries no string "value" (control-plane-only record).
#
# FENCE (this corpus row): the round-trip cannot regress.
defmodule Smalt.Corpus.SecretCrossPlaneSeed do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"

  setup do
    ensure_store()
  end

  defp put_vault(vault) do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/#{vault}?api-version=2021-04-01",
      %{
        "location" => "eastus",
        "properties" => %{"sku" => %{"name" => "standard", "family" => "A"}}
      }
    )
  end

  defp put_secret(vault, name, value) do
    arm(
      :put,
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/#{vault}/secrets/#{name}?api-version=2023-07-01",
      %{"location" => "eastus", "properties" => %{"value" => value}}
    )
  end

  @tag :corpus
  test "ARM secret PUT -> data-plane GET value round-trip" do
    assert put_vault("corpus-kv").status == 201
    secret = put_secret("corpus-kv", "corpus-secret", "corpus-seed-value")
    assert secret.status in [200, 201], inspect(secret.resp_body)

    get =
      egress(:get, "/secrets/corpus-secret", %{}, [{"authorization", "Bearer corpus-harness"}])

    assert get.status == 200,
           "cross-plane seed regressed: #{get.status} #{inspect(get.resp_body)}"

    assert json(get)["value"] == "corpus-seed-value"
  end

  @tag :corpus
  test "no parent vault -> no data-plane seed (ARM-only record)" do
    secret = put_secret("missing-vault", "orphan-secret", "v")
    assert secret.status == 404

    get =
      egress(:get, "/secrets/orphan-secret", %{}, [{"authorization", "Bearer corpus-harness"}])

    assert get.status == 404, "seeded a secret with no parent vault: #{get.status}"
  end
end
