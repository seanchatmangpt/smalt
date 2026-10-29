# ------------------------------------------------------------------------------
# Service Bus: 1 namespace, 4 queues, 3 topics, 4 subscriptions (12 resources).
# ------------------------------------------------------------------------------

resource "azurerm_servicebus_namespace" "orders_sb" {
  name                = "sb-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "Standard"
}

resource "azurerm_servicebus_namespace_queue" "order_intake" {
  name                = "order-intake"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  max_delivery_count  = 7
  lock_duration       = "PT1M"
}

resource "azurerm_servicebus_namespace_queue" "payment_intake" {
  name                = "payment-intake"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  max_delivery_count  = 5
  lock_duration       = "PT1M"
}

resource "azurerm_servicebus_namespace_queue" "inventory_reserve" {
  name                = "inventory-reserve"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  max_delivery_count  = 10
  lock_duration       = "PT2M"
}

resource "azurerm_servicebus_namespace_queue" "deadletter_replay" {
  name                = "deadletter-replay"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  max_delivery_count  = 3
  lock_duration       = "PT5M"
}

resource "azurerm_servicebus_topic" "order_events" {
  name                = "order-events"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
}

resource "azurerm_servicebus_topic" "payment_events" {
  name                = "payment-events"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
}

resource "azurerm_servicebus_topic" "inventory_events" {
  name                = "inventory-events"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
}

resource "azurerm_servicebus_subscription" "order_events_fulfillment" {
  name                = "fulfillment"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  topic_name          = azurerm_servicebus_topic.order_events.name
  max_delivery_count  = 5
}

resource "azurerm_servicebus_subscription" "order_events_analytics" {
  name                = "analytics"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  topic_name          = azurerm_servicebus_topic.order_events.name
  max_delivery_count  = 5
}

resource "azurerm_servicebus_subscription" "payment_events_ledger" {
  name                = "ledger"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  topic_name          = azurerm_servicebus_topic.payment_events.name
  max_delivery_count  = 8
}

resource "azurerm_servicebus_subscription" "inventory_events_restock" {
  name                = "restock"
  resource_group_name = var.resource_group
  namespace_name      = azurerm_servicebus_namespace.orders_sb.name
  topic_name          = azurerm_servicebus_topic.inventory_events.name
  max_delivery_count  = 6
}
