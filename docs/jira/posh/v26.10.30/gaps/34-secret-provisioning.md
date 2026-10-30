# 34 Secret Provisioning: tenant KV secrets referenced but never provisioned

Status: PARTIAL (read-only census 2026-10-30; every file:line re-read from disk
this session; `terraform validate` executed read-only on the consumer root —
the falsifier is specified, not yet landed).

## The gap (GAP7 G1)

`infra/modules/tenant-apps/main.tf:28-38` declares two Key Vault secret
references per tenant:

- `${var.key_vault_uri}secrets/${var.slug}-session-secret` (main.tf:30)
- `${var.key_vault_uri}secrets/${var.slug}-idp-cert` (main.tf:36)

`grep -rn azurerm_key_vault_secret infra/` returns zero matches: nothing in
this repo provisions those secret objects. The `apps` identity already holds
`Key Vault Secrets User` on the vault (access/main.tf:31-36) — RBAC to READ is
ready; the secret objects themselves do not exist. First real deploy:
`az containerapp update` succeeds, the revision starts, Key Vault reference
resolution fails, `SESSION_SECRET`/`SAML_IDP_CERT` resolve empty, and the
health-check loop in `deploy-dev.yml:81-95` fails the workflow after its
bounded retries.

The repo currently only ADMITS the gap: `platform/outputs.tf` exports
`required_key_vault_secrets` and the module outputs `key_vault_secret_names`
(tenant-apps/outputs.tf) — a manifest of missing secrets, not provisioning.

## Recommendation: Terraform resource block, not az script

`azurerm_key_vault_secret` in the platform root wins over a
`scripts/provision_secrets.sh` az-CLI path because:

1. the apply identity already runs `terraform apply` via OIDC
   (infra-dev.yml; federated credential at platform/main.tf:110-116) — no new
   credential surface;
2. the falsifier (below) becomes a plan-time assertion in the same root — a
   script provisioner leaves the consumer config still unverified at plan;
3. drift detection and rotation come free from state.

Named artifact: `infra/environments/dev/platform/secrets.tf` (new file, one
per-root block set; the tenant loop reuses `local.tenants` so TENANTS in the
deploy workflow and the TF side cannot skew).

## Prod spec (secrets.tf)

```hcl
resource "random_password" "session" {
  for_each = local.tenants
  length   = 64
  special  = false # base62-safe; SESSION_SECRET is env-injected
}

resource "azurerm_key_vault_secret" "session" {
  for_each     = local.tenants
  name         = "${each.key}-session-secret"
  key_vault_id = azurerm_key_vault.main.id
  value        = random_password.session[each.key].result
  # Do NOT set expiration — rotation is re-apply, not expiry.
}

# idp-cert is minted in the Entra ceremony (app registration signing cert),
# never generated here and never committed. Per-tenant PEM passed as a
# sensitive variable / env var at apply time.
variable "idp_certs" {
  type      = map(string) # slug -> PEM body
  sensitive = true
}

resource "azurerm_key_vault_secret" "idp_cert" {
  for_each     = var.idp_certs
  name         = "${each.key}-idp-cert"
  key_vault_id = azurerm_key_vault.main.id
  value        = each.value
}
```

Tenant loop: `for_each = local.tenants` (platform/main.tf:17-22 — currently
`demo`), matching `vars.TENANTS` in deploy-dev.yml. Adding a tenant to
`local.tenants` without adding it to `vars.TENANTS` (or vice versa) is caught
by the falsifier below only if the cert var is present; session coverage is
structural.

Requires one new role assignment for the apply identity:
`Key Vault Secrets Officer` on `azurerm_key_vault.main` (access/main.tf role
map — same pattern as `apps_key_vault_secrets_user`).

### Rotation story

- session-secret: re-apply rotates the value (`random_password` regenerates
  only on forced replacement — pin with `keepers` keyed to a version bump, or
  taint/replace deliberately; untargeted re-applies are no-ops). Container
  Apps resolves `key_vault_secret_id` references at revision start, so a
  rotated secret needs a revision restart to take effect — document as
  restart-after-rotate.
- idp-cert: rotation is an Entra-side ceremony (new cert in the app
  registration -> new PEM -> update `idp_certs` var -> apply). Never
  generated or committed in this repo; `.gitignore` should carry the PEM
  pattern.

## Kind side: already provisioned — reference, do not duplicate

Verified on disk this session:

- `~/smalt/scripts/courtroom_kind_court.sh:276-288` (stage S09) creates
  `courtroom-idp-cert` from the smalt dev cert (`--from-file=dev-cert.pem`)
  and `courtroom-session-secret` from `openssl rand -hex 32`, both
  dry-run-client applied; teardown deletes exactly these three secrets
  (courtroom_kind_court.sh:66, fail_all).
- `~/smalt/k8s/courtroom-api.yaml:73-81,104-112` mounts `courtroom-idp-cert`
  at `/etc/courtroom/idp` (`SAML_IDP_CERT_PATH`) and injects the session
  secret as env from `courtroom-session-secret` — this is the lane-7 finding,
  confirmed intact.
- `~/smalt/k8s/courtroom-smalt.yaml:74` boots the SAML IdP face on :19445.

The kind lane needs no new artifact. Any new local manifest here would be a
second writer for one concept (the O(N^2) drift law, cf.
gaps/24-cross-repo-skew.md S7) — the gap file records the pointers above and
changes nothing.

## Falsifier (specified, not landed)

Claim under test: every `key_vault_secret_id` referenced by container apps
resolves to a declared/real secret at plan time.

Two halves:

1. **Today's behavior (measured this session)**: `terraform validate` in
   `infra/environments/dev/platform` exits 0 (`Success! The configuration is
   valid.`) against the unresolved references. Confirmed: `validate` does not
   catch the gap, and azurerm does not read `key_vault_secret_id` values at
   plan either — the failure surfaces only at revision start in Azure. The
   consumer repo has no gate that fires today.
2. **Landed falsifier**: in `platform/main.tf` add a plan-time data lookup
   that fails closed when a secret is absent:

```hcl
data "azurerm_key_vault_secret" "required" {
  for_each     = toset(flatten([for t in module.tenant : t.key_vault_secret_names]))
  name         = each.value
  key_vault_id = azurerm_key_vault.main.id
}
```

A missing secret makes `terraform plan` fail with an unresolvable data source
(fail-closed). This requires the reader to have Secrets User on the vault —
true for the apps identity, must also hold for the apply identity. Note the
circularity once secrets.tf lands: the data source then trivially resolves to
the azurerm_key_vault_secret resources; its residual value is catching a
tenant added to `vars.TENANTS`/deploy without a TF-side secret (the real skew
this gap exists for). Cheaper alternative if the read-permission coupling is
unwanted: a `check` block over the same data with an `assert` — warning-only,
weaker. Fail-closed data source is the recommendation.

Mutation test for non-vacuity: delete the `<slug>-idp-cert` secret object in
the vault (or plan with `idp_certs = {}`) -> plan must fail; restore -> plan
must pass. A falsifier that cannot flip is FAIL.

## Status line

PARTIAL — gap confirmed and measured (`validate` exit 0 on unresolved
references, run this session); prod artifact (secrets.tf + Secrets Officer
grant + idp_certs var) and falsifier (data-source fail-closed lookup) fully
specified above; nothing landed in this repo this session. Kind side ALREADY
ALIVE via `~/smalt/scripts/courtroom_kind_court.sh` S09 + `courtroom-api.yaml`
mounts — referenced, not duplicated.
