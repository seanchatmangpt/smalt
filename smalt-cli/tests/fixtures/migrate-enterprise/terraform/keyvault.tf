# ------------------------------------------------------------------------------
# Key Vault: 2 vaults, 6 secrets.
# ------------------------------------------------------------------------------

resource "azurerm_key_vault" "orders_kv" {
  name                = "kv-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  sku_name            = "standard"
}

resource "azurerm_key_vault" "payments_kv" {
  name                = "kv-payments-prod"
  location            = var.location
  resource_group_name = var.resource_group
  sku_name            = "premium"
}

resource "azurerm_key_vault_secret" "orders_conn" {
  name         = "orders-cosmos-conn"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.orders_kv.id
}

resource "azurerm_key_vault_secret" "orders_sb" {
  name         = "orders-sb-conn"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.orders_kv.id
}

resource "azurerm_key_vault_secret" "orders_blob" {
  name         = "orders-blob-sas"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.orders_kv.id
}

resource "azurerm_key_vault_secret" "payments_gateway" {
  name         = "payments-gateway-key"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.payments_kv.id
}

resource "azurerm_key_vault_secret" "payments_webhook" {
  name         = "payments-webhook-signing"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.payments_kv.id
}

resource "azurerm_key_vault_secret" "inventory_api" {
  name         = "inventory-api-key"
  value        = "replace-me-not-a-real-secret"
  key_vault_id = azurerm_key_vault.orders_kv.id
}
