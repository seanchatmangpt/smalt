# Gap 01: smalt terraform provider vs azurerm ~5.12 semantics vs courtroom-platform-az usage

**DIALECT-SCOPED: dialect #1 (Azure ARM/azurerm)** — stamp added by GAP-15
wave-2 doc migration (lane 15). Decision record:
`../../../posh/v26.10.31/00-unification-dialect-decision.md`. Every gap and
close condition below stays azurerm-scoped; the neutral-core counterpart
(role definition as a vendor-neutral RBAC class in `smalt-core.ttl`) is a
forward pointer to v26.10.31 lanes 9/13, not a fix in this file.

Lane 1, 2026-10-30. Sources read on disk:

- Provider: `/Users/sac/smalt/adapters/terraform-provider-smalt/internal/provider/{server.go, data_sources_v1.go, data_source_client_config.go, resource_resource_group_tf.go, resource_key_vault.go, resource_key_vault_secret.go, resource_container_app.go, resource_container_app_environment.go, resource_remaining_v1.go, validators.go}`
- Consumer: `/Users/sac/cai/courtroom-platform-az/infra/{environments/dev/{access,platform},modules/tenant-apps}/*.tf`

Consumer surface actually used: 10 resources (`resource_group`, `log_analytics_workspace`,
`container_registry`, `key_vault`, `container_app_environment`, `user_assigned_identity`,
`federated_identity_credential`, `role_definition`, `role_assignment`, `container_app`), 6 data
sources (`resource_group`, `storage_account`, `container_registry`, `key_vault`,
`user_assigned_identity`, `client_config`), provider config (`subscription_id`,
`resource_provider_registrations = "none"`, `storage_use_azuread = true`, `features {}`), `import {}`
blocks on 12 resources, `lifecycle { prevent_destroy }` x4 and `ignore_changes` on
`template[0].container[0].image` / `template[0].revision_suffix`.

## Gap table

| # | Area | Gap | Severity | Evidence | Close condition |
|---|------|-----|----------|----------|-----------------|
| G1 | `azurerm_role_definition` | Entire resource is UNSUPPORTED: Create/Read/Update/Delete all return a typed error (`roleDefinitionUnsupported`). Consumer access env declares `azurerm_role_definition.terraform_plan` (custom role with list-secrets actions) and references its `role_definition_resource_id` in `azurerm_role_assignment.terraform_plan_list`. | **BLOCKS-CONSUMER** (access env create fails outright) | resource_remaining_v1.go:897-921; access/main.tf:126-140,152-158 | Implement roleDefinitions PUT/DELETE on the smalt ARM face (GET-only today, see resource_remaining_v1.go:891-896) or consumer removes the custom role + assignment and relies on Contributor. |
| G2 | `azurerm_user_assigned_identity` computed identity attrs | Wire face record carries no `properties.clientId/principalId`; resource `carryOrMintIdentityAttr` mints a deterministic GUID with a loud warning; **data source `azurerm_user_assigned_identity` mints the same GUIDs silently** (no warning diag). Consumer builds ~half its role assignments (github_deploy, apps identities) from the data source `principal_id`. On a real plane the minted GUID is not the Entra object id → assignments bind a non-existent principal. | **DEGRADED** (loud on resource, silent on data source) | resource_remaining_v1.go:423-435; data_sources_v1.go (UAI Read, clientID/principalID fallback mint); access/main.tf:39-51,55-63 | Smalt ARM face returns real clientId/principalId, or data source emits the same UNSUPPORTED warning diag the resource does. |
| G3 | `azurerm_role_assignment` name→GUID resolution | `role_definition_name` ("Contributor", "AcrPush", …) resolves via `mintDeterministicGUID(name\|scope)` (uuid5), NOT the Azure built-in role definition GUID. The assignment's `roleDefinitionId` therefore diverges from real Azure semantics; any real-plane PUT would target a non-existent definition GUID. | DEGRADED (accepted on smalt plane, wrong on real Azure) | resource_remaining_v1.go:1044-1074 (`resolveRoleDefinitionInput`), 1090-1093 | Resolve built-in role names via the smalt Policy GET face (same face cited at resource_remaining_v1.go:893-895) to real definition IDs; mint only as a last resort, loudly. |
| G4 | `azurerm_role_assignment` schema breadth | Missing vs azurerm 5.12: `description`, `condition`, `condition_version`, `delegated_managed_identity_resource_id`. `skip_service_principal_aad_check` is Optional here; in azurerm it is computed-only. | COSMETIC (consumer uses none of these) | resource_remaining_v1.go:956-1024 vs consumer access/main.tf:141-167 | Add the four optional attrs (pass-through to properties) whenever a consumer needs them; no work needed for this consumer. |
| G5 | FIC / role_assignment silent success on unsupported routes | FIC Create/Update/Delete and role_assignment Read/Delete swallow `isUnsupportedARMRouteError` and report success with fabricated state; role_assignment Read keeps stale state when the route is unsupported even on NotFound. Plan/apply can "succeed" while nothing landed on the wire. | DEGRADED | resource_remaining_v1.go:607-610, 644-654, 721-724, 749-751, 1146-1158, 1203-1205 | Either surface a loud UNSUPPORTED diagnostic (like role_definition does) or prove the route exists before claiming success; a skipped write must never read as a pass. |
| G6 | CAE `default_domain` (and `latest_revision_fqdn`, `ingress.fqdn`) fabrication | When the wire response omits `properties.defaultDomain`, smalt fabricates `<name>.<location>.azurecontainerapps.io`. Real Azure format is `<name>-<random-hash>.<region>.azurecontainerapps.io`. Consumer builds `web_origin`/`api_url` (module outputs, ingress APP_ORIGIN/BACKEND_URL envs) from `default_domain` — a fabricated value yields wrong public URLs baked into app config. `latest_revision_fqdn` has an analogous `<name>.internal.<location>.azurecontainerapps.io` fallback (resource_container_app.go:1303-1308). | DEGRADED | resource_container_app_environment.go:527-535 (`applyResponseToModel`); tenant-apps/main.tf locals 1-8; resource_container_app.go:1303-1308 | Smalt plane returns real `defaultDomain`; or drop the fallback and error loudly when the wire omits it (consumer reads it via outputs, so silence is worse than failure). |
| G6b | CAE other fabricated computed attrs | `static_ip_address` fallback `10.0.0.100`, `docker_bridge_cidr` `10.2.0.1/16`, `platform_reserved_cidr`, `platform_reserved_dns_ip_address`, `custom_domain_verification_id` `smalt-cae-verification-id` — all fabricated constants when wire omits. | COSMETIC (consumer references none) | resource_container_app_environment.go:536-546 | Same as G6; drop-or-error policy. |
| G7 | ImportState coverage | All 10 consumer-relevant resources implement `ImportState` (framework `ResourceWithImportState`) with ID parsing; consumer `import {}` blocks are satisfiable. Not a gap — recorded because the lane brief flagged "ImportResourceState absence (G7)": absence is FALSE for this provider. | no-gap (verified) | ImportState at resource_remaining_v1.go:404,754,924,1208,1513,1877,2230; resource_container_app.go:885; resource_container_app_environment.go:406; resource_key_vault.go:380; resource_key_vault_secret.go:337 | n/a |
| G8 | lifecycle blocks | `prevent_destroy` and `ignore_changes = [template[0].container[0].image, template[0].revision_suffix]` are Terraform-core constructs applied by the CLI against any provider; both work. The ignore_changes targets exist in the smalt schema (`revision_suffix` in template model, `image` in container model). | no-gap (verified) | tenant-apps/main.tf, resource_container_app.go:152-155, 189-192 (template/container models) | n/a |
| G9 | Provider config parity | `subscription_id`, `resource_provider_registrations`, `storage_use_azuread`, `features {}` all present in the provider schema (features with nested parity blocks). Consumer's exact provider block is schema-valid. | no-gap (verified) | server.go:56-141 | n/a |
| G10 | `data.azurerm_client_config` | Present with tenant_id/subscription_id/client_id; `object_id` is set equal to `client_id` — wrong on real Azure (object id of the caller identity ≠ app/client id). Consumer uses only `tenant_id`. | COSMETIC | data_source_client_config.go Read (state.ObjectID = clientID) | Return the real object id from the wire or drop the attr; not blocking this consumer. |
| G11 | `data.azurerm_storage_account` `primary_access_key` | Minted deterministic GUID (`mintDeterministicGUID("st-key:"+id)`), not a real key. Consumer uses only `.id`. | COSMETIC (DEGRADED if ever consumed) | data_sources_v1.go (storage Read) | Real listKeys face or loud UNSUPPORTED; unused here. |
| G12 | Validation parity | Resource-level validation is thin vs azurerm: no oneOf validators on `revision_mode`, `sku_name`, `sku`, `transport`, `principal_type`; only provider-level URL/UUID validators and RG name validators exist. Invalid values pass provider validation and fail (or silently diverge) at the plane. | COSMETIC | validators.go (only URL/UUID/oneOf helpers); resource schemas pass no Validators except resource_resource_group_tf.go:49,60 | Add oneOf validators on enum-like attrs to match azurerm error surface; DX only. |
| G13 | ACR `admin_username`/`admin_password` | Computed attrs are fabricated (`<name>` / `mintDeterministicGUID("acr-pwd:"+id)`) when admin_enabled; consumer sets `admin_enabled = false` and uses only `login_server` (correctly derived from wire or `<name>.azurecr.io` fallback). | COSMETIC | resource_remaining_v1.go:1556-1563 | Real listCredentials face; unused here. |
| G14 | `azurerm_container_app` breadth vs 5.12 | Missing azurerm 5.x surface the consumer does not use: template `volumes`, `service`, `azure_queue_scale_rule`/custom scale rules (only min/max replicas present), `ingress.ip_security_restriction` present but `included_event`... `secrets` `key_vault_secret_id` + `identity` ARE present and consumer's kv-referenced secrets survive read via `reconcileContainerAppSecrets`. `identity.principal_id`/`tenant_id` computed present. | COSMETIC | resource_container_app.go:57-105 (models), 1343-1400 (secret reconcile) | Add scale rules/volumes when a consumer needs them; current config is covered. |
| G15 | `azurerm_key_vault` alias split | Smalt carries BOTH `enable_rbac_authorization` and `rbac_authorization_enabled` (azurerm 5.x uses `rbac_authorization_enabled`). Consumer uses the azurerm name; superset is harmless but the duplicate invites drift if the two attrs are written independently. | COSMETIC | resource_key_vault.go:50-53, 115-128 | Keep one canonical attr; alias at state-migration level only. |

## Notes on what is NOT a gap (verified)

- Every attribute the consumer config references is present in the smalt schema: all
  data-source and resource computed attrs consumed (`default_domain`, `login_server`, `vault_uri`,
  `principal_id`, `client_id`, `role_definition_resource_id`, storage/rg/kv/acr `id`s) exist; the
  risk is value truthfulness (G2/G3/G5/G6), not schema shape.
- Import blocks on all 12 imported resources are supported (G7).
- `features {}`, `resource_provider_registrations = "none"`, `storage_use_azuread = true` accepted (G9).
- Key vault resource carries `purge_protection_enabled`, `soft_delete_retention_days`,
  `tenant_id`, `sku_name`, `public_network_access_enabled` — full consumer usage covered.
- Log analytics `sku`/`retention_in_days` with PerGB2018/30 defaults matching consumer config;
  note `workspace_id`/`primary_shared_key` computed attrs exist but `primary_shared_key` truthfulness
  unverified against the wire (same class as G11) — consumer does not read them.

## Standing

Verified by reading every provider schema file and every consumer .tf file on disk this session.
azurerm ~5.12 semantics cited from maintained azurerm knowledge (attribute names/requiredness for
role_assignment, role_definition, client_config, key_vault, container_app), not re-fetched from the
azurerm repo — attribute-level claims vs upstream are UNVERIFIED against the 5.12 tag; consumer-side
claims are verified on disk. Real-plane behavior of the smalt ARM face (whether
clientId/principalId/defaultDomain are actually returned) was not executed — the G2/G6 severity
ratings assume the documented fallback paths fire.

STATUS: ALIVE (read + report written; no provider code changed)

## Updates (2026-10-30, registry-sweep lane 49)

- **G1 CLOSED by C1.** `azurerm_role_definition` is LIVE on both tiers: the smalt ARM face
  mounts roleDefinitions GET/PUT/DELETE (`resource_providers.ex:4550-4566`,
  `lib/smalt/arm/rbac.ex`) and the provider performs real PUT/GET/DELETE
  (`resource_remaining_v1.go:1043-1260`). KD-01 flipped to CLOSED in
  `posh/KNOWN_DIVERGENCES.md` §6; `resource:azurerm_role_definition` moved to the §4.1 PASS
  ledger; coverage gate re-run: `7 registered / 13 pass / 0 missing / 20 cells; KD rows: 8`,
  exit 0. Registration pin 12/7 unchanged (in-place flip, no type added; crosscheck OK).
- **G7 superseded by C8** (import formats): all 12 consumer `import {}` blocks are now
  covered by executable import assertions (`import_state_test.go`, 6 test funcs; `go test
  ./... -run Import` green 2026-10-30). GAP22's GAP22-3 close condition (executable
  roundtrip assertions) is met at the assertion level.
- **ACR api-version fix noted:** the provider now pins `acrAPIVersion = "2023-06-01"`
  (`resource_remaining_v1.go:1609-1612`, ISO-base law; `2023-06-preview` normalizes to
  `2023-06-01` via version_base). G13 status unchanged (admin creds still fabricated when
  admin_enabled; consumer sets `admin_enabled = false`, unaffected).
