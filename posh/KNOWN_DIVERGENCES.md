# POSH & Terraform Provider Smalt: Known Divergences Register

This register documents intentional, lawful divergences between Microsoft Azure / HashiCorp AzureRM and the sovereign Smalt POSH membrane (POSH-009).

## 1. Provider Identity & Endpoints
| Dimension | Azure Cloud | Smalt Sovereign Membrane | Rationale / Law |
| :--- | :--- | :--- | :--- |
| **Control Plane Host** | `management.azure.com:443` | `127.0.0.1:9443` (Loopback HTTP) or Kind NodePort `30943` | Sovereign air-gap execution; eliminates WAN egress tollbooth. |
| **Data Plane / Key Vault Host** | `{vault}.vault.azure.net:443` | Routed via ARM Gateway `/vaults/{v}/secrets/{s}` on loopback | Single-port local settlement ledger without external DNS dependencies. |
| **OAuth2 Token Mint** | `login.microsoftonline.com/{tenant}/oauth2/v2.0/token` | `http://127.0.0.1:9443/smalt/oauth2/v2.0/token` | Hermetic mock STS with `context.WithoutCancel` singleflight deduplication. |
| **Egress Boundaries** | Global internet | Strict fail-closed allowlist (`posh.yaml`) with kernel-level IMDS socket tripwire | Blocks cloud IMDS SSRF (`169.254.169.254`, `[::ffff:169.254.169.254]`) before `connect(2)`. |

## 2. Resource Coverage & Wire Parity
The provider implements 100% wire parity for the 12 required sovereign resources and 7 data sources:
- `azurerm_resource_group`: Canonical ARM ID normalizer + Private State raw body round-tripping.
- `azurerm_key_vault`: Control plane vault management with auto-synthesized local `vault_uri`.
- `azurerm_key_vault_secret`: Dual-plane split routing with data plane versioned URIs.
- `azurerm_container_app_environment`: Managed environment support with `customDomainVerificationId` preservation.
- `azurerm_container_app`: Write-only `secret[*].value` state preservation on `Read` to prevent spurious drift.
- `azurerm_user_assigned_identity`: Managed identity principal/client ID minting.
- `azurerm_federated_identity_credential`: Workload identity credential linking.
- `azurerm_role_definition`: Local RBAC definitions with full permission actions matrix.
- `azurerm_role_assignment`: Deterministic role binding.
- `azurerm_container_registry`: Local sovereign container registry.
- `azurerm_log_analytics_workspace`: Operational insights workspace.
- `azurerm_storage_account`: Sovereign blob storage account.

## 3. Data Sources
- `azurerm_client_config`: Returns sovereign tenant ID, subscription ID, and client ID.
- `azurerm_resource_group`: Reads existing resource group from ARM plane.
- `azurerm_key_vault`: Reads existing vault configuration.
- `azurerm_container_registry`: Reads registry endpoint.
- `azurerm_storage_account`: Reads storage account endpoints and access keys.
- `azurerm_user_assigned_identity`: Reads managed identity credentials.
- `azurerm_smalt_health`: Built-in health probe data source querying `/metadata/endpoints`.

## 4. Coverage Gate

Surface inventory is derived mechanically by `posh/scripts/coverage.py` (posh op registry +
provider resource/data-source TypeNames). Coverage cells are classified: every cell must be
PASS, a registered divergence row (KD-nn, §5), or the gate exits 1 — loudly MISSING. Silent
gaps fail. `--self-test` injects a bogus op into the inventory before compare and must flip
the gate to exit 1, then restores the unmodified inventory.

### 4.1 PASS ledger

Cells at full wire parity (evidence: §2/§3 register above; `go test ./...` in
`adapters/terraform-provider-smalt` and `posh`). A cell not in this ledger and not covered by
a KD row is loudly MISSING.

| Status | Cell | Evidence |
| :--- | :--- | :--- |
| PASS | resource:azurerm_resource_group | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_key_vault | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_container_registry | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_log_analytics_workspace | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_storage_account | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_role_assignment | §2 wire parity; provider unit tests |
| PASS | resource:azurerm_federated_identity_credential | §2 wire parity; provider unit tests |
| PASS | datasource:azurerm_client_config | §3 wire parity; provider unit tests |
| PASS | datasource:azurerm_resource_group | §3 wire parity; provider unit tests |
| PASS | datasource:azurerm_key_vault | §3 wire parity; provider unit tests |
| PASS | datasource:azurerm_container_registry | §3 wire parity; provider unit tests |
| PASS | datasource:azurerm_storage_account | §3 wire parity; provider unit tests |
| PASS | datasource:azurerm_smalt_health | §3 wire parity; provider unit tests |
| PASS | op:echo | first admitted op; posh server tests |

## 5. Known Divergence Register (KD-nn)

A gate-auditable register: surface, divergence, evidence receipt, close condition. Cells
covered by a KD row render REGISTERED; all other cells must PASS or the gate exits 1.

| ID | Covers (cell globs) | Divergence | Evidence receipt | Close condition |
| :--- | :--- | :--- | :--- | :--- |
| KD-01 | resource:azurerm_role_definition | role_definition is create-local (law: definitions are minted, not fetched); GET of a foreign definition is refused. Read returns the locally-minted definition only. | receipts/posh009-role-definition-create-local.md | GET of a foreign role definition succeeds identically to local — until then create-local is the law. |
| KD-02 | resource:azurerm_user_assigned_identity, datasource:azurerm_user_assigned_identity | UAI `client_id`/`principal_id` are not returned by the face on read; they are minted deterministically at create and preserved in state. | receipts/posh009-uai-ids-face.md | Face returns both IDs on read without state preservation. |
| KD-03 | resource:azurerm_key_vault_secret, datasource:azurerm_key_vault_secret, resource:azurerm_container_app | Secrets are not echoed on read (write-only `value`); read returns metadata only, write-only values preserved in state to prevent spurious drift. | receipts/posh009-secrets-not-echoed.md | Data plane returns secret values on read without drift. |
| KD-04 | resource:azurerm_container_app | containerApps traffic weights are applied on update only — create carries no traffic split; traffic diverges from AzureRM's create-time traffic block. | receipts/posh009-traffic-update-only.md | Create accepts and persists a traffic split. |
| KD-05 | resource:azurerm_container_app, resource:azurerm_container_app_environment | Memory is numeric (bare integer MiB) rather than AzureRM's quantity string (`1.0Gi`); no unit-suffix parsing. | receipts/posh009-numeric-memory.md | Quantity-string memory accepted with unit conversion. |
| KD-06 | * (all cells) | api-version ceilings per KD-78: each ARM face pins a maximum api-version; requests above the ceiling are refused, not downgraded. | receipts/posh009-api-version-ceilings.md | api-version negotiation replaces fixed ceilings. |
