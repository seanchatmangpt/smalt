# SHIM-COURT-free per-resource plan fixture: bare resource group.
# Plan-only: azurerm refreshes (GET) then diffs; no writes at plan time.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-rg"
  location = "smalt-local"
}
