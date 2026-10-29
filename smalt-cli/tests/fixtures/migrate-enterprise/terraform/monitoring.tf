# ------------------------------------------------------------------------------
# Monitoring estate: DELIBERATE unsupported-type path. None of these types are
# in smalt-migrate's SUPPORTED_TYPES; the scanner must COUNT each occurrence in
# unsupported_resource_types (fail-closed), never silently drop them.
# ------------------------------------------------------------------------------

# DELIBERATE unsupported types:
resource "azurerm_resource_group" "orders_rg" {
  name     = "rg-orders-${var.environment}"
  location = var.location
}

resource "azurerm_application_insights" "orders_appi" {
  name                = "appi-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  application_type    = "web"
}

resource "azurerm_log_analytics_workspace" "orders_law" {
  name                = "law-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "PerGB2018"
}
