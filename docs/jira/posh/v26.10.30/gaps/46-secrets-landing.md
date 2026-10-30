# 46 Secrets Landing (tenant Key Vault secrets, lands the gap 34 artifact)

Status: ALIVE (files landed + validate green + falsifier block present; nothing applied).

Subject: `/Users/sac/cai/courtroom-platform-az` @ main 31c58e9 (uncommitted working-tree change).

## Landed

`infra/environments/dev/platform/secrets.tf` (new):

- `variable "idp_certs"` — map(string), `sensitive = true`, no default.
- `random_password.session` — for_each `local.tenants`, `length = 32`, `special = false`
  (KV compat).
- `azurerm_key_vault_secret.session` — `<slug>-secret`... exact names
  `<slug>-session-secret` / `<slug>-idp-cert`, matching the consumer
  `infra/modules/tenant-apps` outputs (`key_vault_secret_names` at outputs.tf:11-13)
  and the module's secret URIs (main.tf:28-37).
- `azurerm_key_vault_secret.idp_cert` — for_each over `{ for slug, cfg in local.tenants :
  slug => var.idp_certs[slug] }` — NOT over the sensitive map directly: azurerm/TF
  rejects sensitive values as for_each keys. A slug missing from `idp_certs` plan-errors
  on the invalid index rather than skipping silently.
- `azurerm_role_assignment.terraform_apply_secrets_officer` — Key Vault Secrets Officer
  for the apply identity. **Disclosure**: grant lives in platform/secrets.tf, not
  access/main.tf's `service_role_assignments` / `secrets_officer` pattern
  (access/main.tf:164-171), because the apply identity is created in the access stack
  (lives in `rg-courtroom-tfstate-dev-eus`) while the vault is created in this stack —
  the cross-stack data lookup `data.azurerm_user_assigned_identity.terraform_apply`
  keeps the grant inside the stack that owns the vault. Access root untouched.
- Fail-closed falsifier: `data "azurerm_key_vault_secret" "required"` (for_each over
  `<slug>-session-secret` / `< secrets` names) + `check "tenant_secrets_present"`
  assert referencing the data read. Contract caveat honored: the data read resolves
  `azurerm_key_vault.main.id` (a resource attribute), so the read fires when the vault
  id is known (post-plan/apply on an initialized vault); it is referenced by the check
  block so it is never silently skipped, and an absent secret errors the read.
- Import blocks deliberately NOT added (nothing applied; imports for
  session/idp-cert secrets would be a follow-up when values are real).

## Upstream receipt missing

`gaps/34-secret-provisioning.md` did not exist on disk (gaps/ held only
24-cross-repo-skew.md at lane start). The lane contract fully specified the deliverable,
so I landed from the contract; G34's own gap analysis remains UNVERIFIED/absent.

## Gates (real output this session)

- `terraform fmt -check -recursive` → exit 0.
- `terraform validate -no-color` (TF 1.14.6, azurerm ~> 5.12 + random provider,
  init -backend=false) → `Success! The configuration is valid.`, exit 0 — with
  secrets.tf and the check block present, dummy vars via TF_VAR_* (validate rejects
  `-var` flags; F3 pattern adapted).
- Nothing applied; no state touched. Check block note: `for_each` is not supported
  inside nested `data` blocks of a check block (TF 1.14 rejects it), so the assert
  reads `data.azurerm_key_vault_secret.required` directly.
