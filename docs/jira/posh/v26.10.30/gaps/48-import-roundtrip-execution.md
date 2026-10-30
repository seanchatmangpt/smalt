# 48 Import Roundtrip Execution — per-type rows

Status: ALIVE (G36's court executed 2026-10-30, final full run 21:25:34Z,
exit 0; work dir `/tmp/import-roundtrip-court.MnuVnI`). Script:
`/Users/sac/smalt/adapters/terraform-provider-smalt/scripts/import_roundtrip_court.sh`
(adopted, amended — see "Court amendments"). Subject provider tree:
`/Users/sac/smalt/adapters/terraform-provider-smalt` (uncommitted working
tree @ main f0e0a125; consumer @ 31c58e9). Plane: kind `smalt` cluster,
PLANE=KIND (discriminator exit 2), `smalt-backend-0` 2/2 Running on image
`smalt:local` (rebuilt this session, see "Plane refresh").

## Gate

Script exit 0 with ≥5 PASS rows: **met — 9 PASS, 3 loud SKIP, exit 0.**

## Per-type rows

| # | Type | Consumer row | Result | Witness id (create→forget→import→zero-drift plan→destroy, all exit 0) |
|---|---|---|---|---|
| 1 | `azurerm_resource_group` | 1 | **PASS** | `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/irtc-rg-1793395533` |
| 2 | `azurerm_key_vault` | 4 | **PASS** | `.../irtc-kv-1793395533/providers/Microsoft.KeyVault/vaults/irtckv1793395533` |
| 3 | `azurerm_key_vault_secret` | — (parity form) | **PASS** | `.../irtc-kv-secret-1793395533/providers/Microsoft.KeyVault/vaults/irtckvs1793395533/secrets/irtc-secret` (parity ARM-path import-id override) |
| 4 | `azurerm_user_assigned_identity` | 6,7 | **SKIP (registered divergence KD-02 / GAP22-2)** | face record carries no `properties.client_id/principal_id`; create/import honestly refused by the honesty law (error-by-default, lane C2). Roundtrip would require fabrication. Close = face returns both ids on read (KD-02 falsifier). |
| 5 | `azurerm_role_assignment` | 11 (path-form scope) | **PASS** | `.../irtc-role_assignment-1793395533/providers/Microsoft.Authorization/roleAssignments/irtc-ra-1793395533` |
| 6 | `azurerm_role_definition` | — | **PASS** | `.../irtc-role_definition-1793395533/providers/Microsoft.Authorization/roleDefinitions/irtc-rd-1793395533` |
| 7 | `azurerm_container_app_environment` | 5 | **PASS** | `.../irtc-cae-1793395533/providers/Microsoft.App/managedEnvironments/irtc-cae-1793395533` |
| 8 | `azurerm_log_analytics_workspace` | 2 | **PASS** | `.../irtc-law-1793395533/providers/Microsoft.OperationalInsights/workspaces/irtc-law-1793395533` |
| 9 | `azurerm_container_registry` | 3 | **PASS** | `.../irtc-acr-1793395533/providers/Microsoft.ContainerRegistry/registries/irtcacr1793395533` |
| 10 | `azurerm_container_app` | 9,10 | **PASS** | `.../irtc-container_app-1793395533/providers/Microsoft.App/containerApps/irtc-ca-1793395533` |
| 11 | FIC (`azurerm_federated_identity_credential`) | 8 | **SKIP (KD-08)** | nested `federatedIdentityCredentials` route 404 on the smalt plane — loud, unchanged from G36's script. |
| 12 | consumer blocks 11-12 (registry-nested role assignment ids) | 12 | **SKIP (covered)** | role_assignment row courts the same parse path; nested-scope consumer ids re-courted once the GAP22 consumer-root court lands. |

All PASS rows executed the full six-stage cycle: terraform apply (live PUT
create) → state rm → terraform import (consumer id form) → id-equality check
→ `plan -detailed-exitcode` == 0 (zero drift) → destroy == 0.

## Defects found and fixed this session (all in the provider tree unless noted)

1. **Split-brain plane (substrate, root cause of run-1's 9 FAILs).** The kind
   StatefulSet ran 2 replicas behind a ClusterIP with no shared resource
   store: create PUTs landed on one pod, import GETs on the other →
   "Cannot import non-existent remote object". Witnessed via per-pod logs
   (PUT on backend-1, import GET on backend-0). Fixed by scaling
   `statefulset/smalt-backend` to 1 replica (reversible; left at 1).
2. **Stale plane image.** The kind pod served an older registry: rejected
   OperationalInsights `api-version=2022-10-01` (cap 2020-08-01) and had no
   roleDefinitions admission at all. Rebuilt `smalt:local` (release target,
   with the Dockerfile-required build contexts `ash_r2rml`, `ash_graphlaw`,
   `ggen_igniter`, `graphlaw_ex` and `SUBJECT_SHA=$(git rev-parse HEAD)`),
   `kind load`, rollout restart. law row green after.
3. **roleDefinitions not admitted under strict api-version validation**
   (smalt `lib/smalt/registry.ex`). The face mounts GET/PUT/DELETE routes
   (KD-01 says CLOSED) but the registry admission lists lacked the type, so
   the strict plane refused every request with
   `NoRegisteredProviderFound`. Added the type to `@admitted_resource_types`,
   the shape map, and the latest-version map (`=> "2022-04-01"`).
4. **container_app template lost on import** (`resource_container_app.go`).
   `applyResponseToModel` never restored `m.Template`, so the post-import
   plan always showed the template block "1 to change". Added
   `templateModelFromWire` restoring min/max replicas + containers
   (cpu/memory) from the wire response when the model carries none.
5. **role_definition import left `assignable_scopes`/`permissions` null**
   (`resource_remaining_v1.go`). ImportState now performs a real wire GET and
   seeds name/assignable_scopes/permissions via `applyRoleDefinitionWire`;
   a failed GET leaves the drift visible rather than inventing values.
6. **role_definition `assignable_scopes` schema Optional-only.** Any create
   (not just import) drifted on the next plan. Now Optional+Computed
   (upstream-azurerm parity) and Create writes back the effective
   `[scope]` default (else "unknown value after apply").
7. **Court fixture triggered the KD-09 mint.** The role_assignment fixture
   used `role_definition_id = ...rd.role_definition_id` (bare name) → KD-09
   deterministic mint rewrote the attr after apply → inconsistent-result
   error. Fixture now uses `role_definition_resource_id` (path form), which
   the plane accepts verbatim; consumer import ids are path-form too.

Court amendments (scripts/import_roundtrip_court.sh): uai row → loud SKIP
citing KD-02/GAP22-2 (was a failing roundtrip); role_assignment fixture id
form. Nothing else touched.

## Related divergences (unchanged, loud)

- KD-02 (UAI attr roundtrip): SKIP row above — registered.
- KD-08 (FIC nested route): SKIP row — registered.
- KD-09 (bare-name mint): dodged in the fixture; register row unchanged.
- GAP22-3 (lenient parsers accept wrong-type ids): NOT exercised by this
  court (all ids type-correct); still open.

## Gates run (actual exits)

- `bash scripts/import_roundtrip_court.sh` (full, final) → **exit 0**, 9 PASS.
- `go vet ./internal/provider/` → exit 0.
- `go test ./...` (provider) → `ok terraform-provider-smalt/internal/provider`.
- `bash scripts/court_plane_discriminator.sh` → PLANE=KIND (exit 2 = kind
  verdict), port 9443 probe 200.
- Independent manual witnesses (outside the court harness):
  role_definition roundtrip `plan=0` (`/tmp/rd-manual2`), role_assignment
  roundtrip `plan=0` (`/tmp/ra-manual`).

## Operational residue

- `statefulset/smalt-backend` left at 1 replica (split-brain fix). Restoring
  2 replicas re-introduces the split-brain until the backends share resource
  state — that is a substrate lane's defect to register, not this court's.
- kind node images pruned to free ENOSPC for the image load (crictl rmi
  --prune on all 3 nodes + one docker image prune on the colima host).
- Open question: run-1 uai apply passed while run-2+ honestly refuses
  (identical provider source); unexplained variance, row is SKIP either way.

See also: `docs/jira/posh/v26.10.30/gaps/22-import-formats.md` (smalt tree),
`gaps/24-cross-repo-skew.md`.
