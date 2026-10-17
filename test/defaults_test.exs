defmodule Smalt.ArmGateway.DefaultsTest do
  use ExUnit.Case, async: true

  alias Smalt.ArmGateway.Defaults

  @storage "Microsoft.Storage/storageAccounts"
  @vault "Microsoft.KeyVault/vaults"
  @cosmos "Microsoft.DocumentDB/databaseAccounts"

  describe "table contents" do
    test "covers exactly the three resource families" do
      assert Map.keys(Defaults.table()) |> Enum.sort() == [@cosmos, @vault, @storage]
    end
  end

  describe "apply/2 merge semantics" do
    test "empty body gets full defaults" do
      merged = Defaults.apply(@storage, %{})
      assert merged["sku"]["name"] == "Standard_LRS"
      assert merged["kind"] == "StorageV2"
      assert merged["properties"]["minimumTlsVersion"] == "TLS1_2"
      assert merged["properties"]["networkAcls"]["defaultAction"] == "Allow"
    end

    test "user wins per key; sibling defaults still land" do
      body = %{
        "sku" => %{"name" => "Premium_LRS"},
        "properties" => %{"minimumTlsVersion" => "TLS1_0"}
      }

      merged = Defaults.apply(@storage, body)
      assert merged["sku"]["name"] == "Premium_LRS"
      assert merged["properties"]["minimumTlsVersion"] == "TLS1_0"
      # sibling defaults still applied
      assert merged["kind"] == "StorageV2"
      assert merged["properties"]["supportsHttpsTrafficOnly"] == true
    end

    test "properties deep-merge: partial user properties keep defaults" do
      merged = Defaults.apply(@vault, %{"properties" => %{"enableSoftDelete" => false}})
      assert merged["properties"]["enableSoftDelete"] == false
      assert merged["properties"]["sku"]["name"] == "standard"
      assert merged["properties"]["softDeleteRetentionInDays"] == 90
    end

    test "cosmos defaults apply" do
      merged = Defaults.apply(@cosmos, %{})
      assert merged["kind"] == "GlobalDocumentDB"
      assert merged["properties"]["databaseAccountOfferType"] == "Standard"
      assert merged["properties"]["consistencyPolicy"] == %{"defaultConsistencyLevel" => "Session"}
      assert merged["properties"]["enableMultipleWriteLocations"] == false
    end

    test "unregistered type returns body unchanged" do
      body = %{"a" => 1}
      assert Defaults.apply("Microsoft.Foo/bars", body) == body
    end

    test "non-map body returned unchanged" do
      # defensive: apply/2 with a non-map body passes through
      assert Defaults.apply(@storage, nil) == nil
    end
  end

  describe "validator acceptance" do
    test "every defaulted body validates against its registry shape" do
      for {type, defaults} <- Defaults.table(),
          is_map(defaults) do
        merged = Defaults.apply(type, %{})

        assert {:ok} = Smalt.GraphLaw.Validator.validate_resource(type, merged),
               "defaults for #{type} must be validator-acceptable"
      end
    end

    test "user override merged with defaults still validates" do
      merged =
        Defaults.apply(@storage, %{
          "sku" => %{"name" => "Standard_GRS"},
          "properties" => %{"allowBlobPublicAccess" => false}
        })

      assert {:ok} = Smalt.GraphLaw.Validator.validate_resource(@storage, merged)
    end
  end

  describe "EventHub namespace enrichment" do
    test "namespace properties carry createdAt (azurerm dereferences it) plus created_at" do
      enriched =
        Defaults.enrich("Microsoft.EventHub/namespaces", "ehns", "/id/ehns", %{
          "properties" => %{}
        })

      props = enriched["properties"]
      # Intentional contract (KD-53-era EH repair robustness change, corpus-fenced
      # in test/corpus/eh_created_at.exs): BOTH spellings carried, equal ISO8601.
      assert Map.has_key?(props, "createdAt")
      assert Map.has_key?(props, "created_at")
      assert props["created_at"] == props["createdAt"]
      assert is_binary(props["createdAt"])
    end
  end
end
