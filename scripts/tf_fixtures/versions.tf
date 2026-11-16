# scripts/tf_fixtures/versions.tf — re-authored fresh v26.10.19.
# Pin set preserved (azurerm 4.54.0 / azapi 2.4.0 / tf >= 1.8.5): these are
# wire-compat pins, not style.
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

  # No automatic RP registration against the emulator.
  resource_provider_registrations = "none"

  subscription_id = "00000000-0000-0000-0000-000000000000"

  # Endpoint redirection is injected via ARM_METADATA_HOSTNAME by scripts/smalt-tf
  # (never hardcoded in committed HCL).
}
