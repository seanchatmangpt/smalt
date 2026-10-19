# SHIM-COURT marker not used here (fixtures, not a shim); plan fixture for the
# storage family: storage account + blob container against the smalt ARM plane.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-storage"
  location = "smalt-local"
}

resource "azurerm_storage_account" "probe" {
  name                     = "t5smalttfprobestor"
  resource_group_name      = azurerm_resource_group.probe.name
  location                 = azurerm_resource_group.probe.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "probe" {
  name                  = "tf-probe-container"
  storage_account_name  = azurerm_storage_account.probe.name
  container_access_type = "private"
}
