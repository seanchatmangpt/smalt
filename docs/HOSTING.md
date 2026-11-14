# Hosting smalt behind fnox.io

Standing: PARTIAL

Status: fnox.io hosting is authored, not deployed; registration is pending (no ACTIVE receipt).
This runbook only maps repo files to hosting roles. Nothing here was deployed.

## File-to-use map

| File | Role for a hosted fnox demo |
|---|---|
| `k8s/smalt-backend.yaml` | Primary: Secret, ConfigMap, 3 Services, StatefulSet, posh config |
| `k8s/smalt-backend-default-deny-ingress.gen.yaml` | Generated NetworkPolicies (default-deny + console allow) |
| `docker/compose.smalt.yml` | Loopback-only single-host alternative (build via `docker/Dockerfile`) |
| `lib/smalt/gcp/router.ex` | Host-header GCP dialect router (no ports of its own) |

## Ports and env

| Port | Name | Exposed in |
|---|---|---|
| 9443 | arm-mgmt (health probes) | k8s Services, compose |
| 9444 | arm-tls | k8s Services, compose |
| 8443 | data-egress | k8s Services, compose |
| 5672 | amqp-sb | k8s Services, compose |
| 5673 | eh | headless Service, compose |
| 4369 / 9000 | epmd / erl-dist | headless Service only (BEAM cluster) |
| 9545 | compose only | compose |

Env (ConfigMap `smalt-backend-env`): `SMALT_ARM_PORT`, `SMALT_ARM_TLS_PORT`, `SMALT_EGRESS_PORT`,
`SMALT_AMQP_PORT`, `SMALT_EVENT_HUBS_PORT`, `SMALT_BIND_IP`, `SMALT_PLANES`, `SMALT_PROFILE`,
`SMALT_TLS_CERTFILE`, `SMALT_TLS_KEYFILE`. Compose adds `SMALT_SB_SHARED_KEY` (dev key; override
in production).

## GCP emulator routing

`Smalt.GCP.Router` dispatches by Host header, so the same ARM listener serves GCP dialects when
clients send these hosts: `oauth2.googleapis.com`, `iam.googleapis.com`,
`cloudresourcemanager.googleapis.com`, `metadata.google.internal` and `169.254.169.254`.
Expose no extra ports: route those names (DNS or Host override) to the arm-mgmt/arm-tls
listeners. Which listener carries them is not asserted here.

## Dry-run receipt

`kubectl apply --dry-run=client -f /Users/sac/smalt/k8s/smalt-backend.yaml` (exit 0, observed):

```
secret/smalt-release-cookie created (dry run)
configmap/smalt-backend-env created (dry run)
service/smalt-backend-headless created (dry run)
service/smalt-backend created (dry run)
service/smalt-backend-nodeport created (dry run)
statefulset.apps/smalt-backend created (dry run)
configmap/posh-config-backend created (dry run)
```
