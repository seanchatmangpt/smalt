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

  describe "enrich/5 merge semantics" do
    test "KeyVault vaultUri enrichment with authority resolution and deep-merge" do
      # Default without authority
      enriched = Defaults.enrich("Microsoft.KeyVault/vaults", "mykv", "/id/mykv", %{"properties" => %{}})
      assert enriched["properties"]["vaultUri"] == "https://mykv.vault.azure.net/"

      # With localhost authority normalized to 127.0.0.1
      enriched_auth = Defaults.enrich("Microsoft.KeyVault/vaults", "mykv", "/id/mykv", %{"properties" => %{}}, "http://localhost:9443")
      assert enriched_auth["properties"]["vaultUri"] == "http://127.0.0.1:9443/"

      # Deep-merge UNDER user properties: user properties win, sibling properties kept
      user_body = %{
        "location" => "eastus",
        "properties" => %{
          "sku" => %{"family" => "A", "name" => "premium"},
          "enableSoftDelete" => false
        }
      }

      merged = Defaults.enrich("Microsoft.KeyVault/vaults", "mykv", "/id/mykv", user_body, "http://localhost:9443")
      assert merged["location"] == "eastus"
      assert merged["properties"]["sku"]["name"] == "premium"
      assert merged["properties"]["enableSoftDelete"] == false
      assert merged["properties"]["vaultUri"] == "http://127.0.0.1:9443/"

      # User-supplied vaultUri wins over default
      override_body = %{
        "properties" => %{
          "vaultUri" => "https://custom-vault.example.com/"
        }
      }

      overridden = Defaults.enrich("Microsoft.KeyVault/vaults", "mykv", "/id/mykv", override_body)
      assert overridden["properties"]["vaultUri"] == "https://custom-vault.example.com/"
    end

    test "Storage primaryEndpoints enrichment and partial deep-merge" do
      enriched = Defaults.enrich(@storage, "mystore", "/id/mystore", %{"properties" => %{}})
      endpoints = enriched["properties"]["primaryEndpoints"]
      assert endpoints["blob"] == "https://mystore.blob.smalt.local/"
      assert endpoints["queue"] == "https://mystore.queue.smalt.local/"
      assert endpoints["table"] == "https://mystore.table.smalt.local/"
      assert endpoints["file"] == "https://mystore.file.smalt.local/"
      assert endpoints["web"] == "https://mystore.web.smalt.local/"

      # Partial user primaryEndpoints deep-merges: user endpoint wins, sibling endpoints retained
      partial_body = %{
        "properties" => %{
          "primaryEndpoints" => %{
            "blob" => "https://custom.blob.domain/"
          }
        }
      }

      merged = Defaults.enrich(@storage, "mystore", "/id/mystore", partial_body)
      merged_endpoints = merged["properties"]["primaryEndpoints"]
      assert merged_endpoints["blob"] == "https://custom.blob.domain/"
      assert merged_endpoints["queue"] == "https://mystore.queue.smalt.local/"
      assert merged_endpoints["table"] == "https://mystore.table.smalt.local/"
    end

    test "ServiceBus namespace enrichment deep-merges under user properties" do
      id = "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.ServiceBus/namespaces/sbns"
      user_body = %{
        "properties" => %{
          "minimumTlsVersion" => "1.3",
          "userCustomField" => "custom_val"
        }
      }

      enriched = Defaults.enrich("Microsoft.ServiceBus/namespaces", "sbns", id, user_body)
      props = enriched["properties"]

      # User overrides and additions win
      assert props["minimumTlsVersion"] == "1.3"
      assert props["userCustomField"] == "custom_val"

      # Enriched defaults land
      assert props["status"] == "Active"
      assert props["serviceBusEndpoint"] == "https://sbns.servicebus.smalt.local:443/"
      assert is_binary(props["createdAt"])
      assert is_list(props["authorizationRules"])
      assert hd(props["authorizationRules"])["name"] == "RootManageSharedAccessKey"
    end

    test "EventHub namespace enrichment deep-merges under user properties" do
      user_body = %{
        "properties" => %{
          "kafkaEnabled" => false,
          "maximumThroughputUnits" => 10
        }
      }

      enriched = Defaults.enrich("Microsoft.EventHub/namespaces", "ehns", "/id/ehns", user_body)
      props = enriched["properties"]

      assert props["kafkaEnabled"] == false
      assert props["maximumThroughputUnits"] == 10

      # Both createdAt and created_at spellings present
      assert Map.has_key?(props, "createdAt")
      assert Map.has_key?(props, "created_at")
      assert props["created_at"] == props["createdAt"]
      assert is_binary(props["createdAt"])
      assert props["status"] == "Active"
      assert props["serviceBusEndpoint"] == "https://ehns.servicebus.smalt.local:443/"
    end

    test "unregistered type or non-map input passes through unchanged" do
      unregistered_body = %{"properties" => %{"foo" => "bar"}}
      assert Defaults.enrich("Microsoft.Foo/bars", "foo", "/id/foo", unregistered_body) == unregistered_body

      non_map = "not_a_map"
      assert Defaults.enrich(@storage, "store", "/id/store", non_map) == non_map
    end
  end
end
