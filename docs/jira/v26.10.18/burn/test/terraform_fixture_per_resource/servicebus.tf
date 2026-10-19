# Per-resource plan fixture: servicebus namespace + queue.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-sb"
  location = "smalt-local"
}

resource "azurerm_servicebus_namespace" "probe" {
  name                = "t5-smalt-tf-probe-sbns"
  resource_group_name = azurerm_resource_group.probe.name
  location            = "smalt-local"
  sku                 = "Standard"
}

resource "azurerm_servicebus_queue" "probe" {
  name     = "t5-tf-probe-queue"
  namespace_id = azurerm_servicebus_namespace.probe.id
}
