terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  resource_provider_registrations = "none"
  skip_provider_registration      = true
  metadata_host                   = "127.0.0.1:9443"
  subscription_id                 = "00000000-0000-0000-0000-000000000000"
  tenant_id                       = "00000000-0000-0000-0000-000000000000"
  client_id                       = "smalt-sovereign"
  client_secret                   = "smalt-sovereign-mock-secret"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-smalt-kind-ard"
  location = "East US"
  tags = {
    env  = "sovereign"
    tier = "gold"
  }
}

resource "azurerm_key_vault" "kv" {
  name                = "kv-smalt-kind-ard"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = "00000000-0000-0000-0000-000000000000"
  sku_name            = "standard"
}

resource "azurerm_key_vault_secret" "sec" {
  name         = "db-conn"
  value        = "Server=tcp:127.0.0.1;Database=smalt;"
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_container_app_environment" "env" {
  name                = "cae-smalt-kind-ard"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_container_app" "app" {
  name                         = "ca-smalt-kind-ard"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"
  tags = {
    env  = "sovereign"
    tier = "edge"
  }

  secret {
    name  = "db-secret"
    value = azurerm_key_vault_secret.sec.value
  }

  template {
    container {
      name   = "app"
      image  = "smalt/app:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "DB_CONN"
        secret_name = "db-secret"
      }
    }
  }
}
