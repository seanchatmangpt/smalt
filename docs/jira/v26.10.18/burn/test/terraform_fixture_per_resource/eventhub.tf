# Per-resource plan fixture: eventhub namespace + hub.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-ehub"
  location = "smalt-local"
}

resource "azurerm_eventhub_namespace" "probe" {
  name                = "t5-smalt-tf-probe-ehubns"
  resource_group_name = azurerm_resource_group.probe.name
  location            = "smalt-local"
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "probe" {
  name                = "t5-tf-probe-hub"
  namespace_name      = azurerm_eventhub_namespace.probe.name
  resource_group_name = azurerm_resource_group.probe.name
  partition_count     = 2
  message_retention   = 1
}
