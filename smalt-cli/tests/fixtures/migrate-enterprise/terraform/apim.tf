# ------------------------------------------------------------------------------
# API Management (Terraform leg): 2 gateways.
# ------------------------------------------------------------------------------

resource "azurerm_api_management" "orders_apim" {
  name                = "apim-orders-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group
  publisher_name      = "Orders Platform"
  publisher_email     = "orders-platform@example.com"
  sku_name            = "Developer_1"
}

resource "azurerm_api_management" "partner_apim" {
  name                = "apim-partner-prod"
  location            = var.location
  resource_group_name = var.resource_group
  publisher_name      = "Partner APIs"
  publisher_email     = "partner-apis@example.com"
  sku_name            = "Developer_1"
}
