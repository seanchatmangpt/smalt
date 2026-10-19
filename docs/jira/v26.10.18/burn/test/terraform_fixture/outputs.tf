output "rg_id" {
  description = "Resource group id from the planned resources."
  value       = azurerm_resource_group.smalt_fixture.id
}

output "vault_uri" {
  description = "Key Vault URI from the planned key vault."
  value       = azurerm_key_vault.smalt_fixture.vault_uri
}

output "storage_account_id" {
  description = "Storage account id. The connection string is a secret and is intentionally not exported."
  value       = azurerm_storage_account.smalt_fixture.id
}
