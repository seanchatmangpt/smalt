# Expanded example: full provider surface

Exercises **every resource type** the Go provider registers (12 types) plus the
`azurerm_client_config` data source, all against the smalt ARM plane on kind.

## Prerequisites (kind wiring)

```sh
just kind-up        # create the kind cluster `smalt` (k8s/kind-config.yaml; host 9443 -> NodePort 30943)
just kind-images    # build smalt:local and load it into the kind node
just kind-deploy    # apply the canonical deployables (smalt-backend + console)
```

The plane listens on `http://127.0.0.1:9443` on the host (NodePort mapping in
`k8s/kind-config.yaml`); no port-forward needed.

## Provider configuration

- `arm_endpoint = "http://127.0.0.1:9443"` — or export `SMALT_ARM_ENDPOINT`
  (provider falls back to env, then to `http://127.0.0.1:9443`; see
  `internal/provider/server.go`).
- `subscription_id` — the mock plane accepts the all-zeros UUID
  `00000000-0000-0000-0000-000000000000`.

## Apply / destroy under dev_overrides

The local provider binary is used via dev_overrides, so the registry is never
contacted:

```sh
export TF_CLI_CONFIG_FILE=/Users/sac/smalt/adapters/terraform-provider-smalt/dev.tfrc
cd examples/expanded

terraform init -input=false   # dev_overrides: no providers downloaded
terraform plan
terraform apply
terraform destroy
```

A warning that the provider is not installed is expected under dev_overrides.

## Type-coverage table

Every uncommented `resource` block in `main.tf` maps to a registered type,
verified against the `Metadata` `TypeName` strings in `internal/provider/*.go`
(`ProviderTypeName = "azurerm"`):

| Resource type in main.tf | Go schema file | Status |
|---|---|---|
| `azurerm_resource_group` | `internal/provider/resource_resource_group_tf.go` | PRESENT |
| `azurerm_container_app_environment` | `internal/provider/resource_container_app_environment.go` | PRESENT |
| `azurerm_container_app` | `internal/provider/resource_container_app.go` | PRESENT |
| `azurerm_key_vault` | `internal/provider/resource_key_vault.go` | PRESENT |
| `azurerm_key_vault_secret` | `internal/provider/resource_key_vault_secret.go` | PRESENT |
| `azurerm_user_assigned_identity` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_federated_identity_credential` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_role_definition` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_role_assignment` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_container_registry` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_log_analytics_workspace` | `internal/provider/resource_remaining_v1.go` | PRESENT |
| `azurerm_storage_account` | `internal/provider/resource_remaining_v1.go` | PRESENT |

Data source: `azurerm_client_config`
(`internal/provider/data_source_client_config.go`) — attributes `tenant_id`,
`subscription_id`, `client_id`, `object_id`.

## Lane note

Lane F18 owns `examples/expanded/` only. Other lanes own the Go provider
surface (`internal/provider/*.go`); if a type listed above goes missing, the
block must be commented out in `main.tf` with a loud TODO naming the type.
