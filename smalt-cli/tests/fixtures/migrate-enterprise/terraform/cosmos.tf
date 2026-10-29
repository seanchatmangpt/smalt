# ------------------------------------------------------------------------------
# Cosmos DB estate: 1 account, 3 databases, 8 containers.
# The account-name interpolation is DELIBERATE (typed UNRESOLVED by the scanner).
# ------------------------------------------------------------------------------

resource "azurerm_cosmosdb_account" "orders" {
  name                = "cosmos-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  offer_type          = "Standard"
}

resource "azurerm_cosmosdb_sql_database" "orders_db" {
  name                = "orders"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  offer_throughput    = 1200
}

resource "azurerm_cosmosdb_sql_database" "payments_db" {
  name                = "payments"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  offer_throughput    = 800
}

resource "azurerm_cosmosdb_sql_database" "inventory_db" {
  name                = "inventory"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  offer_throughput    = 600
}

resource "azurerm_cosmosdb_sql_container" "order_headers" {
  name                = "order-headers"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.orders_db.name
  partition_key_paths = ["/tenantId"]
  throughput          = 500
}

resource "azurerm_cosmosdb_sql_container" "order_lines" {
  name                = "order-lines"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.orders_db.name
  partition_key_paths = ["/tenantId", "/orderId"]
  throughput          = 400
}

resource "azurerm_cosmosdb_sql_container" "order_events" {
  name                = "order-events"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.orders_db.name
  partition_key_paths = ["/partitionKey"]
  throughput          = 400
}

resource "azurerm_cosmosdb_sql_container" "payment_authorizations" {
  name                = "payment-authorizations"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.payments_db.name
  partition_key_paths = ["/tenantId"]
  throughput          = 450
}

resource "azurerm_cosmosdb_sql_container" "payment_settlements" {
  name                = "payment-settlements"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.payments_db.name
  partition_key_paths = ["/tenantId", "/settlementDate"]
  throughput          = 350
}

resource "azurerm_cosmosdb_sql_container" "inventory_items" {
  name                = "inventory-items"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.inventory_db.name
  partition_key_paths = ["/sku"]
  throughput          = 300
}

resource "azurerm_cosmosdb_sql_container" "inventory_levels" {
  name                = "inventory-levels"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.inventory_db.name
  partition_key_paths = ["/warehouseId", "/sku"]
  throughput          = 300
}

resource "azurerm_cosmosdb_sql_container" "inventory_reservations" {
  name                = "inventory-reservations"
  resource_group_name = var.resource_group
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.inventory_db.name
  partition_key_paths = ["/tenantId", "/sku"]
  throughput          = 250
}
