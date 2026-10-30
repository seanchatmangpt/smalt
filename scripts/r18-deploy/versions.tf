# scripts/r18-deploy/versions.tf — r18 deploy-loop court fixture (lane S5).
# Wire-compat pins mirror scripts/tf_fixtures (azurerm 4.54.0 / azapi 2.4.0);
# endpoint redirection uses ONLY standard upstream provider configuration
# (metadata_host attribute — the receipted azurerm 4.x surface, see
# scripts/tf_fixtures_per_resource/endpoints.tf). Port defaults are the
# lane-S5 lease (29443/29444); the court script passes them explicitly.
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

variable "arm_metadata_host" {
  description = "Loopback ARM TLS twin (metadata/endpoints document host)."
  type        = string
  default     = "127.0.0.1:29444"
}

provider "azurerm" {
  features {}

  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000000"
  metadata_host                   = var.arm_metadata_host
}

provider "azapi" {
  # Endpoint routing rides the ARM_METADATA_HOSTNAME / ARM_* env surface the
  # court script exports (same pattern scripts/tf_fixtures relies on); no
  # subscription_id needed on azapi (parent ids carry the subscription).
}
