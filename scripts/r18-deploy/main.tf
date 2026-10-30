# scripts/r18-deploy/main.tf — courtroom-platform-az Container Apps deploy
# loop against the smalt loopback control plane (lane S5, census rows
# R13/R14 of docs/jira/v26.10.29/receipts/r14-consumer-azure-census.md).
#
# The expressed topology is the REAL one the consumer README documents
# (README.md:3-5: "Each tenant runs as its own frontend and backend
# container app in a shared Container Apps environment"):
#
#   resource group
#   + Log Analytics workspace        (R12: telemetry landing / KQL face)
#   + data collection rule           (R12: ingest pipeline face)
#   + ACR registry                   (image identity; ACR emulation plane)
#   + storage account  courtsmaltacr (ACR blob-backed repo store, receipted
#                                     design: repositories = containers)
#   + per-tenant container-app PAIR  (R14: tenant-config projection,
#                                     for_each over var.tenants)
#   + managed environment            (real topology member)
#   + Azure Cache for Redis          (real topology member)
#   + user-assigned identity         (real topology member)
#
# Registry admission honesty (census R2): smalt admits
# Microsoft.App/containerApps, Microsoft.OperationalInsights/workspaces and
# Microsoft.Insights/dataCollectionRules are admitted (managedEnvironments
# additionally rides the mid-wave ContainerAppsRouter runtime plane from
# lane S2). Microsoft.Cache/redis and
# Microsoft.ManagedIdentity/userAssignedIdentities are NOT admitted ontology
# individuals today, so their PUTs are typed-refused (graphlaw refusal).
# Those two ride `count = var.land_extension_types ? 1 : 0`: the default
# apply lands the full served graph (exit 0); the census leg re-applies with
# the variable on and asserts the TWO TYPED refusals — the refusal output IS
# the census-open evidence.

variable "land_extension_types" {
  description = "Apply the two registry-absent topology members (redis, user-assigned identity). Off by default: the primary apply lands the served graph only."
  type        = bool
  default     = false
}

variable "tenants" {
  description = "Tenant-config projection (census R14): one frontend+backend container-app pair per tenant, shaped after packages/tenant-config/src/schema.ts (slug + canonical hostname + redirects)."
  type = list(object({
    slug      = string
    canonical = string
  }))
  default = [
    { slug = "alpha", canonical = "alpha.courtroom.example" },
    { slug = "beta", canonical = "beta.courtroom.example" },
  ]
}

variable "image_tag" {
  description = "Consumer image tag (the courtroom-platform-az HEAD SHA the images are built from)."
  type        = string
  default     = "338caed"
}

variable "ai_ingestion_endpoint" {
  description = "Application Insights ingest endpoint the deployed apps' APPLICATIONINSIGHTS_CONNECTION_STRING points at (the smalt Breeze face)."
  type        = string
  default     = "http://127.0.0.1:29445/"
}

locals {
  sub          = "00000000-0000-0000-0000-000000000000"
  rg           = "rg-courtroom-az"
  location     = "smalt-local"
  registry     = "courtsmaltacr"
  login_server = "${local.registry}.azurecr.io"
  env_id       = "/subscriptions/${local.sub}/resourceGroups/${local.rg}/providers/Microsoft.App/managedEnvironments/courtroom-env"
  ikey         = "r18a2f60-0000-4000-8000-000000000001"
  ai_conn_str  = "InstrumentationKey=${local.ikey};IngestionEndpoint=${var.ai_ingestion_endpoint}"

  # One pair per tenant (README.md:3-5). Each pair member carries the slice
  # of the consumer's env-var contract (census "Consumer env-var contract",
  # 29 names) that its role reads; both carry the AI connection string so
  # deployed-app telemetry rides the same Breeze face the census leg POSTs.
  app_pairs = merge([for t in var.tenants : merge(
    {
      "${t.slug}-api" = {
        slug      = t.slug
        role      = "api"
        port      = 8080
        repo      = "courtroom-api"
        canonical = t.canonical
      }
    },
    {
      "${t.slug}-web" = {
        slug      = t.slug
        role      = "web"
        port      = 3000
        repo      = "courtroom-web"
        canonical = t.canonical
      }
    }
  )]...)

  api_env = [
    { name = "PORT", value = "8080" },
    { name = "NODE_ENV", value = "production" },
    { name = "REDIS_URL", value = "rediss://redis-courtroom:6380" },
    { name = "SESSION_SECRET", value = "smalt-dev-session-secret" },
    { name = "APPLICATIONINSIGHTS_CONNECTION_STRING", value = local.ai_conn_str },
    { name = "AUTH_ALLOWED_GROUP_IDS", value = "smalt-admin" },
    { name = "COOKIE_SECURE", value = "true" },
    { name = "TRUST_PROXY", value = "loopback, linklocal, uniquelocal, 100.64.0.0/10" },
  ]

  # Web-role env common slice; the per-tenant members (BACKEND_URL → the
  # tenant's api app, CANONICAL_ORIGIN → the tenant's canonical host) are
  # appended per-instance in the container body where each.value is in scope.
  web_env_base = [
    { name = "PORT", value = "3000" },
    { name = "NODE_ENV", value = "production" },
    { name = "APPLICATIONINSIGHTS_CONNECTION_STRING", value = local.ai_conn_str },
  ]
}

resource "azurerm_resource_group" "courtroom" {
  name     = local.rg
  location = local.location
}

# ---- R12: telemetry landing plane ------------------------------------------

resource "azapi_resource" "workspace" {
  type                      = "Microsoft.OperationalInsights/workspaces@2020-08-01"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = "log-courtroom"
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body = {
    properties = {
      workspaceCapping = { dataVolumeCap = "2GB" }
    }
  }
}

resource "azapi_resource" "dcr" {
  type                      = "Microsoft.Insights/dataCollectionRules@2022-06-01"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = "dcr-courtroom"
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body = {
    properties = {
      dataFlow = [{ streams = ["Custom-AppTraces"], destinations = ["log-courtroom"] }]
    }
  }
}

# ---- image identity (ACR emulation plane) -----------------------------------

resource "azapi_resource" "acr" {
  type                      = "Microsoft.ContainerRegistry/registries@2023-06-01-preview"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = local.registry
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body = {
    sku        = { name = "Basic" }
    properties = { adminUserEnabled = true }
  }
}

# The ACR emulation's blob-backed repo store (receipted design: repositories
# = blob containers of the registry-named account, tags = blob names) — the
# repos the deployed images resolve against.
resource "azurerm_storage_account" "acr_store" {
  name                     = local.registry
  resource_group_name      = azurerm_resource_group.courtroom.name
  location                 = azurerm_resource_group.courtroom.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "acr_repos" {
  for_each              = toset(distinct([for p in local.app_pairs : p.repo]))
  name                  = each.key
  storage_account_name  = azurerm_storage_account.acr_store.name
  container_access_type = "private"
}

# ---- census-open topology members: registry-admission REFUSES these (typed) ----

resource "azapi_resource" "managed_env" {
  # S2 landed the Microsoft.App runtime plane mid-wave (ContainerAppsRouter):
  # managedEnvironments is SERVED, so the managed env lands in the default
  # apply — no longer census-open.

  type                      = "Microsoft.App/managedEnvironments@2023-05-01"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = "courtroom-env"
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body = {
    properties = {
      appsLogsToMonitorWorkspace = true
    }
  }
}

resource "azapi_resource" "redis" {
  count = var.land_extension_types ? 1 : 0

  type                      = "Microsoft.Cache/redis@2023-08-01"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = "redis-courtroom"
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body = {
    properties = { enableNonSslPort = false }
    sku        = { name = "Basic", family = "C", capacity = 1 }
  }
}

resource "azapi_resource" "identity" {
  count = var.land_extension_types ? 1 : 0

  type                      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = "id-courtroom"
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []
  body                      = {}
}

# ---- per-tenant container-app pairs (census R14) -----------------------------

resource "azapi_resource" "container_app" {
  for_each = local.app_pairs

  type                      = "Microsoft.App/containerApps@2023-05-01"
  parent_id                 = azurerm_resource_group.courtroom.id
  name                      = each.key
  location                  = azurerm_resource_group.courtroom.location
  schema_validation_enabled = false
  response_export_values    = []

  body = {
    properties = {
      managedEnvironmentId = local.env_id
      configuration = {
        ingress = {
          external   = true
          targetPort = each.value.port
          transport  = "auto"
        }
      }
      template = {
        containers = [
          {
            name  = "${each.value.slug}-${each.value.role}"
            image = "${local.login_server}/${each.value.repo}:${var.image_tag}"
            env = each.value.role == "api" ? local.api_env : concat(local.web_env_base, [
              { name = "BACKEND_URL", value = "http://${each.value.slug}-api:8080" },
              { name = "CANONICAL_ORIGIN", value = "https://${each.value.canonical}" },
            ])
            resources = {
              cpu    = 0.5
              memory = "1Gi"
            }
          }
        ]
        scale = {
          minReplicas = 1
          maxReplicas = 1
        }
      }
    }
  }
}

output "login_server" {
  value = local.login_server
}

output "container_app_ids" {
  value = { for k, v in azapi_resource.container_app : k => v.id }
}

output "workspace_id" {
  value = azapi_resource.workspace.id
}
