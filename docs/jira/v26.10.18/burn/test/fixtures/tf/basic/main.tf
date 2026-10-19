terraform {
  required_version = ">= 1.8.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
  }
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"

  subscription_id = "00000000-0000-0000-0000-000000000000"
}

# AZB-05 control-plane fixture: the two resource classes the control-plane
# court exercises (storage account PUT is the Accept surface in
# test/azsim/control_plane_test.exs). Standard azurerm; all sentinel GUIDs.
resource "azurerm_resource_group" "basic" {
  name     = "rg-azb05-basic"
  location = "smalt-local"
}

resource "azurerm_storage_account" "basic" {
  name                     = "azb05basicstore01"
  resource_group_name      = azurerm_resource_group.basic.name
  location                 = azurerm_resource_group.basic.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
