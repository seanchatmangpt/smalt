terraform {
  required_version = ">= 1.8.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.54.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.4.0"
    }
  }
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"

  subscription_id = "00000000-0000-0000-0000-000000000000"
}
