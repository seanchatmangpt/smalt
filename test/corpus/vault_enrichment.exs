# INCIDENT → FIX → FENCE
#
# INCIDENT: azurerm 4.54 FR-5 divergences — the sparse ARM records 404'd or
# nil-deref'd consumer reads: vault vaultUri absent, storage primaryEndpoints
# nil, SB/EH namespace property derefs + listKeys (tf-plan-probe, T5
# cleanroom).
#
# FIX: persist-time enrichment `Smalt.ArmGateway.Defaults.enrich/5`
# (lib/smalt/arm_gateway/defaults.ex) deep-merges name-interpolated defaults
# UNDER user properties at PUT-persist time: vaultUri (echoing the gateway
# request authority per KD-T5-F1), storage primaryEndpoints, SB/EH namespace
# property sets. GET stays verbatim.
#
# FENCE (this corpus row): the enriched read shape cannot regress.
defmodule Smalt.Corpus.VaultEnrichment do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"

  setup do
    ensure_store()
  end

  @tag :corpus
  test "vault GET echoes properties.vaultUri (authority-aware enrichment)" do
    put =
      arm(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/corpus-vault?api-version=2021-04-01",
        %{
          "location" => "eastus",
          "properties" => %{"sku" => %{"name" => "standard", "family" => "A"}}
        }
      )

    assert put.status == 201, inspect(put.resp_body)

    get =
      arm(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/corpus-vault?api-version=2021-04-01"
      )

    assert get.status == 200, inspect(get.resp_body)
    props = json(get)["properties"]
    assert is_binary(props["vaultUri"]) and props["vaultUri"] != "",
           "vaultUri enrichment regressed: #{inspect(props)}"

    assert String.ends_with?(props["vaultUri"], "/")
  end

  @tag :corpus
  test "storage account GET carries properties.primaryEndpoints (FR-5 nil-deref fence)" do
    put =
      arm(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/corpusstore?api-version=2021-04-01",
        %{"location" => "eastus", "properties" => %{}}
      )

    assert put.status in [200, 201, 202], inspect(put.resp_body)

    get =
      arm(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/corpusstore?api-version=2021-04-01"
      )

    assert get.status == 200, inspect(get.resp_body)
    endpoints = get_in(json(get), ["properties", "primaryEndpoints"]) || %{}

    assert is_map(endpoints) and map_size(endpoints) > 0,
           "primaryEndpoints enrichment regressed: #{inspect(json(get))}"
  end
end
