# INCIDENT → FIX → FENCE
#
# INCIDENT: the EventHub namespace enrichment defaulted
# `"created_at"` (snake_case typo) where the sibling ServiceBus entry used
# `"createdAt"` — azurerm eventhub_namespace_resource.go:541 dereferences
# createdAt and nil-panicked on the sparse record (lib/smalt/arm_gateway/
# defaults.ex:106 documents the typo and the fix).
#
# FIX: the EH namespace wire carries BOTH keys — `"createdAt"` (camelCase,
# the azurerm read) AND `"created_at"` (the snake_case consumer key) — the
# dual-key emission so neither reader class nil-derefs.
#
# FENCE (this corpus row): both namespaces carry createdAt (camel) and the
# EH dual-key emission; neither key may vanish from the wire.
Code.require_file("helper.exs", __DIR__)

defmodule Smalt.Corpus.EhCreatedAt do
  @moduledoc false

  use ExUnit.Case, async: false

  import Smalt.Corpus.Helper

  @sub "sub-corpus"
  @rg "corpus-rg"

  setup do
    ensure_store()
  end

  defp put_and_get(ns_type, name) do
    put =
      arm(
        :put,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns_type}/#{name}?api-version=2021-04-01",
        %{
          "location" => "eastus",
          "sku" => %{"name" => "Standard", "tier" => "Standard"},
          "properties" => %{}
        }
      )

    assert put.status in [200, 201], inspect(put.resp_body)

    get =
      arm(
        :get,
        "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/#{ns_type}/#{name}?api-version=2021-04-01"
      )

    assert get.status == 200, inspect(get.resp_body)
    json(get)
  end

  @tag :corpus
  test "EH namespace carries the dual-key createdAt + created_at emission" do
    body = put_and_get("Microsoft.EventHub/namespaces", "corpus-ehns")
    props = body["properties"] || %{}

    assert is_binary(props["createdAt"]) and props["createdAt"] != "",
           "EH createdAt enrichment regressed: #{inspect(props)}"

    assert is_binary(props["created_at"]) and props["created_at"] != "",
           "EH dual-key created_at emission regressed: #{inspect(props)}"
  end

  @tag :corpus
  test "SB sibling namespace carries the same camelCase createdAt key" do
    body = put_and_get("Microsoft.ServiceBus/namespaces", "corpus-sbns")
    props = body["properties"] || %{}

    assert is_binary(props["createdAt"]) and props["createdAt"] != "",
           "SB createdAt enrichment regressed: #{inspect(props)}"

    refute Map.has_key?(props, "created_at"), inspect(props)
  end
end
