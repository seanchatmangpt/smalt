resource "azurerm_resource_group" "smalt_fixture" {
  name     = "rg-smalt-fixture"
  location = "smalt-local"
}

resource "azurerm_key_vault" "smalt_fixture" {
  name                = "kv-smalt-fixture"
  resource_group_name = azurerm_resource_group.smalt_fixture.name
  location            = azurerm_resource_group.smalt_fixture.location
  sku_name            = "standard"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
}

resource "azurerm_storage_account" "smalt_fixture" {
  name                     = "smaltfixturestore"
  resource_group_name      = azurerm_resource_group.smalt_fixture.name
  location                 = azurerm_resource_group.smalt_fixture.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
