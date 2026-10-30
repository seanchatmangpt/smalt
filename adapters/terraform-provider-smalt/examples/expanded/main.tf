# Expanded example root: exercises EVERY resource type the Go provider
# registers (12 types, verified against internal/provider/*.go Metadata
# TypeName strings). Provider type name is "azurerm" (server.go); the local
# binary satisfies the requirement via dev_overrides, so no version pin.
#
# Prerequisites and the apply/destroy loop live in ./README.md.

terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {}

  arm_endpoint    = "http://127.0.0.1:9443" # or export SMALT_ARM_ENDPOINT
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

# Data source: current client context (tenant/subscription/client/object IDs).
data "azurerm_client_config" "current" {}

# --- Foundation -------------------------------------------------------------

resource "azurerm_resource_group" "rg" {
  name     = "smalt-expanded-rg"
  location = "smaltlocation"

  tags = {
    managed-by = "terraform-provider-smalt"
    lane       = "F18"
  }
}

# --- Container Apps ----------------------------------------------------------

resource "azurerm_container_app_environment" "env" {
  name                = "smalt-expanded-cae"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  tags = {
    managed-by = "terraform-provider-smalt"
  }
}

resource "azurerm_container_app" "app" {
  name                         = "smalt-expanded-ca"
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"

  secret {
    name  = "db-conn"
    value = azurerm_key_vault_secret.db.value
  }

  ingress {
    target_port      = 8080
    external_enabled = true
  }

  template {
    min_replicas = 0
    max_replicas = 2

    container {
      name   = "app"
      image  = "smalt/app:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "DB_CONN"
        secret_name = "db-conn"
      }
    }
  }

  tags = {
    managed-by = "terraform-provider-smalt"
  }
}

# --- Key Vault ---------------------------------------------------------------

resource "azurerm_key_vault" "kv" {
  name                = "smalt-expanded-kv"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

resource "azurerm_key_vault_secret" "db" {
  name         = "db-conn"
  value        = "Server=tcp:127.0.0.1;Database=smalt;"
  key_vault_id = azurerm_key_vault.kv.id
}

# --- Managed identity + federated credential --------------------------------

resource "azurerm_user_assigned_identity" "uai" {
  name                = "smalt-expanded-uai"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "fic" {
  name                      = "smalt-expanded-fic"
  resource_group_name       = azurerm_resource_group.rg.name
  user_assigned_identity_id = azurerm_user_assigned_identity.uai.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:smalt/terraform-provider-smalt:ref:refs/heads/main"
}

# --- RBAC (role definition + assignment) -------------------------------------

resource "azurerm_role_definition" "rd" {
  name        = "smalt-expanded-custom-role"
  scope       = azurerm_resource_group.rg.id
  description = "Custom read-only role scoped to the expanded example RG"

  permissions {
    actions = ["*/read"]
  }

  assignable_scopes = [azurerm_resource_group.rg.id]
}

resource "azurerm_role_assignment" "ra" {
  name                 = "smalt-expanded-ra"
  scope                = azurerm_resource_group.rg.id
  role_definition_name = azurerm_role_definition.rd.name
  principal_id         = azurerm_user_assigned_identity.uai.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Observability / storage / registry --------------------------------------

resource "azurerm_container_registry" "acr" {
  name                = "smaltexpandedacr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "smalt-expanded-law"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
}

resource "azurerm_storage_account" "sa" {
  name                     = "smaltexpandedsa"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# --- Outputs ------------------------------------------------------------------

output "client_config" {
  value = {
    tenant_id       = data.azurerm_client_config.current.tenant_id
    subscription_id = data.azurerm_client_config.current.subscription_id
    client_id       = data.azurerm_client_config.current.client_id
    object_id       = data.azurerm_client_config.current.object_id
  }
}

output "resource_group_id" {
  value = azurerm_resource_group.rg.id
}
