# smalt k8s

## Swarm + console (BK-K8SM): kind → kubectl → witness

Engineer path for `k8s/kind-config.yaml`, `k8s/smalt-backend.yaml`,
`k8s/smalt-console.yaml`. The burn blueprint below is unchanged.

### 1. Cluster

```bash
kind create cluster --config k8s/kind-config.yaml   # 1 CP + 2 workers
kubectl get nodes -o wide                           # expect 3 Ready
```

Host mappings (kind-config): 9443→30943 (ARM), 9444→30944 (TLS twin),
5672→30572 (AMQP), 9080→30080 (console).

### 2. Secrets (before apply)

```bash
kubectl create secret generic smalt-release-cookie \
  --from-literal=cookie="$(openssl rand -hex 16)" --save-config
# Shared TLS Secret (typed decision: shared cert, not per-pod — see
# smalt-backend.yaml header). SANs cover both pod FQDNs + loopback.
.smalt/tls exists? skip; else: scripts/gen_dev_cert.sh
# Extend SANs to the pod FQDNs before minting, or mint a k8s-scoped pair:
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -CA .smalt/tls/ca-cert.pem \
  -CAkey .smalt/tls/ca-key.pem \
  -subj "/CN=smalt-backend-0.smalt-backend-headless.default.svc.cluster.local" \
  -addext "subjectAltName=DNS:localhost,DNS:smalt-backend-0.smalt-backend-headless.default.svc.cluster.local,DNS:smalt-backend-1.smalt-backend-headless.default.svc.cluster.local,DNS:smalt-backend.default.svc.cluster.local,IP:127.0.0.1" \
  -keyout /tmp/smalt-k8s-key.pem -out /tmp/smalt-k8s-cert.pem
kubectl create secret tls smalt-tls --cert=/tmp/smalt-k8s-cert.pem --key=/tmp/smalt-k8s-key.pem --save-config
```

### 3. Images into kind

```bash
docker build --target release -t smalt:local .          # docker/Dockerfile
kind load docker-image smalt:local --name smalt
# Console (no Dockerfile in workspace/ yet — typed seam; minimal recipe):
#   FROM node:20-alpine → corepack enable → workspace/ `npm ci && npm run build`
#   → CMD ["npm","start"] (next start, port 3000)
docker build -t smalt-console:local workspace/
kind load docker-image smalt-console:local --name smalt
```

### 4. Apply

```bash
kubectl apply -f k8s/smalt-backend.yaml
kubectl apply -f k8s/smalt-console.yaml
kubectl get pods -l app=smalt-backend -o wide   # 2/2 Running, spread over workers
```

### 5. Witness

**Swarm witness** (BEAM distribution over headless DNS):

```bash
kubectl exec smalt-backend-0 -- \
  /app/_release/bin/smalt eval \
  'net_adm:ping(:'"'"'smalt-backend-1.smalt-backend-headless.default.svc.cluster.local'"'"')'
# expect: pong
```

**Console from the laptop**:

```bash
kubectl port-forward svc/smalt-console 3000:3000   # or http://localhost:9080 via NodePort
open http://localhost:9080
```

**Real SDK traffic laptop→pod** (9444 TLS twin, dev CA trust):

```bash
NODE_EXTRA_CA_CERTS="$PWD/.smalt/tls/ca-cert.pem" \
  node -e 'const https=require("https");https.get("https://localhost:9444/metadata/endpoints",r=>{console.log(r.statusCode);process.exit(0)}).on("error",e=>{console.error(e);process.exit(1)})'
# expect: 200 (auth-exempt surface), or 401 on non-exempt paths with a
# tokenless→STS-mint→bearer-retry handshake per the KD-15 premise.
```

### Known seams (typed, successor lanes)

- **Console air-gap guard**: `workspace/lib/smalt.ts` `assertLocalUrl`
  refuses non-loopback hosts, so the in-cluster console's
  `NEXT_PUBLIC_SMALT_ARM=http://smalt-backend.default.svc.cluster.local:9443`
  is refused until the guard learns an in-cluster allowlist. Console pages
  render; API calls through smaltFetch will 500 with the air-gap error.
- **Console image**: no `workspace/Dockerfile` committed; the README recipe
  above is the interim contract.
- **TLS Secret** `smalt-tls` must exist before the StatefulSet rolls
  (volume mount), and the cookie Secret before the pod starts (env).

---

# smalt k8s — Burn Cluster Blueprint

Phase 4 (Compact Cluster Orchestration) deployment blueprint for the smalt
burn image on a local kind cluster (`k8s/kind/cluster.yaml`).

## Manifests

| File | Objects | Role |
|---|---|---|
| `burn/smalt-deployment.yaml` | Deployment `smalt-burn` | 3-replica, single-container pods; security context; probes; anti-affinity |
| `burn/smalt-services.yaml` | 5 Services | `smalt-headless` (clusterIP: None, BEAM peer discovery) + 4 client-facing ClusterIP Services |
| `burn/smalt-azure-issues-job.yaml` | Job | carried over, unchanged |
| `burn/smalt-burn-conformance-job.yaml` | Job | carried over, unchanged |
| `burn/smalt-sovereign-midnight-job.yaml` | Job | carried over, unchanged |
| `kind/cluster.yaml` | kind Cluster | carried over, unchanged (coordinator-owned port mappings + mounts) |

## Deploy

```bash
# 1. Subject identity is REQUIRED — substitute from the image contract
#    (org.smalt.subject label / SMALT_BURN_SUBJECT_SHA env; enforced by
#    scripts/build_burn_image.sh). Never deploy the raw placeholder.
SUBJECT_SHA=$(git rev-parse HEAD)
sed "s/__SUBJECT_SHA__/${SUBJECT_SHA}/" k8s/burn/smalt-deployment.yaml \
  | kubectl apply -f -
kubectl apply -f k8s/burn/smalt-services.yaml
```

## Design contract

### Zero sidecars

Single container per pod. Storage (DETS mirrors), cache, and pubsub resolve
in-process (Smalt.Store / Smalt.StoreTables / messaging supervisors) —
no redis/rabbitmq/envoy/nginx sidecar containers anywhere in the blueprint.
Writable state is tmpfs under `/tmp` (`SMALT_DATA_DIR=/tmp/smalt-data`).

### Native BEAM discovery

No libcluster dependency exists in `mix.exs`, so peer discovery rides the
release's own name distribution:

- `RELEASE_DISTRIBUTION=name`
- `RELEASE_NODE=smalt@$(POD_NAME).smalt-headless.default.svc.cluster.local`
  (headless Service, `clusterIP: None`)
- `ERL_AFLAGS="-kernel inet_dist_listen_min 9000 -kernel inet_dist_listen_max 9009"`
  pins the dist port range; container publishes 4369 (epmd) + 9000.
- Requires the release-stage image (`docker/Dockerfile` `FROM deps AS
  release`, `CMD ["/app/_release/bin/smalt", "start"]`) — the RELEASE_*
  env contract is honored by the release boot scripts, not by `mix run`.
- The prior 2-replica deployment booted `mix run --no-halt` with
  `distribution: none` — that boot cannot join a distributed cluster and
  was replaced.

`RELEASE_COOKIE` is inline for the kind burn cluster. A real cluster must
source it from a Secret:

```bash
kubectl create secret generic smalt-release-cookie \
  --from-literal=cookie=$(openssl rand -hex 16)
```

and swap the inline env for a `secretKeyRef`. (Deliberately not done here:
kind-local burn keeps the manifest dependency-free.)

### Security context

`runAsNonRoot` (uid/gid 65534), `readOnlyRootFilesystem: true`, all
capabilities dropped, `allowPrivilegeEscalation: false`, `/tmp` on a
memory-backed `emptyDir` (the only writable path; `SMALT_DATA_DIR` lives
under it).

### Probes

`/metadata/endpoints` on 9443 is the only auth-exempt HTTP surface
(`lib/smalt/auth/bearer.ex` `@exempt_exact`; arm router
`GET /metadata/endpoints`). Readiness proves the TLS-terminated ARM
listener + router are up; liveness uses the same endpoint with looser
thresholds.

**Documented gap**: no native `/health` endpoint exists yet that reflects
real scheduler-reduction capacity + state-engine integrity — the current
probe proves process liveness, not reduction headroom or DETS/store
integrity. That is the /health endpoint lane's seam; when it lands,
repoint `readinessProbe.httpGet.path` at `/health` and flip this gap.

### Multi-replica

3 replicas, `requiredDuringSchedulingIgnoredDuringExecution` pod
anti-affinity on `kubernetes.io/hostname`, resource bounds
(requests 500m/512Mi, limits 2/2Gi), RollingUpdate `maxUnavailable: 0`.

**Cross-replica consistency seam**: replicas share NOTHING (in-process
DETS per pod, no shared volume), and the client-facing Services are
spread-only, not session-sticky — the same blob/container key can land on
different replicas across requests. This is correct for burn/adversarial
traffic (state-per-pod is the point) and WRONG for a coherent multi-client
surface; a coherent surface needs session-sticky routing or a shared-store
plane. Documented here so the limitation is chosen, not discovered.

## Validate

```bash
kubectl --dry-run=client -o yaml apply -f k8s/burn/smalt-deployment.yaml
kubectl --dry-run=client -o yaml apply -f k8s/burn/smalt-services.yaml
yamllint k8s/burn/*.yaml
```
