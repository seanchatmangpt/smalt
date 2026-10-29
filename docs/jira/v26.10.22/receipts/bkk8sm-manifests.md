# BK-K8SM — kind cluster config + smalt swarm/console k8s manifests

Standing: ALIVE (validated on a live 3-node kind cluster)
Context: solo
Date: 2026-10-22

## Deliverables

- `k8s/kind-config.yaml` — kind Cluster `kind-smalt`: 1 control-plane + 2
  workers. Host port mappings (extraPortMappings on the control-plane node →
  fixed NodePorts in the manifests): 9443→30943 (backend ARM HTTP),
  9444→30944 (backend ARM TLS twin), 5672→30572 (backend AMQP), 9080→30080
  (console). NOTE: console host port is 9080, not 8080 — host 8080 and 8081
  were already allocated on this machine (witnessed `Bind for 127.0.0.1:8080
  failed: port is already allocated` on first create attempt).
- `k8s/smalt-backend.yaml` — StatefulSet (replicas 2, OrderedReady,
  preferred podAntiAffinity across the 2 workers) + headless Service
  `smalt-backend-headless` (per-pod DNS:
  `smalt-backend-{0,1}.smalt-backend-headless.default.svc.cluster.local`)
  + client ClusterIP Service `smalt-backend` + NodePort Service
  `smalt-backend-nodeport` (30943/30944/30843/30572) + ConfigMap
  `smalt-backend-env` (SMALT_* env contract from lib/smalt/config.ex) +
  Secret `smalt-release-cookie` (placeholder, overwritten host-side).
  RELEASE_NODE rides headless DNS; ERL_AFLAGS pins dist range 9000-9009;
  epmd 4369 + dist 9000 exposed.
- `k8s/smalt-console.yaml` — Deployment (image `smalt-console:local`,
  imagePullPolicy Never) + NodePort Service 30080.
  `NEXT_PUBLIC_SMALT_ARM/EGRESS` point at
  `smalt-backend.default.svc.cluster.local`.
- `k8s/README.md` — new top section "Swarm + console (BK-K8SM)": kind
  create → Secrets (cookie + shared TLS) → docker build/kind load → apply →
  swarm witness (`net_adm:ping`) → console port-forward/NodePort → real SDK
  traffic over the 9444 TLS twin with NODE_EXTRA_CA_CERTS. Burn blueprint
  section preserved unchanged below it.

## Typed decisions

- **TLS: shared Secret, not per-pod certs.** One leaf minted host-side with
  SANs for both pod FQDNs + loopback, mounted read-only at
  /etc/smalt/tls. Rejected per-pod: image has no cert-mint step, the pod
  filesystem is read-only, and all SDK legs already trust the dev CA. Close
  condition: cert-mint initContainer when per-pod identity lands.
- **Console air-gap guard seam (typed, successor lane)**:
  `workspace/lib/smalt.ts` `assertLocalUrl` refuses non-loopback hosts, so
  the in-cluster console env values will be refused by the guard until it
  learns an in-cluster allowlist. Wired as tasked; documented in both the
  manifest header and the README.

## Embedded validation output (real run)

kind + kubectl present (kind v0.30.0, kubectl v1.35.2), docker daemon up.
No pre-existing cluster (`kind get clusters` → "No kind clusters found").

First create attempt failed twice, both real gates:

```
ERROR: failed to create cluster: unknown kind  for apiVersion:
  kind.x-k8s.io/v1alpha4
```
→ my config was missing `kind: Cluster`; fixed.

```
docker: ... Bind for 127.0.0.1:8080 failed: port is already allocated
```
→ host 8080 busy; console mapping moved to host 9080.

Third attempt — real cluster from the committed config:

```
 ✓ Joining worker nodes 🚜
 • Waiting ≤ 3m0s for control-plane = Ready ⏳
 ✓ Ready after 12s 💚
Set kubectl context to "kind-kind-smalt"
```

```
$ kubectl get nodes -o wide
NAME                       STATUS   ROLES           AGE   VERSION   INTERNAL-IP
kind-smalt-control-plane   Ready    control-plane   43s   v1.34.0   172.18.0.2
kind-smalt-worker          Ready    <none>          33s   v1.34.0   172.18.0.3
kind-smalt-worker2         Ready    <none>          33s   v1.34.0   172.18.0.4
```

Manifest validation on the live cluster:

```
$ kubectl apply --dry-run=client -f k8s/smalt-backend.yaml
secret/smalt-release-cookie created (dry run)
configmap/smalt-backend-env created (dry run)
service/smalt-backend-headless created (dry run)
service/smalt-backend created (dry run)
service/smalt-backend-nodeport created (dry run)
statefulset.apps/smalt-backend created (dry run)
$ kubectl apply --dry-run=server -f k8s/smalt-backend.yaml
... (server dry run) ... all 6 objects accepted
  (one informational Warning: spec.SessionAffinity is ignored for headless services)
$ kubectl apply --dry-run=client -f k8s/smalt-console.yaml
deployment.apps/smalt-console created (dry run)
service/smalt-console created (dry run)
$ kubectl apply --dry-run=server -f k8s/smalt-console.yaml
... (server dry run) ... both objects accepted
```

(`kubectl apply --dry-run=client -f k8s/kind-config.yaml` errors with "no
matches for kind Cluster" — expected: kind configs are not k8s resources;
the real gate for that file was `kind create cluster` itself.)

## Teardown

The validation cluster was torn down after the gates (host ports 9443/9444/
5672 would otherwise collide with the local smalt substrate):

```
Deleting cluster "kind-smalt" ...
Deleted nodes: ["kind-smalt-worker" "kind-smalt-worker2" "kind-smalt-control-plane"]
```

`docker ps` post-teardown: zero kind-smalt containers. Engineer recreates
it with step 1 of k8s/README.md.

## Not done here (typed)

- Full pod boot + live `net_adm:ping` witness: requires `smalt:local`
  release image (`docker build --target release`, ~minutes) + cookie/TLS
  Secrets; the README documents the exact commands. Dry-run against a live
  3-node cluster is this lane's validation gate.
- Console Dockerfile does not exist in workspace/ (minimal recipe in
  README); air-gap guard allowlist extension is the successor one-file diff.
