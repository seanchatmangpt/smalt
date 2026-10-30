# Gap 06 — Terraform state handling across local/production split

Status: PARTIAL. Evidence as-of 2026-10-30, read from disk at
`/Users/sac/cai/courtroom-platform-az` (consumer roots) and
`/Users/sac/smalt/justfile.d/58-posh.just` (posh-court).

## Layout observed

- Consumer roots (`infra/environments/dev/{access,platform}/versions.tf`): `backend "azurerm"`
  blob state (`stcourtroomtfstatedev`/`tfstate/{access,platform}.tfstate`),
  `use_azuread_auth = true`. No state-encryption block anywhere.
- Consumer-root local CI (courtroom-platform-az `.github/workflows/ci.yml:107`): `terraform init
  -backend=false` + `validate` only — no state read, no plan/apply against Azure from CI.
- Local kind runs (smalt `58-posh.just` stages 6/7, `adapters/terraform-provider-smalt/examples/basic`):
  throwaway root against the smalt ARM plane on kind; local state only, no `backend` block by
  construction.

## Findings

| # | Topic | Finding | Evidence | Severity | Close condition |
|---|---|---|---|---|---|
| a | State divergence consumer roots | Consumer roots always use the azurerm backend; local runs are `init -backend=false` + `validate` (no state at all). The "local plan against smalt, apply in CI against Azure" split does not exist for consumer roots today — divergence risk is structural, not active: a local `plan`/`apply` on a consumer root would mint a *second* local state lineage (`terraform.tfstate`) that the remote state never sees, and CI's plan job uses `-lock=false` (`infra-dev.yml:54-56`) so even CI-vs-CI plans take no lock. Apply is gated to `workflow_dispatch` on main from `dev-infra` OIDC environment. | `versions.tf` both roots; `ci.yml:107`; `infra-dev.yml:54-56,93-97` | Medium | Mechanical gate against local apply on consumer roots (pre-flight `terraform state list` provenance check or guard script). Falsifier: a local apply on a consumer root is refused, or provably stateless (`terraform state list` empty, no `terraform.tfstate` written). |
| a2 | Accidental real apply from posh root | `examples/basic` targets `arm_endpoint = http://127.0.0.1:9443` with zero subscription id — structurally cannot reach real Azure. The only real-Azure apply path is the CI apply job. | `examples/basic/main.tf` | Low | None needed (structural fence adequate); re-check if `examples/` gains a real-Azure variant. |
| b | Import drift (F3 stripped imports.tf) | Both dev roots carry `imports.tf` pinned to real Azure ids; local runs strip it (F3), so local validate exercises config without import blocks. Import blocks are no-ops once imported — but a local `apply -auto-approve` on a consumer root with empty local state would treat every imported resource as CREATE, attempting real creates of `prevent_destroy`-tagged infra names (name collisions, not residue). The current fence is purely procedural — nothing runs local apply on consumer roots, but nothing forbids it either. | `platform/imports.tf` (11 import blocks incl. `module.tenant["demo"]` container apps); `access/imports.tf` (2); F3 receipts `smalt/tmp/posh/posh-court-20261030-f3*.log` | High | Mechanical fence: `just` target or CI check asserting no `terraform apply` runs against a consumer root backed by a local (non-backend) state lineage. Falsifier: an attempted local apply on a consumer root in a clean dir is refused by the fence; `-backend=false` validate remains allowed. |
| b2 | Lineage unrecorded | Real-Azure resources were CLI-created then imported; smalt-kind resources are Terraform-created from empty state — guaranteed-divergent lineages, safe only because state never merges. Nothing records which lineage a resource belongs to. | `platform/main.tf` `local.tenants = { demo }` (demo only); imports.tf | Low | Add lineage register (ledger row or tag); close when lineage recorded and a `platform` plan output is archived as witness. |
| c | Destroy-residue falsifier vs module.tenant | Stage 7 residue probes cover two surfaces: `resourcegroups` and `containerApps` list. `module.tenant` resources ARE containerApps (`ca-{slug}-{api,web}-dev`), so the containerApps probe would catch tenant app residue — but the posh example root never creates a tenant module instance (it creates only `azurerm_resource_group.rg` = `smalt-basic-rg`), so the probe is never exercised against the tenant surface. KV-backed secrets (`{slug}-session-secret`, `{slug}-idp-cert`) are not probed at all. | `58-posh.just` stage 7 (2 curl GETs + asserts); `examples/basic/main.tf` (one rg); `modules/tenant-apps/main.tf` (2 container apps + KV secret refs) | High | Add a tenant-shaped example (container apps + KV secret refs), destroy, and probe containerApps + keyvault secrets endpoints. Falsifier: a deliberately broken destroy (mutation) makes stage 7 FAIL on the tenant-surface probe — the court must flip. |
| c2 | Residue probe scope | Only 2 ARM surfaces probed. `access`-root classes (role definitions/assignments, user-assigned identities, federated identity credentials) are not residue-probed after destroy. | `58-posh.just` stage 7 | Medium | Add probes: roleAssignments, custom roleDefinitions, userAssignedIdentities, federatedIdentityCredentials. Close when a seeded-residue mutation flips the court on each new probe. |
| d | No tfstate encryption | `backend "azurerm"` blocks carry no encryption config. State contains KV secret *ids* (URIs, not values) and principal ids — metadata exposure, not secret material. Required-version pin `>= 1.9.0, < 2.0.0` predates native `terraform { encryption }` (1.10+). | `versions.tf` both roots; `tenant-apps/main.tf` `key_vault_secret_id` refs | Low | Bump pin ≥1.10, enable state encryption or blob CMK; close when one plan shows the backend re-wrap succeeds. |
| d2 | Local state files | `.gitignore` covers `*.tfstate*` (verified on disk). Plaintext local state would still land on disk if finding (a)'s gap is exercised; contained by (a)'s fence. | `.gitignore` | Low | None beyond (a); verified ignore covers `*.tfstate*` and backups. |
| d3 | `-lock=false` on CI plan | Plan job runs `init -lock=false` + `plan -lock=false` — a concurrent apply could move state between plan and its published diff. Low risk (apply is manual dispatch) but a divergence source. Commit 31c58e9 ("Skip state locking during Terraform init for plans") introduced it. | `infra-dev.yml:54-56`; commit 31c58e9 | Low | Drop `-lock=false` from plan once the original motivation is re-derived, or register as accepted divergence in the parity register. Apply job inits locked — fine. |
| e | Workspace/tenant isolation | `local.tenants = { demo }` — single demo tenant. Container app names embed slug (`ca-{slug}-{api,web}-dev`); `for_each` over tenants makes a second tenant config-only. No `terraform workspace` usage anywhere; backend keys are per-root (`access.tfstate`/`platform.tfstate`), lineage-isolated by key. | `platform/main.tf` locals; `tenant-apps` name locals; no workspace refs | Low | When a second tenant lands: residue probes become per-slug, assert per-tenant zero residue. Close at ≥2 tenants + per-tenant probes flipping under mutation. |
| e2 | Access root ungated | The `access` root (role assignments, terraform plan/apply identities, custom plan role definition) has no CI plan/apply workflow at all — only fmt/validate in ci.yml. Access-root applies are local-only, with the same unguarded-local-apply exposure as (b), on the most privilege-sensitive surface. Separation of the terraform identities living outside the managed RG is good. | `access/main.tf`; no workflow with `working-directory: infra/environments/dev/access` | Medium | Add an infra-dev-style OIDC-gated plan+apply workflow for the access root. Close when access-root applies carry an environment gate like platform's `dev-infra`. |
| e2-bis | Import rot until dispatch | CI validate (`-backend=false`) never executes import blocks — they get zero execution coverage on PRs and can rot silently until a manual dispatch apply fails. | `ci.yml:107-108`; `infra-dev.yml` (apply manual-dispatch only) | Medium | Run a real locked `terraform plan` (remote state, OIDC read-only) on PRs touching `infra/**`; close when a PR that breaks an import block fails CI. |

## Non-vacuity wedge

Stage 7's residue asserts have never been flipped by a seeded-residue mutation. Per
shim-court protocol a court that cannot flip is FAIL. Both High rows ((b), (c)) close with
mechanical fences/courts whose falsifiers flip; (c)'s falsifier is the same non-vacuity proof
stage 8 already applies to the receipt legs, extended to residue.

## Status

PARTIAL — state handling is split-brain by design and currently safe by structural fences
(`examples/basic` cannot reach real Azure; local CI is validate-only), not by mechanical gates.
High: (b) procedural-only fence on local apply with stripped imports, (c) tenant surface never
exercised by the residue court.
