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
| PASS | resource:azurerm_role_definition | CLOSED KD-01 (2026-10-30 lane C1): face mounts roleDefinitions GET/PUT/DELETE (`resource_providers.ex:4550-4566`); provider performs real PUT/GET/DELETE (`resource_remaining_v1.go:1043-1260`); `go test ./...` green |
| PASS | op:echo | first admitted op; posh server tests |

## 5. Known Divergence Register (KD-nn)

A gate-auditable register: surface, divergence, evidence receipt, close condition. Cells
covered by a KD row render REGISTERED; all other cells must PASS or the gate exits 1.
Covers-cell law (2026-10-30, wave-2 lane 4): the Covers column holds fnmatch cell globs
only — whitespace-free, no bare `*`, and each row must cover >= 1 inventory cell. The gate
(`posh/scripts/coverage.py`) exits 2 on prose globs, bare `*` (which would register the
`--self-test` bogus-op injection — vacuous flip), and any row covering zero cells;
previously these were silent-skipped (KD-06's `* (all cells)` prose matched 0 cells while
claiming all of them).

| ID | Covers (cell globs) | Divergence | Evidence receipt | Close condition |
| :--- | :--- | :--- | :--- | :--- |
| KD-02 | resource:azurerm_user_assigned_identity, datasource:azurerm_user_assigned_identity | UAI `client_id`/`principal_id` are not returned by the face on read. Honesty law (2026-10-30, lane C2): absent prior state, a deterministic mint is REFUSED with a typed error; `TFPOSH_ALLOW_FABRICATED_IDS=1` downgrades to a loud warning + mint. Data source was silent-mint; now error-by-default. | `TFPOSHT_LIVE=1` roundtrips green; carryOrMintIdentityAttr (resource_remaining_v1.go), data_sources_v1.go UAI Read | Face returns both IDs on read without state preservation. |
| KD-03 | resource:azurerm_key_vault_secret, datasource:azurerm_key_vault_secret, resource:azurerm_container_app | Divergence polarity UPDATED 2026-10-30 (gap lane 23; live wire probe receipt `docs/jira/posh/v26.10.30/gaps/23-secret-echo-staleness.md`): the smalt ARM control-plane face (`vaults/:v/secrets/:s` GET) now ECHOES `properties.value` exactly (rendered verbatim from the stored record, `resource_providers.ex` `handle_child_get`) — opposite polarity to the previously registered "never echoed"; real Azure ARM omits the value. The 8443 data-plane face and deleted-secret bundles still never echo (`secrets.ex` public record drops `value`). Provider Read is disjunctive (adopts an exact echo, else preserves prior state — `resource_key_vault_secret.go:365-368`, `live_f4_test.go:323-333`); container-app wire secrets remain never-echoed (distinct face). | gaps/23-secret-echo-staleness.md (live probe: vault PUT 202, secret PUT 201, secret GET 200 with `properties.value` echoed) | ARM face omits `properties.value` on GET (real-Azure parity) — or the echo is accepted-and-registered as the standing disjunctive law; silent re-flip in either direction is the failure class. |
| KD-04 | resource:azurerm_container_app | containerApps traffic weights are applied on update only — create carries no traffic split; traffic diverges from AzureRM's create-time traffic block. | receipts/posh009-traffic-update-only.md | Create accepts and persists a traffic split. |
| KD-05 | resource:azurerm_container_app, resource:azurerm_container_app_environment | SPLIT 2026-11-04 by dialect column (CORE \| POSH-MEMBRANE). **POSH-MEMBRANE half CLOSED**: family_translate.go:28 ParseMemoryGiB ports the provider's parseMemoryGiB (unit-stripping Gi/G/Mi/M quantity parse, 0.5 GiB fallback) and its mutation court TestMutationKD05WrongTranslationFails (family_translate_test.go:60) proves wrong translation fails. **CORE half OPEN**: the BEAM containerApps face still stores bare numeric MiB with no quantity-string unit parsing (`grep -rn "GiB\|MiB" lib/smalt --include="*.ex"` returns only unrelated transport caps, no memory parse — witness `docs/jira/v26.10.31/receipts/kd09-witness.md`). | receipts/posh009-numeric-memory.md; docs/jira/v26.10.31/receipts/kd09-witness.md | CORE: BEAM containerApps face accepts AzureRM-style quantity-string memory ("1.0Gi") with unit conversion. |
| KD-06 | resource:azurerm_*, datasource:azurerm_* | api-version ceilings per KD-78: each ARM face pins a maximum api-version; requests above the ceiling are refused, not downgraded. Applies to every resource/data-source cell (all ride an ARM face); `op:*` cells are excluded so the coverage-gate `--self-test` bogus-op injection stays MISSING (non-vacuous flip). Globs are fnmatch-scoped per type — a bare `*` is refused by the gate (exit 2). | receipts/posh009-api-version-ceilings.md | api-version negotiation replaces fixed ceilings. |
| KD-07 | resource:azurerm_container_app_environment | `default_domain` fabricated as `<name>.<location>.azurecontainerapps.io` when the face omits `properties.defaultDomain` (real Azure carries a random hash segment). Honesty law (2026-10-30, lane C2): REFUSED with a typed error by default (attr reads null); loud warning + fabricated value under `TFPOSH_ALLOW_FABRICATED_IDS=1`. | resource_container_app_environment.go applyResponseToModel; `go test ./... -race` green | Face returns real `defaultDomain`. |
| KD-08 | resource:azurerm_federated_identity_credential, resource:azurerm_role_assignment | AMENDED 2026-11-04 (half-met): roleAssignments routes ARE mounted on the BEAM face — PUT/GET/GET-list/DELETE at subscription and resourceGroup scopes (`lib/smalt/arm_gateway/plug/resource_providers.ex:4392-4495`); federatedIdentityCredentials remains Registry shape admission only (no FIC routes). Original divergence (swallowed unsupported-route errors → fabricated/stale state, honesty-law fix 2026-10-30 lane C2) unchanged. | resource_remaining_v1.go FIC + role_assignment CRUD; resource_providers.ex:4392-4495 route mounts; `go test ./... -race` green; `TFPOSHT_LIVE=1` roundtrips green | BEAM face mounts the federatedIdentityCredentials routes (roleAssignments half is met). |
| KD-09 | resource:azurerm_role_assignment | CLOSED 2026-11-04: the close condition is met — `lib/smalt/policy/assignments.ex:19-33` carries `@builtin_roles` with the real Azure built-in role definition GUIDs (Owner 8e3af657-a8ff-443c-a75c-2fe8c4bcb635, Contributor b24988ac-6180-42a0-ab88-20f7382dd24c, Reader acdd72a7-3385-48ef-bd42-f606fba81ae7) and `role_definition/2` resolves by name (case-insensitive) or GUID. Flip-law: witness receipt `docs/jira/v26.10.29/receipts/r10b-policy-split.md` (mtime 2026-10-29 23:12) postdates the fix (mtime 2026-10-29 21:59); fresh BEAM-side witness `docs/jira/v26.10.31/receipts/kd09-witness.md` (mix run -e real output, 2026-11-04). Prior divergence (uuid5 local-GUID mint, loud-warning diag) superseded on the BEAM face. | resolveRoleDefinitionInput (resource_remaining_v1.go); docs/jira/v26.10.29/receipts/r10b-policy-split.md; docs/jira/v26.10.31/receipts/kd09-witness.md | ~~smalt Policy face resolves built-in role names to real definition GUIDs~~ — met; no open remainder. |

## 6. Closed rows (no longer active divergences)

- KD-01 CLOSED 2026-10-30 (v26.10.30 lane C1): the smalt ARM face mounts
  roleDefinitions GET/PUT/DELETE (`lib/smalt/arm_gateway/plug/resource_providers.ex:4550-4566`,
  `lib/smalt/arm/rbac.ex`) and the provider performs real PUT/GET/DELETE
  (`resource_remaining_v1.go` Create/Read/Update/Delete) — the row's close condition
  ("roleDefinitions PUT/DELETE land on the smalt ARM face") is met. The
  `resource:azurerm_role_definition` cell moved to the §4.1 PASS ledger. Registration pin
  12/7 unchanged (C1 flipped the resource in place, no type added).
