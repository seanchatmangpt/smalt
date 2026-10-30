# Gap 02 — smalt ARM face vs real Azure ARM semantics

Lane 2 of 12 (read-mostly). Inputs:
`docs/jira/posh/v26.10.30/receipts/schema_parity_live.md` (lane F3),
`tmp/posh/archive/terraform-provider-smalt/docs/arm_face_gap_report.md`
(extracted from `tmp/posh/archive/terraform-provider-smalt-elixir-spike-20261030.tar.gz`),
live code under `/Users/sac/smalt/lib/smalt/` (re-read 2026-10-30).

Status line: **PARTIAL** — ARM face serves the consumer surface
(10 azurerm resources, plan PASS in lane F3 after G2–G6 patches), but with
api-version ceilings below real-azurerm ~5.x pins, write-face gaps on
roleDefinitions, no whatif/export-template surface, and strict-mode refusal
of types the face serves.

## 1. Gap table

| # | Area | smalt today (file:line evidence) | Real Azure / azurerm ~5.x semantics | Severity | Close condition |
|---|------|----------------------------------|-------------------------------------|----------|-----------------|
| A1 | api-version ceilings vs azurerm pins | `lib/smalt/registry.ex` `@api_versions` (e.g. resourceGroups `2023-07-01`, vaults `2023-02-01`, virtualNetworks/subnets/NIC/NSG/PE `2021-04-01`, OperationalInsights `2020-08-01`, managedClusters `2023-02-01`, FIC `2023-01-31`); gate is monotonic `version_lte?/2` in `lib/smalt/arm_gateway/plug/common.ex:277-312` | azurerm 5.x pins newer versions for several types (log-analytics workspaces `2022-10-01`, AKS `2024-02-01`, network `2023-05-01`-era, FIC `2023-08-01`, key vault `2023-07-01`). Monotonic gate admits anything ≤ ceiling, so the *newer* azurerm pins are the refused class | HIGH | Raise `@api_versions` ceilings to ≥ the azurerm-5.x pin per type (registry is ggen-projected — edit the ontology, re-project); falsifier: real `terraform plan` with the Go port's api-versions via the elixir face returns 0 `InvalidApiVersionParameter` |
| A2 | strict-mode refuses served types | `common.ex:253-276` — default permissive; `strict_version_validation` refuses un-admitted types (e.g. `Microsoft.App/managedEnvironments`, `Microsoft.ContainerRegistry/registries` are served by dedicated faces in `providers/*_router.ex` but have no `registry.ex` row) | real ARM serves exactly what its provider manifest advertises; provider and manifest never disagree | MED | Add registry rows for managedEnvironments + registries (ontology, re-project). Until then, strict-mode-on is not a legal boot for azurerm consumers |
| A3 | roleDefinitions write face | `resource_providers.ex:4496` GET-only (3 built-ins via `Smalt.Policy`); `lib/smalt/arm/rbac.ex:70` has `put_role_definition/3` law with NO route mounting it; PUT → 404 RouteNotFound (archive gap report row 6) | real ARM supports PUT/DELETE custom role definitions; azurerm `azurerm_role_definition` does PUT | MED | Mount PUT/DELETE routes over the existing `rbac.ex` law; falsifier: azurerm-shaped PUT of a custom def returns 201 and GET resolves by GUID |
| A4 | whatif / template export absent | grep over `lib/smalt/arm_gateway/`: zero `whatif`/`/export` route families; `deployments.ex` has no POST `.../preflight` or validate | real ARM: `POST .../validate`, `POST .../whatIf`, `GET .../exportTemplate` | LOW | Out of POSH scope unless the Go port's plan path needs preflight; register as known divergence (KD-nn row) rather than build |
| A5 | LRO fidelity | `lib/smalt/arm_gateway/lro.ex` — store-backed InProgress records, 202 + `Azure-AsyncOperation` + `Location` + `Retry-After`, single-writer sweeper terminal flip, fail-closed on malformed records | real ARM: 202 with those headers, poll returns operation resource; also `Location`-only (non-async) LROs for some RP families | LOW | Divergence is bounded: smalt's async-poll shape matches the envelope real azurerm's waiters consume. Register Location-only polls as KD-nn divergence only if a consumer waiter needs it |
| A6 | error envelope | `common.ex:148-180` `send_arm_error/6` — `{error: {code, message, target?, innererror{}, details?}}`, code-in-body, target on 404s only, GraphLaw refusals render 400 `InvalidResourceShape` (never 422) | real ARM error envelope matches; `innererror` present-but-empty is the real AAD/ARM shape | NONE (parity) | — |
| A7 | resource-id canonicalization | keys downcased (`provider_state.ex:87`, `tags_locks.ex:154`, `acr_router.ex:24-67`, `resource_health.ex:138-142`); container_groups router matches on downcased path but preserves original path for pass-through | real ARM is case-insensitive on ids but echoes a canonical form (`resourceGroups` mixed-case) | LOW | Divergence only if a consumer round-trips the echoed id into a case-sensitive downstream (azurerm does not). Confirm echoed `id` member casing on one GET per family; register if any family echoes client casing |
| A8 | tags law | `common.ex:100-107` + `tags_locks.ex:38-62`: full-replace PUT, null-when-empty render, 2022-09-01 tags API shape accepted; empty tags → `null` (azurerm drift-avoidance documented in-code) | matches real ARM replace-semantics and azurerm's null-normalization | NONE (parity) | — |
| A9 | locks law | `tags_locks.ex:19-30` — ReadOnly/CanNotDelete covering-scope gates, 409 `ScopeLocked` | matches real ARM lock enforcement shape | NONE (parity, unprobed at RG/sub scope live) | One live probe of RG-scope lock vs resource DELETE to keep receipt fresh |
| A10 | GraphLaw admission vs Azure type universe | `registry.ex:18-67` admits ~55 types vs the hundreds azurerm can address; non-admitted types on the generic face either 404 (no route) or GraphLaw-refuse 400 (archive report row 5, MI class — note MI rows now ADDED to registry since the archive report) | real ARM serves its full RP universe | MED | For azurerm-parity, per-consumer surface inventory (lane F3's 10-resource table) is the working admission set; widen registry only when the consumer config adds types. Register the "served-but-unadmitted" class (A2) as the risk, not the universe size itself |
| A11 | provider-schema parity (consumer-facing, from F3) | G2–G6 patched only in throwaway `/tmp/f3-provider`; G1 (AutoMTLS) + G7 (import unimplemented) unpatched in BOTH providers | Go port plans clean | HIGH (for the elixir spike) | Land G2–G6 patches into the canonical provider tree; G7 import is a registered divergence on both providers |

> CORRECTION 2026-10-30 (docs lane D1): row A11's "G7 (import
> unimplemented)" clause is STALE. `gaps/01-provider-azurerm-parity.md`
> G7 re-verified on disk that all 10 consumer-relevant resources
> implement `ImportState` (framework `ResourceWithImportState`; e.g.
> `resource_container_app_environment.go:406`) in the canonical Go
> provider — import is NOT a registered divergence. The G2–G6
> patch-location finding stands; the G7 clause is superseded by GAP1's
> no-gap (verified) row.

## 2. Which real-azurerm api-versions would smalt refuse today

Monotonic gate (`version_lte?/2`, date-only compare, `-preview` stripped) —
smalt refuses only versions **greater than** the registry ceiling (or
malformed). Against azurerm ~5.x pins:

- **Refused (ceiling below pin):** log-analytics workspaces (pin `2022-10-01`
  vs smalt `2020-08-01`), AKS managedClusters (pin `2024-02-01` vs
  `2023-02-01`), FIC (pin `2023-08-01` vs `2023-01-31`), key-vault vaults
  (pin `2023-07-01` vs `2023-02-01`), Network family (pin `2023-05-01`-era vs
  `2021-04-01`) — vnet/subnet/NIC/NSG/privateEndpoints.
- **Admitted (pin ≤ ceiling):** resourceGroups (`2021-04-01` pin ≤
  `2023-07-01`), storageAccounts (`2023-05-01` pin = ceiling),
  userAssignedIdentities (`2023-01-31` pin ≤ `2023-04-01`), CR registries
  (`2023-06-01`-preview pin, preview stripped = ceiling), locks
  (`2016-09-01`), roleAssignments (`2022-04-01` = ceiling), diagnostic
  settings (`2021-05-01-preview` = ceiling).

azurerm pins are cited from azurerm 5.x SDK pins, not re-verified against
provider source this session — the falsifier for the whole list is one
`terraform plan` of the consumer config against the elixir face counting
`InvalidApiVersionParameter` per type.

## 3. Standing vocabulary

- ARM face per consumer surface: ALIVE (lane F3 plan PASS after patches; archive
  live-probe report shows 201/202/200 across 9 families).
- strict-mode boot for azurerm: BLOCKED (A2).
- roleDefinitions write face: REFUSED (404) — gap, law exists unmounted (A3).
- whatif/export: UNSUPPORTED — registered divergence, not a defect (A4).
- Error envelope, tags, locks: parity (A6/A8/A9).
