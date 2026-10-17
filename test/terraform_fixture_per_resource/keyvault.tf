# Per-resource plan fixture: key vault.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-keyvault"
  location = "smalt-local"
}

resource "azurerm_key_vault" "probe" {
  name                = "kv-smalt-tf-probe"
  resource_group_name = azurerm_resource_group.probe.name
  location            = "smalt-local"
  sku_name            = "standard"
  tenant_id           = "00000000-0000-0000-0000-000000000000"
}
