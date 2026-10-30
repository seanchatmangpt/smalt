# Basic smalt-on-kind resource group through the local dev_overrides provider.
# Requires: TF_CLI_CONFIG_FILE pointing at dev.tfrc (see ../README.md step 3).

terraform {
  required_providers {
    # No version pin: under dev_overrides the local binary satisfies the
    # requirement and the registry is never contacted.
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {}

  # smalt ARM plane on kind (NodePort mapping 9443 -> 30943, k8s/kind-config.yaml).
  arm_endpoint    = "http://127.0.0.1:9443"
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

resource "azurerm_resource_group" "rg" {
  name     = "smalt-basic-rg"
  location = "smaltlocation"
  tags = {
    managed-by = "terraform-provider-smalt"
  }
}

output "rg_id" {
  value = azurerm_resource_group.rg.id
}
