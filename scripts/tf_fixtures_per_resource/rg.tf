# rg.tf — bare resource group. Plan/apply/no-drift probe for the ARM face of
# azurerm_resource_group against the smalt control plane. Plan-time is
# read-only (azurerm refreshes via GET, then diffs); the write happens at
# apply.
resource "azurerm_resource_group" "probe" {
  name     = "rg-smalt-tf-probe-rg"
  location = "smalt-local"
}
