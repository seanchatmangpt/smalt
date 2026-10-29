# Fixture: key vault + secret + API management
resource "azurerm_key_vault" "kv" {
  name                = "smalt-vault"
  location            = "westus"
  resource_group_name = "rg-smalt"
  sku_name            = "standard"
}

resource "azurerm_key_vault_secret" "sas" {
  name         = "sas-key"
  value        = "super-secret-do-not-emit"
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_api_management" "apim" {
  name                = "smalt-apim"
  location            = "westus"
  resource_group_name = "rg-smalt"
  publisher_name      = "Smalt"
  publisher_email     = "ops@smalt.local"
  sku_name            = "Developer_1"
}
