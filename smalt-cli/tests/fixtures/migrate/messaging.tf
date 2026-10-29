# Fixture: servicebus + eventhub namespaces
resource "azurerm_servicebus_namespace" "sb" {
  name                = "smalt-sb-ns"
  location            = "westus"
  resource_group_name = "rg-smalt"
  sku                 = "Standard"
}

resource "azurerm_servicebus_namespace_queue" "jobs" {
  name                = "jobs"
  resource_group_name = "rg-smalt"
  namespace_name      = azurerm_servicebus_namespace.sb.name
  max_delivery_count  = 7
  lock_duration       = "PT1M"
}

resource "azurerm_servicebus_topic" "events" {
  name                = "events"
  resource_group_name = "rg-smalt"
  namespace_name      = azurerm_servicebus_namespace.sb.name
}

resource "azurerm_servicebus_subscription" "audit" {
  name                = "audit"
  resource_group_name = "rg-smalt"
  namespace_name      = azurerm_servicebus_namespace.sb.name
  topic_name          = azurerm_servicebus_topic.events.name
  max_delivery_count  = 3
}

resource "azurerm_eventhub_namespace" "eh" {
  name                = "smalt-eh-ns"
  location            = "westus"
  resource_group_name = "rg-smalt"
  sku                 = "Standard"
  capacity            = 2
}

resource "azurerm_eventhub" "telemetry" {
  name                = "telemetry"
  resource_group_name = "rg-smalt"
  namespace_name      = azurerm_eventhub_namespace.eh.name
  partition_count     = 4
  message_retention_in_days = 1
}

resource "azurerm_eventhub_consumer_group" "cg" {
  name                = "workers"
  resource_group_name = "rg-smalt"
  namespace_name      = azurerm_eventhub_namespace.eh.name
  eventhub_name       = azurerm_eventhub.telemetry.name
}
