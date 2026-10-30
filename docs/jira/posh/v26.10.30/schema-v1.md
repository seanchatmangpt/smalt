# Provider schema face — v1 (terraform-provider-smalt)

Enumerated from disk, not invented: every `RegisterResource` / `RegisterDataSource`
call site in `adapters/terraform-provider-smalt/internal/provider/` (2026-10-30,
lane R6). The provider type name is pinned to `azurerm`
(`server.go`: `MetadataRequest{ProviderTypeName: "azurerm"}`; provider address
`registry.terraform.io/hashicorp/azurerm`).

## Resources (12)

| # | type name | source file |
|---|-----------|-------------|
| 1 | azurerm_resource_group | resource_resource_group_tf.go (default in `server.go` `Resources()`) |
| 2 | azurerm_container_app | resource_container_app.go |
| 3 | azurerm_container_app_environment | resource_container_app_environment.go |
| 4 | azurerm_key_vault | resource_key_vault.go |
| 5 | azurerm_key_vault_secret | resource_key_vault_secret.go |
| 6 | azurerm_user_assigned_identity | resource_remaining_v1.go |
| 7 | azurerm_federated_identity_credential | resource_remaining_v1.go |
| 8 | azurerm_role_definition | resource_remaining_v1.go |
| 9 | azurerm_role_assignment | resource_remaining_v1.go |
| 10 | azurerm_container_registry | resource_remaining_v1.go |
| 11 | azurerm_log_analytics_workspace | resource_remaining_v1.go |
| 12 | azurerm_storage_account | resource_remaining_v1.go |

## Data sources (7)

| # | type name | source file |
|---|-----------|-------------|
| 1 | azurerm_client_config | data_source_client_config.go (default in `server.go` `DataSources()`) |
| 2 | azurerm_resource_group | data_sources_v1.go |
| 3 | azurerm_key_vault | data_sources_v1.go |
| 4 | azurerm_container_registry | data_sources_v1.go |
| 5 | azurerm_storage_account | data_sources_v1.go |
| 6 | azurerm_user_assigned_identity | data_sources_v1.go |
| 7 | azurerm_smalt_health | data_sources_v1.go |

## dev_overrides usage

`scripts/dev_overrides.sh` idempotently writes `dev.tfrc` with an UNLABELED
`dev_overrides` block pinning `hashicorp/azurerm` to the module directory, then
prints `export TF_CLI_CONFIG_FILE="<dev.tfrc>"`. Never touches `~/.terraformrc`.
Terraform >= 1.14 rejects labeled `dev_overrides` blocks — the source-to-path
mapping must be an attribute of an unlabeled block. Build first with
`make build` (binary `terraform-provider-azurerm`, gitignored), then point
`terraform` at the override config.

Sample configurations: `examples/basic/main.tf` (dev_overrides usage) and
`examples/kind/main.tf` (real-azurerm `~> 3.110` on-smalt parity sample).
