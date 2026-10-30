# Gap 03 — kind Cluster vs ACA Production Parity

Status: PARTIAL — kind estate is ALIVE for local orchestration smoke; parity with the
Azure production topology is PARTIAL by design and incomplete on every dimension except
static config surface.

- kind side: `/Users/sac/smalt/k8s/kind-config.yaml`, `/Users/sac/smalt/k8s/smalt-backend.yaml`
  (StatefulSet + headless svc + NodePort + shared TLS Secret; posh UDS sidecar).
- Production side: `/Users/sac/cai/courtroom-platform-az/infra/modules/tenant-apps/main.tf`,
  `/Users/sac/cai/courtroom-platform-az/infra/environments/dev/platform/main.tf`,
  `.github/workflows/deploy-dev.yml`.

## Parity table

| Dimension | kind (smalt) | Azure ACA production | Parity | Severity | Close condition |
|---|---|---|---|---|---|
| Ingress / TLS termination | Plain-HTTP NodePort via `extraPortMappings` (host 9443→30943); separate TLS twin on 9444 with a shared dev-CA leaf cert (Secret `smalt-tls`, `scripts/gen_dev_cert.sh`). No L7 proxy, no managed TLS. | ACA managed ingress: web external TLS-terminated at the ACA edge (`allow_insecure_connections=false`), api internal-only (`external_enabled=false`), proxy-terminated TLS in front of the container. | NONE | HIGH | Run an ingress controller (e.g. NGINX/Envoy) on kind with a real CA-signed cert and assert proxy-trust behavior (`X-Forwarded-*`) matches ACA; or accept typed divergence and test TLS only at the app twin port. |
| Identity | None. Pods are `runAsUser 65534`, no workload identity; BEAM cluster cookie is the only auth. | Every app: user-assigned managed identity (`id-courtroom-apps-dev`) + ACR `identity` pull + KV `identity`-bound secret refs; CI deploys via `id-courtroom-github-dev` federated OIDC. | NONE | HIGH | Deploy the azure-workload-identity webhook into kind, mint a dev federated credential, and run one real KV-pull + ACR-pull leg behind it. |
| Secrets | k8s Secrets in plain YAML (`smalt-release-cookie` `replace-me-before-apply`, `smalt-tls`); host-side overwrite by hand. | ACA `secret` blocks resolve from Key Vault (`key_vault_secret_id`) with identity-bound access; secrets never enter the manifest. | WEAK | MEDIUM | Mirror the KV-reference pattern: External Secrets Operator or CSI secrets-store driver on kind pulling from the real dev KV, so manifests carry references, not values. |
| Scaling | Static `replicas: 2`, podAntiAffinity across 2 kind workers; no autoscaling. | `min_replicas`/`max_replicas` per app (Consumption profile, KEDA-backed scale rules under the hood). | PARTIAL (bounds declared on ACA side only) | LOW | kind can express replica count but not event-driven scale rules; accept divergence or add KEDA to kind with a real scaler (e.g. AMQP queue depth on 5672). |
| Observability | Nothing — no log sink; container logs live only in containerd/kubectl. | ACA environment wired to Log Analytics (`log-analytics` destination, 30-day retention); deploy workflow asserts health over the public FQDN. | NONE | MEDIUM | Ship kind container logs to a real sink (Loki/Promtail or an OTLP collector) and keep at least one assertion that reads it back. |
| Image delivery | `kind load docker-image smalt:local`, `imagePullPolicy: Never`. | CI builds linux/amd64, pushes to ACR (`crcourtroomplatformdev`), `az containerapp update --image` per tenant with digest pinning; TF `lifecycle.ignore_changes` gives the workflow sole ownership of the image. | NONE (different mechanism entirely) | LOW (mechanism gap, not a behavior gap) | Not closable faithfully: build-push-deploy is cloud-specific. Close by proving the *digest-pinning* behavior: kind pulls a digest-pinned image from ACR with `imagePullPolicy: IfNotPresent` through the azure-workload-identity+ACR OIDC path once identity is closed. |
| Revisions / traffic split | None. Restarts replace pods; no revision history, no weighted routing. | `revision_mode=Single`, `max_inactive_revisions=10`, `traffic_weight 100% latest`, deploy workflow waits on `latestReadyRevisionName` before proceeding. | NONE | MEDIUM | No k8s-native equivalent without Argo Rollouts/Flagger; either install one on kind and exercise a canary, or register a typed divergence (ACA-specific, untestable on kind). |
| Probes / readiness gating | k8s native probes on real kernel self-report (`/.well-known/health/ready`), exec-probe sidecar. | ACA `liveness_probe`/`readiness_probe` on `/health` (api 8080, web 3000). | HIGH | — | Parity is real here: both platforms gate traffic on HTTP readiness of the container port. Close already satisfied for the *mechanism*; paths differ per app. |
| Config surface | ConfigMap `smalt-backend-env` (SMALT_* env contract). | ACA `env` blocks (NODE_ENV, APP_ORIGIN, BACKEND_URL, SAML/SESSION secrets refs). | PARTIAL | — | Same shape (env-driven config), different keys — fine, different apps. |

## Standing

- kind estate: ALIVE (in active use for smalt swarm witness + TLS-twin + posh sidecar;
  witnessed 2026-10-30 header comments in smalt-backend.yaml).
- Production ACA estate: ALIVE (terraform provisioned, deploy workflow gated on
  revision-ready + health).
- kind-as-ACA-stand-in: PARTIAL — 5 of 8 dimensions have ZERO parity; kind exercises the
  app's internal topology (BEAM distribution, TLS twin, sidecar, probes) but none of
  ACA's platform behaviors (managed ingress, identity, KV secrets, revisions, LA sink).

## Falsifier

A claim that "kind parity exists" is refuted if any of: a deploy flow exercises
`az containerapp update` behavior on kind; a KV-sourced secret changes without a
manifest edit on kind; a revision rollout with traffic weight occurs on kind. None of
these are currently executable on kind — that absence is the gap.
