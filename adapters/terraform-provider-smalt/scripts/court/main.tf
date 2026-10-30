# Court fixture: one azurerm_resource_group against the smalt ARM plane.
# RG name is injected per run (-var rg_name) so runs are hermetic.

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

variable "rg_name" {
  type = string
}

provider "azurerm" {
  features {}

  arm_endpoint    = "http://127.0.0.1:9443"
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = "smaltlocation"
  tags = {
    managed-by = "terraform-provider-smalt"
    court      = "provider-court"
  }
}

output "rg_id" {
  value = azurerm_resource_group.rg.id
}
