# 22 Import Formats: consumer `import {}` blocks vs provider parse vs stored-id roundtrip

Status: PARTIAL (read-only census 2026-10-30; parser bodies re-read from disk this
session — no executable import roundtrip court ran against a live state, that is
the close condition for GAP22-3).

Subjects:

- consumer: `/Users/sac/cai/courtroom-platform-az` (HEAD 31c58e9)
  - `infra/environments/dev/access/imports.tf` (2 blocks)
  - `infra/environments/dev/platform/imports.tf` (10 blocks; total 12, not 11 —
    recount from disk 2026-10-30)
- substrate: `/Users/sac/smalt/adapters/terraform-provider-smalt`
  (dev-override bound to `hashicorp/azurerm` via `dev.tfrc` — every
  `azurerm_*` in the consumer resolves to this provider, not upstream azurerm)

Shared parse path: every resource's `ImportState` first calls
`NormalizeARMID` (`internal/provider/arm_client.go:490`) which canonicalizes
segment casing case-insensitively (`EqualFold`): `subscriptions`,
`resourceGroups`, `providers`, namespace names (`canonicalNamespaces`,
arm_client.go:447), and resource-type words (`canonicalResourceTypes`,
arm_client.go:460). Case sensitivity is therefore a non-issue: consumer ids
written `resourceGroups` or `resourcegroups` both normalize to the same
stored form.

## Type x (consumer-import-id / provider-parse / stored-id / roundtrip) table

Stored-id provenance: KV/CAE/CA store the ARM path when the response body has
no `id` (`resource_key_vault.go:454-457`,
`resource_container_app.go:1274-1277`,
`resource_container_app_environment.go:494-497`); v1 resources mint the id
from the built ARM path (`resource_remaining_v1.go:248, 351, 615, 966, 1368,
1700`) and normalize it. ImportState reuses the id verbatim
(`resp.State.SetAttribute(id)`), so roundtrip = normalize ∘ build ∘ normalize
— idempotent for all types below.

| # | Resource type | Consumer import id (imports.tf) | Provider ImportState parse | Stored id on create | Roundtrip |
|---|---|---|---|---|---|
| 1 | `azurerm_resource_group` (platform main) | `/subscriptions/{sub}/resourceGroups/rg-...-eus` | **NONE — no `ImportState` implemented** (`resource_resource_group_tf.go` has no `ResourceWithImportState` marker or ImportState func) | `rgID()` normalized path | **BREAK** |
| 2 | `azurerm_log_analytics_workspace` | `.../providers/Microsoft.OperationalInsights/workspaces/log-...-eus` | normalize + `extractResourceGroupFromID` + last-segment name (`resource_remaining_v1.go:2241`) | normalized ARM path | OK |
| 3 | `azurerm_container_registry` | `.../providers/Microsoft.ContainerRegistry/registries/cr...` | same lenient rg+name parse (`:1877`) | normalized ARM path | OK |
| 4 | `azurerm_key_vault` | `.../providers/Microsoft.KeyVault/vaults/kv-...-eus` | same lenient parse (`resource_key_vault.go:380`) | response id, else ARM path | OK |
| 5 | `azurerm_container_app_environment` | `.../Microsoft.App/managedEnvironments/cae-...-eus2` | same lenient parse (`resource_container_app_environment.go:406`) | response id, else ARM path | OK |
| 6 | `azurerm_user_assigned_identity.apps` | `.../Microsoft.ManagedIdentity/userAssignedIdentities/id-courtroom-apps-dev` | lenient rg+name parse (`resource_remaining_v1.go:444`) | normalized ARM path (`:351`) | PARTIAL — see GAP22-2 |
| 7 | `azurerm_user_assigned_identity.github_deploy` | `.../userAssignedIdentities/id-courtroom-github-dev` | same | same | PARTIAL — see GAP22-2 |
| 8 | `azurerm_federated_identity_credential.github_deploy` | `.../userAssignedIdentities/id-courtroom-github-dev/federatedIdentityCredentials/github-environment-dev` | lowercase-marker split → `parent_id`, `user_assigned_identity_id`, `name` (`resource_remaining_v1.go:832`); schema has all attrs (`:535-606`) | `parentID + "/federatedIdentityCredentials/" + name` (`:615`) | OK |
| 9 | module.tenant `azurerm_container_app.api` | `.../Microsoft.App/containerApps/ca-demo-api-dev` | lenient rg+name parse (`resource_container_app.go:885`) | response id, else ARM path | OK |
| 10 | module.tenant `azurerm_container_app.web` | `.../containerApps/ca-demo-web-dev` | same | same | OK |
| 11 | `azurerm_role_assignment.service["github_deploy_contributor"]` | RG-scoped `.../providers/Microsoft.Authorization/roleAssignments/{guid}` | marker split → scope+name (`resource_remaining_v1.go:1572`); marker canonicalized by NormalizeARMID first | `scope + marker + name` (`:1368`) | OK |
| 12 | `azurerm_role_assignment.service["github_deploy_acr_push"]` | registry-nested scope `.../registries/cr.../providers/Microsoft.Authorization/roleAssignments/{guid}` | same; nested namespace canonicalized by the providers-loop in NormalizeARMID (arm_client.go:506-520) | same | OK |

## Mismatch rows

- **GAP22-1 — `azurerm_resource_group` import is a hard break.** The
  resource the consumer imports (`resource_resource_group_tf.go`) implements
  no `ImportState`; terraform will refuse the `import` block with
  "resource doesn't support import". The 10 other types parse fine; the very
  first platform import block fails.
  Close: implement `ImportState` on `resource_resource_group_tf.go`
  (normalize + `SetAttribute(id, resource_group_name, name)` — the id format
  is the trivial two-segment one), plus a roundtrip test create→import with
  the same id.
- **GAP22-2 — UAI computed `client_id`/`principal_id` are empty after
  import.** `ImportState` sets only id/rg/name; `client_id`/`principal_id`
  are computed-only, so the imported state has them null, and the consumer
  outputs (`access/outputs.tf:3,8`, `platform/outputs.tf:23,28`) read null.
  First refresh then hits `carryOrMintIdentityAttr`
  (`resource_remaining_v1.go:336-340, 456+`), which REFUSES with the
  honesty-law diagnostic unless prior state carries the value — and import
  wrote no prior value. Import succeeds; the follow-on plan/refresh does not.
  Close: same class as the registered `UNSUPPORTED(attr roundtrip)` row —
  either import seeds the attrs (read-before-import against the plane) or the
  consumer plan gets a documented attr-roundtrip divergence entry.
- **GAP22-3 — silent wrong-resource adoption (all lenient parsers).** No
  `ImportState` validates that the id's segments match the resource type:
  importing a vault id into `azurerm_container_app` (or a CAE id into
  `azurerm_key_vault`) normalizes cleanly, sets name/rg from the last
  segments, stores a foreign-type id, and the subsequent Read GETs the wrong
  ARM path — adoption of a wrong-resource id is silent. Not exercised by the
  consumer today (its 12 ids are type-correct), but the parse is the shared
  copy-paste body across 8 resources.
  Close: per-type segment assertion at the top of each ImportState
  (e.g. container app requires `Microsoft.App/containerApps/`), fail-closed
  diagnostic; court = import a cross-type id into each type and require
  refusal.
- **GAP22-4 (minor) — `key_vault_secret` import truncates**:
  `resource_key_vault_secret.go:337-340` splits the normalized id and (per
  the visible body) reconstructs name from split parts; nested
  secret names with `/` are legal in Azure. Not exercised by the consumer's
  12 blocks. Close: same per-type segment assertion as GAP22-3.

## Real-Azure parity (would stored ids roundtrip as valid azurerm ids?)

Yes for all types: every stored id is a canonical ARM path
(`/subscriptions/{sub}/resourceGroups/{rg}/providers/{NS}/{type}/{name}`,
nested scope forms for role assignment/FIC preserved verbatim), which is
exactly the form upstream azurerm's `commonids` parsers accept. The only
parity gap is behavioral, not format: upstream azurerm's parsers REJECT
wrong-shape ids (their GAP22-3 equivalent cannot happen there), while the
smalt provider accepts anything slash-separated.

See also: `gaps/24-cross-repo-skew.md` (api-version matrix, same two trees).
