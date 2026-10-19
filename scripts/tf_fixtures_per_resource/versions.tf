# scripts/tf_fixtures_per_resource/versions.tf — re-authored fresh v26.10.19.
# Predecessor test/terraform_fixture_per_resource deleted at 64f6099; the
# provider pins are wire-compat pins, not style, so they are preserved
# (azurerm = 4.54.0, tf >= 1.8.5). Copied beside each per-resource main.tf by
# scripts/tf_plan_check.sh at probe time.
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

  # The emulator does not implement RP registration; keep azurerm silent.
  resource_provider_registrations = "none"

  subscription_id = "00000000-0000-0000-0000-000000000000"

  # Standard upstream endpoint redirection (Phase 3): loopback metadata
  # document on the TLS twin. azurerm 4.x has NO `endpoints {}` block
  # (schema-receipted) — `metadata_host` is the upstream-standard surface.
  # Canonical pattern: endpoints.tf (this directory).
  metadata_host = "127.0.0.1:9444" # bare host[:port] — azurerm prepends https://
}
