# scripts/tf_fixtures/main.tf — smalt terraform fixture (re-authored fresh
# v26.10.19; predecessor test/terraform_fixture deleted at 64f6099).
#
# Deliberately standard HCL — smalt is exercised against unmodified
# Terraform input. Resource NAMES are part of downstream contracts
# (22-native verify asserts rg-smalt-fixture / kv-smalt-fixture /
# t5smaltfixturestore) and are preserved exactly; everything else is
# re-authored wording.
resource "azurerm_resource_group" "smalt_fixture" {
  # ARM-face resource group the other two resources live in.
  name     = "rg-smalt-fixture"
  location = "smalt-local"
}

resource "azurerm_key_vault" "smalt_fixture" {
  # Standard-sku vault on the all-zero dev tenant.
  name                = "kv-smalt-fixture"
  resource_group_name = azurerm_resource_group.smalt_fixture.name
  location            = azurerm_resource_group.smalt_fixture.location
  sku_name            = "standard"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
}

resource "azurerm_storage_account" "smalt_fixture" {
  # LRS storage account (read-your-write fixture surface).
  name                     = "t5smaltfixturestore"
  resource_group_name      = azurerm_resource_group.smalt_fixture.name
  location                 = azurerm_resource_group.smalt_fixture.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
