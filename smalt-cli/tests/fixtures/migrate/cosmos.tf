# Fixture: cosmos account/database/container (PRD REQ-1.1 extraction tests)
resource "azurerm_cosmosdb_account" "db" {
  name                = "smalt-cosmos-acct"
  location            = "westus"
  resource_group_name = "rg-smalt"
  offer_type          = "Standard"
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name              = "maindb"
  resource_group_name = "rg-smalt"
  account_name        = azurerm_cosmosdb_account.db.name
  offer_throughput    = 800
}

resource "azurerm_cosmosdb_sql_container" "items" {
  name                  = "items"
  resource_group_name   = "rg-smalt"
  account_name          = azurerm_cosmosdb_account.db.name
  database_name         = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths   = ["/pk"]
  throughput            = 400
}

resource "azurerm_cosmosdb_sql_container" "wide" {
  name                = "wide"
  resource_group_name = "rg-smalt"
  account_name        = azurerm_cosmosdb_account.db.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/tenant", "/id"]
}
