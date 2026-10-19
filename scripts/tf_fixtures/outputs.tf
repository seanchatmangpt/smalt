# scripts/tf_fixtures/outputs.tf — re-authored fresh v26.10.19.
output "rg_id" {
  description = "Planned resource group id."
  value       = azurerm_resource_group.smalt_fixture.id
}

output "vault_uri" {
  description = "Planned key vault URI."
  value       = azurerm_key_vault.smalt_fixture.vault_uri
}

output "storage_account_id" {
  description = "Planned storage account id (connection string intentionally not exported)."
  value       = azurerm_storage_account.smalt_fixture.id
}
