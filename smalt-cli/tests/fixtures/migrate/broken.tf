# Fixture: unparsable (unbalanced brace) -> typed error, never silent
resource "azurerm_storage_container" "broken" {
  name = "broken-container"
