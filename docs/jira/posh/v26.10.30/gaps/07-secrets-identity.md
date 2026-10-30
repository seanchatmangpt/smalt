# 07 — Secrets & Identity: Local kind vs Prod ACA

Status: **PARTIAL** — prod wiring (ACA→KV via user-assigned identity + GitHub OIDC
federation) is declared and role-assigned ALIVE in Terraform; local kind path is
PARTIAL (real k8s Secrets, runtime-random session secret); KV secret *values* are
provisioned by nobody (BLOCKED gap), and the local path diverges by construction.

Evidence (read this session): `infra/modules/tenant-apps/main.tf`,
`infra/environments/dev/{platform,access}/main.tf`,
`.github/workflows/deploy-dev.yml`, smalt `k8s/courtroom-api.yaml`,
`k8s/courtroom-smalt.yaml`, `k8s/kind-config.yaml`, `k8s/smalt-backend.yaml`,
`scripts/courtroom_kind_court.sh`.

## Flow diagrams

### Prod (ACA + Key Vault + Entra)

```
GitHub Actions (deploy-dev.yml)
  │  OIDC token (sub: repo:...:environment:dev)          ── CI-only, no local analogue
  ▼
Federated identity credential ──► id-courtroom-github-dev ──► azure/login
  │  (Contributor on RG, AcrPush on ACR)
  ▼
az containerapp update --image ...        [deploy owns image only; TF owns secrets]
  ▼
Container App api (UserAssigned identity: id-courtroom-apps-dev)
  ├── secret "session-secret"  ◄── KV ref  kv-courtroom-dev-eus/secrets/<slug>-session-secret
  ├── secret "idp-cert"        ◄── KV ref  kv-courtroom-dev-eus/secrets/<slug>-idp-cert
  │        resolved by ACA control plane using the user-assigned identity
  │        (role: Key Vault Secrets User on the vault — access/main.tf:31)
  ├── env SESSION_SECRET  = secret "session-secret"
  └── env SAML_IDP_CERT   = secret "idp-cert"        (inline env var, whole PEM)
```

### Local (kind-smalt)

```
scripts/courtroom_kind_court.sh (s09)
  ├── TLS material: .smalt/tls/{dev-cert,dev-key,ca-cert}.pem  (gen_dev_cert.sh)
  │     ├── k8s Secret courtroom-smalt-tls  → smalt pod (IdP signing + TLS)
  │     └── k8s Secret courtroom-idp-cert   → api pod SAML_IDP_CERT_PATH
  │                                          (file mount, one PEM, two pods)
  └── k8s Secret courtroom-session-secret = openssl rand -hex 32 (per run)
        → api pod env SESSION_SECRET
  No Azure at all: no KV, no OIDC, no Entra — smalt pod IS the SAML IdP
  (:19445/sso), redis wire :16380 is the session/assertion KV.
```

## Gap table

| # | Gap | Evidence | Severity | Close condition |
|---|-----|----------|----------|-----------------|
| G1 | **KV secret values provisioned by nobody.** Terraform creates the vault and the ACA `secret { key_vault_secret_id }` references, but no `azurerm_key_vault_secret` resource and no script sets `<slug>-session-secret` / `<slug>-idp-cert`. First `az containerapp update` resolves a nonexistent secret → revision fails to start (or starts with stale manually-set values). | `main.tf:28-38` (refs only); grep across repo: zero `azurerm_key_vault_secret` resources | BLOCKED (prod deploy) | Add `azurerm_key_vault_secret` resources (or a seeded-run script step) writing both secrets per tenant before first deploy; falsifier: fresh-tenant `az containerapp update` starts ready with zero manual `az keyvault set`. |
| G2 | **KV is ARM-plane-only; smalt data plane on kind has no KV face.** The vault is reachable only via Azure control plane; the courtroom-smalt pod exposes redis :16380 / saml-idp :19445 / arm-mgmt :9443 — no data-egress face. Even the canonical backend's data-egress :8443 (NodePort 30843) has **no hostPort mapping in kind-config.yaml** (mappings: 9443/9444/5672/9080 only). | kind-config.yaml:25-37; smalt-backend.yaml:69,104; courtroom-smalt.yaml:85-88 | Known divergence, accepted | If data-plane KV reads are ever required locally: add `hostPort: 8443 → nodePort 30843` mapping + data-egress face on the courtroom-smalt pod. Until then local path substitutes k8s Secrets; ACA prod is the only KV consumer and uses the ACA control plane, so the gap is structural, not blocking. |
| G3 | **SAML IdP cert provisioning has no shared origin with prod.** Local: court script mounts the smalt dev cert into both pods (one PEM, two mounts). Prod: `SAML_IDP_CERT` is an ACA secret expected to be the real Entra IdP signing cert, but nothing provisions or rotates it (same root as G1), and nothing verifies it matches the actual Entra app's token-signing cert. | courtroom-api.yaml:73-74,113-116; main.tf:34-38,78-81 | PARTIAL | Prod close: seed `<slug>-idp-cert` from the Entra app's federation metadata at provisioning time + rotation runbook step. Local is ALIVE by construction (IdP and SP pin the same PEM). |
| G4 | **GitHub OIDC federation is CI-only.** Federated credentials exist for `github-environment-dev`, `*-infra`, `*-infra-plan` subjects (access/main.tf:117-132, platform/main.tf:110-118). No local analogue exists or is needed — local deploys never authenticate to Azure. A local deploy would need `az login` + explicit identity, which no script implements. | deploy-dev.yml:39-43 (azure/login, client-id OIDC); access/main.tf | Accepted (structural) | None required unless a local deploy path is wanted; then it would need a separate non-federated credential path, which should be refused (no secrets on laptop). |
| G5 | **`SAML_IDP_CERT` travels as an inline env var in prod.** ACA secret-backed env vars are visible in `az containerapp show` output as a redacted reference, but the value transits the ACA control plane as env, not a file mount. Local path is stronger (read-only file mount at `/etc/courtroom/idp`, runAsNonRoot). | main.tf:78-81 | Low | Consider `SAML_IDP_CERT_PATH` file mount parity in the consumer app config (it already supports the file form — courtroom-api.yaml:7-10). |
| G6 | **STS mock secret leak surface: NONE found.** The kind-path session secret is `openssl rand -hex 32` generated per court run, never committed; TLS material is host-generated dev CA, `.dockerignore` excludes `*.pem`. STS references in scripts (`tf_enclave_loop.sh:472-503`) probe a *real* STS, not a hardcoded mock secret. No hardcoded secret found in scripts. | courtroom_kind_court.sh:276-286 | Clean (no gap) | Keep the invariant: never bake or commit dev material; guard with a grep court if wanted. |

## Cross-references

- `03-kind-vs-aca.md` — topology differences feeding G2/G4.
- `12-runbook.md` — should carry the G1/G3 provisioning steps once closed.
