# Fixture: blob storage container
resource "azurerm_storage_container" "blobs" {
  name                  = "artifacts"
  storage_account_name  = "smaltacct"
  container_access_type = "private"
}
