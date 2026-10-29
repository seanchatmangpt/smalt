# ------------------------------------------------------------------------------
# Blob storage: 5 containers. The storage ACCOUNT itself is deliberately the
# unsupported-type path (azurerm_storage_account is outside smalt scope) --
# the scanner must COUNT it in unsupported_resource_types, never drop it.
# One container name carries a deliberate ${...} interpolation (UNRESOLVED).
# ------------------------------------------------------------------------------

# DELIBERATE unsupported type:
resource "azurerm_storage_account" "ordersdata" {
  name                     = "ordersdata${var.environment}"
  resource_group_name      = var.resource_group
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

resource "azurerm_storage_container" "order_export" {
  name                  = "order-exports"
  storage_account_name  = azurerm_storage_account.ordersdata.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "payment_receipts" {
  name                  = "payment-receipts"
  storage_account_name  = "ordersdataprodblobcore" # literal, resolves by value
  container_access_type = "private"
}

resource "azurerm_storage_container" "invoice_pdf" {
  name                  = "invoice-pdfs"
  storage_account_name  = azurerm_storage_account.ordersdata.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "inventory_snapshots" {
  name                  = "inventory-snapshots-${var.environment}"
  storage_account_name  = azurerm_storage_account.ordersdata.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "edi_archive" {
  name                  = "edi-archive"
  storage_account_name  = azurerm_storage_account.ordersdata.name
  container_access_type = "private"
}
