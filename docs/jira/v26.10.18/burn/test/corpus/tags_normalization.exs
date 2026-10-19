# INCIDENT → FIX → FENCE
#
# INCIDENT: azurerm sends an explicit `"tags": null` when no tags are
# configured; Map.get/3's default does not coerce nil, so a null tags member
# was persisted and every refresh GET echoed `"tags": null` — terraform
# rendered that as `+ tags = {}` on every plan (persistent diff noise).
#
# FIX (v1): normalize_tags/1 coerced nil/missing/non-map tags to %{}.
# FIX (v2, current — 2026-10-16, lane 419 wire evidence /tmp/tf-rg419): real
# azurerm normalizes an EMPTY tags map to null in state (real Azure omits
# tags on untagged resources), so echoing `"tags": {}` makes every
# refresh-only plan drift `+ tags = {}` forever. normalize_tags/1 now pins
# the null-when-empty parity law: nil/missing/non-map/EMPTY map → JSON null
# on the wire; a non-empty map round-trips unchanged.
#
# FENCE (this corpus row): tags never round-trips as the stale `{}` literal —
# untagged resources echo `"tags": null`, tagged resources round-trip.
Code.require_file("helper.exs", __DIR__)

defmodule Smalt.Corpus.TagsNormalization do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"

  setup do
    # routes through the canonical Helper.resilient_clear/1 (i22 hardening)
    :ok = ensure_store()
  end

  @tag :corpus
  test "resource-group PUT with tags:null echoes tags:null on GET (null-when-empty parity)" do
    put =
      arm(
        :put,
        "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=2021-04-01",
        %{"location" => "eastus", "tags" => nil}
      )

    assert put.status in [200, 201, 202], inspect(put.resp_body)

    get = arm(:get, "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=2021-04-01")
    assert get.status == 200, inspect(get.resp_body)
    assert json(get)["tags"] == nil, "tags:null normalization regressed: #{inspect(json(get))}"
  end

  @tag :corpus
  test "resource PUT with tags:null echoes tags:null (storage account readback)" do
    assert arm(:put, "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=2021-04-01", %{
             "location" => "eastus"
           }).status in [200, 201, 202]

    put =
      arm(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/corpus-tags?api-version=2021-04-01",
        %{"location" => "eastus", "tags" => nil, "properties" => %{}}
      )

    assert put.status in [200, 201, 202], inspect(put.resp_body)

    get =
      arm(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/corpus-tags?api-version=2021-04-01"
      )

    assert get.status == 200, inspect(get.resp_body)
    assert json(get)["tags"] == nil, "resource tags:null regressed: #{inspect(json(get))}"
  end

  @tag :corpus
  test "real tags survive the normalization untouched" do
    put =
      arm(:put, "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=2021-04-01", %{
        "location" => "eastus",
        "tags" => %{"env" => "corpus"}
      })

    assert put.status in [200, 201]

    get = arm(:get, "/subscriptions/#{@sub}/resourcegroups/#{@rg}?api-version=2021-04-01")
    assert get.status == 200
    assert json(get)["tags"] == %{"env" => "corpus"}
  end
end
