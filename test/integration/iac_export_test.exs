defmodule SmaltTest.Integration.IacExportTest do
  @moduledoc """
  T-15 — IaC state export court (real Store, real projection walk, real
  renderers; no mocks).

  Seeds `:smalt_resources` with an RG + storage account + key vault and
  witnesses, per the ticket's single-source law: `main.bicep` carries real
  resource type strings, symbolic names derived from the fixture names, and
  outputs for keys/endpoints; the terraform flavor renders matching azurerm
  blocks plus the `terraform.tfvars` stub; and BOTH renderers consume the
  ONE intermediate model — the court calls
  `Smalt.DataPlane.IacExport.intermediate_model/1` directly and asserts the
  rendered files quote the model's expressions verbatim.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.IacExport
  alias Smalt.Store

  @table :smalt_resources
  @sub "00000000-0000-0000-0000-0000000000ix"
  @rg "rg-smalt-fixture"

  setup do
    resources = [
      %{
        "id" => String.downcase("/subscriptions/#{@sub}/resourcegroups/#{@rg}"),
        "name" => @rg,
        "type" => "Microsoft.Resources/resourceGroups",
        "location" => "eastus",
        "properties" => %{"provisioningState" => "Succeeded"}
      },
      %{
        "id" =>
          String.downcase(
            "/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.storage/storageaccounts/stsmaltfixture"
          ),
        "name" => "stsmaltfixture",
        "type" => "Microsoft.Storage/storageAccounts",
        "location" => "westus",
        "kind" => "StorageV2",
        "sku" => %{"name" => "Standard_LRS"},
        "properties" => %{
          "provisioningState" => "Succeeded",
          "supportsHttpsTrafficOnly" => true,
          "primaryEndpoints" => %{"blob" => "https://stsmaltfixture.blob.core.windows.net/"}
        }
      },
      %{
        "id" =>
          String.downcase(
            "/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.keyvault/vaults/kv-smalt-fixture"
          ),
        "name" => "kv-smalt-fixture",
        "type" => "Microsoft.KeyVault/vaults",
        "location" => "westus",
        "sku" => %{"family" => "A", "name" => "standard"},
        "properties" => %{
          "provisioningState" => "Succeeded",
          "tenantId" => "11111111-2222-3333-4444-555555555555",
          "enableSoftDelete" => true,
          "vaultUri" => "https://kv-smalt-fixture.vault.azure.net/"
        }
      }
    ]

    Enum.each(resources, fn r -> Store.put(@table, r["id"], r) end)

    on_exit(fn ->
      Enum.each(resources, fn r -> Store.delete(@table, r["id"]) end)
    end)

    {:ok, resources: resources}
  end

  # --- bicep renderer -------------------------------------------------------------

  test "bicep export renders real resource type strings, symbolic names and the fixture name literals" do
    {:ok, model} = IacExport.intermediate_model()
    bicep = Map.fetch!(IacExport.render_bicep(model), "main.bicep")

    assert bicep =~ "targetScope = 'subscription'"

    # real resource type strings (canonical casing, pinned api-versions)
    assert bicep =~ "resource rg_smalt_fixture 'Microsoft.Resources/resourceGroups@2021-04-01' = {"
    assert bicep =~ "resource stsmaltfixture 'Microsoft.Storage/storageAccounts@2023-05-01' = {"
    assert bicep =~ "resource kv_smalt_fixture 'Microsoft.KeyVault/vaults@2023-07-01' = {"

    # the fixture's names as literals; locations/SKUs filled in
    assert bicep =~ "name: 'rg-smalt-fixture'"
    assert bicep =~ "location: 'eastus'"
    assert bicep =~ "location: 'westus'"
    assert bicep =~ "kind: 'StorageV2'"
    assert bicep =~ "sku: { name: 'Standard_LRS' }"
    assert bicep =~ "sku: { family: 'A', name: 'standard' }"

    # storage/kv scope to their exported resource group
    assert bicep =~ "scope: rg_smalt_fixture"

    # outputs for endpoints/keys where the real export tool does
    assert bicep =~
             "output stsmaltfixture_primary_blob_endpoint string = stsmaltfixture.properties.primaryEndpoints.blob"

    assert bicep =~
             "output stsmaltfixture_primary_access_key string = stsmaltfixture.listKeys().keys[0].value"

    assert bicep =~ "output kv_smalt_fixture_vault_uri string = kv_smalt_fixture.properties.vaultUri"

    # runtime state is never re-declared by an export
    refute bicep =~ "provisioningState"
  end

  # --- terraform renderer ----------------------------------------------------------

  test "terraform export renders matching azurerm blocks plus the terraform.tfvars stub" do
    {:ok, model} = IacExport.intermediate_model()
    files = IacExport.render_terraform(model)

    assert MapSet.new(Map.keys(files)) == MapSet.new(["main.tf", "terraform.tfvars"])
    main_tf = Map.fetch!(files, "main.tf")

    assert main_tf =~ "resource \"azurerm_resource_group\" \"rg_smalt_fixture\""
    assert main_tf =~ "resource \"azurerm_storage_account\" \"stsmaltfixture\""
    assert main_tf =~ "resource \"azurerm_key_vault\" \"kv_smalt_fixture\""
    assert main_tf =~ "provider \"azurerm\" {"

    # blocks match the bicep story: same RG parent, same sku
    assert main_tf =~ ~r/resource_group_name\s+= azurerm_resource_group\.rg_smalt_fixture\.name/
    assert main_tf =~ ~r/account_tier\s+= "Standard"/
    assert main_tf =~ ~r/account_replication_type\s+= "LRS"/
    assert main_tf =~ ~r/sku_name\s+= "standard"/
    assert main_tf =~ ~r/tenant_id\s+= var\.tenant_id/

    # outputs: endpoint + key (sensitive)
    assert main_tf =~ "azurerm_storage_account.stsmaltfixture.primary_blob_endpoint"
    assert main_tf =~ "azurerm_storage_account.stsmaltfixture.primary_access_key"
    assert main_tf =~ "azurerm_key_vault.kv_smalt_fixture.vault_uri"
    assert main_tf =~ "sensitive = true"

    # the tfvars stub: names/locations (+ the tenant placeholder)
    tfvars = Map.fetch!(files, "terraform.tfvars")
    assert tfvars =~ ~r/^rg_smalt_fixture_name\s*= "rg-smalt-fixture"$/m
    assert tfvars =~ ~r/^rg_smalt_fixture_location\s*= "eastus"$/m
    assert tfvars =~ ~r/^stsmaltfixture_location\s*= "westus"$/m
    assert tfvars =~ ~r/^kv_smalt_fixture_name\s*= "kv-smalt-fixture"$/m
    assert tfvars =~ ~r/^tenant_id\s*= "00000000-0000-0000-0000-000000000000"$/m
  end

  # --- single-source witness -------------------------------------------------------

  test "single-source witness: both renderers consume the ONE intermediate model" do
    {:ok, store_model} = IacExport.intermediate_model()
    {:ok, rows_model} = IacExport.intermediate_model(context_rows())

    # one projection pass: the Store walk and the direct-rows walk agree
    assert rows_model == store_model
    refute store_model.outputs == []

    bicep = Map.fetch!(IacExport.render_bicep(rows_model), "main.bicep")
    main_tf = Map.fetch!(IacExport.render_terraform(rows_model), "main.tf")

    # every output the model computed is quoted VERBATIM by both renderers
    Enum.each(rows_model.outputs, fn out ->
      assert bicep =~ "output #{out.name} string = #{out.bicep}"
      assert main_tf =~ out.tf
    end)

    # the same symbolic names name the blocks in both languages
    Enum.each(rows_model.resources, fn entry ->
      assert bicep =~ entry.symbolic_name
      assert main_tf =~ entry.symbolic_name
    end)
  end

  # --- generic (unknown) types -----------------------------------------------------

  test "unknown types render a generic bicep block and an azapi terraform resource" do
    rows = [
      %{
        "id" =>
          String.downcase(
            "/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.servicefabricmesh/applications/mesh-thing"
          ),
        "name" => "mesh-thing",
        "type" => "Microsoft.ServiceFabricMesh/applications",
        "location" => "eastus",
        "properties" => %{"replicaCount" => 3}
      }
    ]

    {:ok, model} = IacExport.intermediate_model(rows)
    [entry] = model.resources
    assert entry.kind == :generic
    assert entry.api_version == "2023-01-01"

    bicep = Map.fetch!(IacExport.render_bicep(model), "main.bicep")
    assert bicep =~ "resource mesh_thing 'Microsoft.ServiceFabricMesh/applications@2023-01-01' = {"
    assert bicep =~ "replicaCount: 3"

    main_tf = Map.fetch!(IacExport.render_terraform(model), "main.tf")
    assert main_tf =~ "resource \"azapi_resource\" \"mesh_thing\""
    assert main_tf =~ ~r/type\s+= "Microsoft\.ServiceFabricMesh\/applications@2023-01-01"/
    # the generic escape hatch pulls in the azapi provider
    assert main_tf =~ "azapi = {"
  end

  # --- servicebus namespace + queue children ---------------------------------------

  test "servicebus queues nest under their namespace in both renderers" do
    ns_id = String.downcase("/subscriptions/#{@sub}/resourcegroups/#{@rg}/providers/microsoft.servicebus/namespaces/sbns-fixture")

    rows = [
      %{
        "id" => ns_id,
        "name" => "sbns-fixture",
        "type" => "Microsoft.ServiceBus/namespaces",
        "location" => "eastus",
        "properties" => %{}
      },
      %{
        "id" => ns_id <> "/queues/orders",
        "name" => "orders",
        "type" => "Microsoft.ServiceBus/namespaces/queues",
        "properties" => %{"lockDuration" => "PT1M"}
      }
    ]

    {:ok, model} = IacExport.intermediate_model(rows)

    [queue] = Enum.filter(model.resources, &(&1.kind == :servicebus_queue))
    assert queue.parent.symbolic_name == "sbns_fixture"
    refute queue.parent.existing

    bicep = Map.fetch!(IacExport.render_bicep(model), "main.bicep")
    assert bicep =~ "resource orders 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {"
    assert bicep =~ "parent: sbns_fixture"
    assert bicep =~ "lockDuration: 'PT1M'"

    main_tf = Map.fetch!(IacExport.render_terraform(model), "main.tf")
    assert main_tf =~ "resource \"azurerm_servicebus_queue\" \"orders\""
    assert main_tf =~ ~r/namespace_id\s+= azurerm_servicebus_namespace\.sbns_fixture\.id/
  end

  # --- typed refusals (row structure is never lenient) ------------------------------

  test "typed refusals: vacuous identity, non-map row, missing type, non-list rows" do
    assert {:error, {:vacuous_identity, :smalt_resources, ""}} =
             IacExport.intermediate_model([%{"id" => "", "type" => "Microsoft.Storage/storageAccounts"}])

    assert {:error, {:non_map_row, _}} = IacExport.intermediate_model(["not-a-row"])

    assert {:error, {:missing_type, _}} =
             IacExport.intermediate_model([%{"id" => "/subscriptions/s/resourcegroups/g", "name" => "g"}])

    assert {:error, {:non_list_rows, :smalt_resources}} = IacExport.intermediate_model(:nope)
  end

  # the same rows the setup seeded into the real Store (for the
  # store-walk == rows-walk equality in the single-source witness)
  defp context_rows do
    Store.list(@table)
    |> Enum.filter(fn row -> String.contains?(row["id"], @sub) end)
  end
end
