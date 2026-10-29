# ------------------------------------------------------------------------------
# Event Hubs (Terraform leg): 2 namespaces... wait, one namespace here.
# 1 namespace, 3 hubs, 4 consumer groups.
# Partition counts are pinned to 2 (EH fixed-partition pinion: "0","1" only).
# ------------------------------------------------------------------------------

resource "azurerm_eventhub_namespace" "ingest_eh" {
  name                = "eh-ingest-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "Standard"
  capacity            = 2
}

resource "azurerm_eventhub" "clickstream" {
  name                      = "clickstream"
  resource_group_name       = var.resource_group
  namespace_name            = azurerm_eventhub_namespace.ingest_eh.name
  partition_count           = 2
  message_retention_in_days = 1
}

resource "azurerm_eventhub" "iot_telemetry" {
  name                      = "iot-telemetry"
  resource_group_name       = var.resource_group
  namespace_name            = azurerm_eventhub_namespace.ingest_eh.name
  partition_count           = 2
  message_retention_in_days = 1
}

resource "azurerm_eventhub" "audit_trail" {
  name                      = "audit-trail"
  resource_group_name       = var.resource_group
  namespace_name            = azurerm_eventhub_namespace.ingest_eh.name
  partition_count           = 2
  message_retention_in_days = 1
}

resource "azurerm_eventhub_consumer_group" "clickstream_read_api" {
  name                = "read-api"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_eventhub_namespace.ingest_eh.name
  eventhub_name       = azurerm_eventhub.clickstream.name
}

resource "azurerm_eventhub_consumer_group" "clickstream_processor" {
  name                = "stream-processor"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_eventhub_namespace.ingest_eh.name
  eventhub_name       = azurerm_eventhub.clickstream.name
}

resource "azurerm_eventhub_consumer_group" "iot_read_api" {
  name                = "read-api"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_eventhub_namespace.ingest_eh.name
  eventhub_name       = azurerm_eventhub.iot_telemetry.name
}

resource "azurerm_eventhub_consumer_group" "audit_shipper" {
  name                = "audit-shipper"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_eventhub_namespace.ingest_eh.name
  eventhub_name       = azurerm_eventhub.audit_trail.name
}

# ------------------------------------------------------------------------------
# Second Event Hub namespace (payments archival) + 1 hub + 1 consumer group.
# ------------------------------------------------------------------------------

resource "azurerm_eventhub_namespace" "archive_eh" {
  name                = "eh-archive-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "Standard"
  capacity            = 1
}

resource "azurerm_eventhub" "payment_archive" {
  name                      = "payment-archive"
  resource_group_name       = var.resource_group
  namespace_name            = azurerm_eventhub_namespace.archive_eh.name
  partition_count           = 2
  message_retention_in_days = 7
}

resource "azurerm_eventhub_consumer_group" "archive_coldstore" {
  name                = "coldstore"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_eventhub_namespace.archive_eh.name
  eventhub_name       = azurerm_eventhub.payment_archive.name
}
