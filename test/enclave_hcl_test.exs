defmodule Smalt.Enclave.HclTest do
  use ExUnit.Case, async: true

  alias Smalt.Enclave.Hcl

  @baseline "test/terraform_fixture"
  @per_resource "test/terraform_fixture_per_resource"

  describe "baseline fixture dir (main.tf: rg/kv/storage)" do
    test "main.tf: three resources with string attrs and dotted refs" do
      {:ok, doc} = Hcl.parse(Path.join(@baseline, "main.tf"))

      assert [%{type: "azurerm_resource_group", name: "smalt_fixture"}, _, _] = doc.resources
      assert length(doc.resources) == 3

      rg = hd(doc.resources)
      assert rg.attrs["name"] == "rg-smalt-fixture"
      assert rg.attrs["location"] == "smalt-local"
      assert rg.line == 1

      kv = Enum.find(doc.resources, &(&1.type == "azurerm_key_vault"))
      assert kv.attrs["name"] == "kv-smalt-fixture"

      assert kv.attrs["resource_group_name"] ==
               {:ref, "azurerm_resource_group.smalt_fixture", "name"}

      assert kv.attrs["location"] == {:ref, "azurerm_resource_group.smalt_fixture", "location"}
      assert kv.attrs["sku_name"] == "standard"

      sa = Enum.find(doc.resources, &(&1.type == "azurerm_storage_account"))
      assert sa.attrs["account_tier"] == "Standard"
      assert sa.attrs["account_replication_type"] == "LRS"

      assert sa.attrs["resource_group_name"] ==
               {:ref, "azurerm_resource_group.smalt_fixture", "name"}
    end

    test "versions.tf: terraform + provider block, nested required_providers map" do
      {:ok, doc} = Hcl.parse(Path.join(@baseline, "versions.tf"))

      assert %{"azurerm" => %{attrs: attrs, line: line}} = doc.provider
      assert is_integer(line) and line > 0
      assert attrs["subscription_id"] == "00000000-0000-0000-0000-000000000000"
      assert attrs["resource_provider_registrations"] == "none"

      # features {} is an empty nested block, folded in as an (augmented) map.
      features = attrs["features"]
      assert is_map(features)

      # top-level terraform block is not a provider/resource: excluded from doc
      refute Map.has_key?(attrs, "required_providers")
    end

    test "outputs.tf: no provider, no resources" do
      {:ok, doc} = Hcl.parse(Path.join(@baseline, "outputs.tf"))
      assert doc.resources == []
      assert doc.provider == %{}
    end
  end

  describe "per-resource fixtures" do
    test "cosmos.tf: nested blocks consistency_policy + geo_location" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "cosmos.tf"))

      cosmos = Enum.find(doc.resources, &(&1.type == "azurerm_cosmosdb_account"))

      assert %{"consistency_level" => "Session"} = cosmos.attrs["consistency_policy"]
      assert is_integer(cosmos.attrs["consistency_policy"].__line__)

      assert cosmos.attrs["geo_location"]["location"] == "smalt-local"
      assert cosmos.attrs["geo_location"]["failover_priority"] == 0
      assert cosmos.attrs["resource_group_name"] == {:ref, "azurerm_resource_group.probe", "name"}
      assert is_integer(cosmos.attrs["consistency_policy"].__line__)
    end

    test "eventhub.tf: integer attrs" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "eventhub.tf"))

      ns = Enum.find(doc.resources, &(&1.type == "azurerm_eventhub_namespace"))
      assert ns.attrs["capacity"] == 1
      assert ns.attrs["sku"] == "Standard"

      hub = Enum.find(doc.resources, &(&1.type == "azurerm_eventhub"))
      assert hub.attrs["partition_count"] == 2
      assert hub.attrs["message_retention"] == 1
      assert hub.attrs["namespace_name"] == {:ref, "azurerm_eventhub_namespace.probe", "name"}
    end

    test "servicebus.tf: namespace + queue with id ref" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "servicebus.tf"))

      queue = Enum.find(doc.resources, &(&1.type == "azurerm_servicebus_queue"))
      assert queue.attrs["name"] == "t5-tf-probe-queue"
      assert queue.attrs["namespace_id"] == {:ref, "azurerm_servicebus_namespace.probe", "id"}

      ns = Enum.find(doc.resources, &(&1.type == "azurerm_servicebus_namespace"))
      assert ns.attrs["sku"] == "Standard"
    end

    test "storage.tf: account + container with private access" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "storage.tf"))

      sa = Enum.find(doc.resources, &(&1.type == "azurerm_storage_account"))
      assert sa.attrs["account_replication_type"] == "LRS"

      c = Enum.find(doc.resources, &(&1.type == "azurerm_storage_container"))
      assert c.attrs["container_access_type"] == "private"
      assert c.attrs["storage_account_name"] == {:ref, "azurerm_storage_account.probe", "name"}
    end

    test "keyvault.tf: kv probe attrs" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "keyvault.tf"))

      kv = Enum.find(doc.resources, &(&1.type == "azurerm_key_vault"))
      assert kv.attrs["name"] == "kv-smalt-tf-probe"
      assert kv.attrs["tenant_id"] == "00000000-0000-0000-0000-000000000000"
    end

    test "rg.tf: single bare resource group" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "rg.tf"))
      assert [%{type: "azurerm_resource_group", name: "probe"}] = doc.resources
      assert hd(doc.resources).attrs["name"] == "rg-smalt-tf-probe-rg"
    end

    test "per-resource versions.tf: single provider azurerm" do
      {:ok, doc} = Hcl.parse(Path.join(@per_resource, "versions.tf"))
      assert map_size(doc.provider) == 1
      assert %{attrs: %{"subscription_id" => _}} = doc.provider["azurerm"]
    end
  end

  describe "line preservation" do
    test "resource line points at its declaration" do
      {:ok, doc} = Hcl.parse(Path.join(@baseline, "main.tf"))
      kv = Enum.find(doc.resources, &(&1.type == "azurerm_key_vault"))

      # kv block is the 6th line of main.tf; storage account the 14th
      assert kv.line == 6
      assert hd(doc.resources).line == 1
      assert Enum.find(doc.resources, &(&1.type == "azurerm_storage_account")).line == 14
    end
  end

  describe "malformed input: typed errors" do
    test "unterminated string reports hcl_parse error with line" do
      err = "resource \"a\" \"b\" {\n  name = \"oops\n}\n"
      assert {:error, {:hcl_parse, _line, msg}} = Hcl.parse_string(err)
      assert is_binary(msg) and msg =~ "string"
    end

    test "missing closing brace reports hcl_parse error" do
      err = "resource \"a\" \"b\" {\n  name = \"x\"\n"
      assert {:error, {:hcl_parse, 3, _}} = Hcl.parse_string(err)
    end

    test "missing file is a typed error, not a raise" do
      assert {:error, :enoent} = Hcl.parse("test/terraform_fixture/nope.tf")
    end
  end

  describe "malformed labels -> typed {:error, {:hcl_parse, line, msg}}" do
    test "resource block with 1 label" do
      assert {:error, {:hcl_parse, line, msg}} =
               Hcl.parse_string("resource \"azurerm_resource_group\" {\n  name = \"x\"\n}\n")

      assert is_integer(line) and line >= 1
      assert msg =~ "2 labels"
    end

    test "provider block with 0 labels" do
      assert {:error, {:hcl_parse, line, msg}} =
               Hcl.parse_string("provider {\n  alias = \"x\"\n}\n")

      assert is_integer(line) and line >= 1
      assert msg =~ "1 label"
    end
  end
end
