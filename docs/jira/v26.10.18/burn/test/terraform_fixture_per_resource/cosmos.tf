# Per-resource plan fixture: cosmos account + sql database + sql container.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-cosmos"
  location = "smalt-local"
}

resource "azurerm_cosmosdb_account" "probe" {
  name                = "smalt-tf-probe-cosmos"
  location            = "smalt-local"
  resource_group_name = azurerm_resource_group.probe.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = "smalt-local"
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "probe" {
  name                = "tf-probe-db"
  resource_group_name = azurerm_resource_group.probe.name
  account_name        = azurerm_cosmosdb_account.probe.name
}

resource "azurerm_cosmosdb_sql_container" "probe" {
  name                  = "tf-probe-container"
  resource_group_name   = azurerm_resource_group.probe.name
  account_name          = azurerm_cosmosdb_account.probe.name
  database_name         = azurerm_cosmosdb_sql_database.probe.name
  partition_key_paths   = ["/pk"]
}
