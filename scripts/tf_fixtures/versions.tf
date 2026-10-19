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

  # Standard upstream endpoint redirection (Phase 3): the loopback metadata
  # document on the TLS twin. azurerm 4.x has NO `endpoints {}` block
  # (schema-receipted) — `metadata_host` is the upstream-standard surface.
  # Canonical annotated pattern: scripts/tf_fixtures_per_resource/endpoints.tf
  metadata_host = "127.0.0.1:9444" # bare host[:port] — azurerm prepends https://
}
