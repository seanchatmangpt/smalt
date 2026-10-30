# 11 — kind cluster operational readiness (lane 11, read-only probes)

Date: 2026-10-30 ~12:22 PDT. Context `kind-smalt`, colima (VZF, aarch64, 4 CPU / 8GiB / 60GiB disk, docker runtime).

## Status: PARTIAL

Nodes Ready and DiskPressure clear (F17 recovered), NodePort mappings present for 9443/9444/5672/9080 — but the
backend StatefulSet is in CrashLoopBackOff, the egress 8443 NodePort is unmapped at the docker boundary, no console
workload is deployed, and restart resilience was exercised for real this session (unplanned colima restart mid-wave)
and held.

## Current state snapshot (verbatim command tails)

```
$ kubectl --context kind-smalt get nodes
NAME                  STATUS   ROLES           AGE   VERSION   CONTAINER-RUNTIME
smalt-control-plane   Ready    control-plane   32m   v1.34.0   containerd://2.1.3
smalt-worker          Ready    <none>          32m   v1.34.0   containerd://2.1.3
-node                 Ready    <none>          32m   v1.34.0   containerd://2.1.3

$ kubectl get pods -A   (workload rows)
posh-sidecar-witness   0/2  Completed        0    6m39s  smalt-worker
smalt-backend-0        0/2  CrashLoopBackOff 35 (2s ago)  17m  smalt-worker2
kube-proxy-d2gwm (smalt-worker)  0/1 CrashLoopBackOff 11  13m   <-- kube-system, secondary casualty

$ for n in smalt-control-plane smalt-worker smalt-worker2; do docker exec $n df -h /var/lib/containerd; done
/dev/vdb1  59G  39G  18G  69% /var    (identical on all three nodes; shared colima disk)

$ docker system df
Images 6 (2 active) 19.12GB, 17.62GB reclaimable (92%)
Build Cache 91 entries 10.24GB, 8.924GB reclaimable

$ docker images | grep -i smalt
smalt-console:local 437MB / smalt:hermetic 516MB / smalt:local 516MB (same ID c05b56bc8435)

$ docker ps (smalt-control-plane port map)
127.0.0.1:59455->6443/tcp, 0.0.0.0:9080->30080/tcp, 0.0.0.0:5672->30572/tcp,
0.0.0.0:9443->30943/tcp, 0.0.0.0:9444->30944/tcp
```

## Gap table

| # | Gap | Evidence | Severity |
|---|---|---|---|
| G11-1 | **smalt-backend-0 CrashLoopBackOff, 35 restarts/17m.** `posh-membrane` sidecar: `/bin/sh: exec: /posh/bin/posh: not found` — the smalt app container's log ends in `Smalt.Store.Heir: holding table :smalt_* (owner partition died)` spam. Workload is NOT operational. | logs above | HIGH |
| G11-2 | **Egress NodePort 30843 (8443) not mapped through docker.** `smalt-backend-nodeport` exposes 8443:30843/TCP in-cluster, but smalt-control-plane has no `->30843` docker port map; all 4 other ports (9443/9444/5672/9080) are mapped. Egress traffic from host cannot reach the backend. | docker ps vs kubectl get svc | HIGH |
| G11-3 | **No console workload deployed.** `smalt-console:local` image exists (437MB, built 24 min ago) but no Deployment/StatefulSet/Pod references it; `kubectl get deploy,sts -A` shows only smalt-backend + system addons. | kubectl get deploy,sts -A | MED |
| G11-4 | **Sidecar witness pod Completed, not Running.** `posh-sidecar-witness 0/2 Completed` — witness ran to completion (probe semantics may be intended, but 0/2 READY with no restart policy evidence in this probe means no standing witness is holding tables). | kubectl get pods | MED |
| G11-5 | **Docker image/build-cache bloat.** 19.12GB images (92% reclaimable) + 10.24GB build cache (8.9GB reclaimable) inside the 60GB colima disk now at 69% — this is exactly the F17 trajectory (94% was witnessed preflight). No prune has run. | docker system df; df 69% | MED |
| G11-6 | **Colima VM restarted ~12:21 this session** (lima hostagent/limactl processes started 12:20:58, all kind containers "Up About a minute", etcd/apiserver age reset to 2m29s while pod ages stayed 32m). The cluster SURVIVED — static pods recovered, nodes re-Ready — so restart resilience is evidenced, but it was unplanned; no deliberate restart test receipt exists. | process start times, docker ps -a | LOW (evidence, not defect) |
| G11-7 | kube-proxy-d2gwm on smalt-worker CrashLoopBackOff (11 restarts) — secondary casualty of G11-1-era churn; worker1's NodePort dataplane may be degraded. | kubectl get pods -A | MED |

## Close conditions

- **G11-1 (HIGH)**: fix the `smalt:local`/hermetic image so `/posh/bin/posh` exists (or correct the sidecar command path); `kubectl rollout status sts/smalt-backend` returns 1/2 or 2/2 available, pod READY 2/2, no CrashLoopBackOff; Heir "owner partition died" warnings stop recurring on fresh logs.
- **G11-2 (HIGH)**: recreate kind cluster (or `docker` port-map surgery is not possible on a running container) with `extraPortMappings` including `8443 -> 30843`; `docker port smalt-control-plane` shows `30843/tcp`; a host curl to 8443 reaches the backend.

> UPDATE 2026-10-30 per gaps/35-egress-mapping-decision.md: G11-2 is DEFERRED,
> not open-as-written. The staged fix maps host **18443** → containerPort
> **30843**, NOT hostPort 8443 — the native host beam holds `127.0.0.1:8443`
> right now, so the `8443 -> 30843` mapping above collides with the native
> substrate as-written and would force a shutdown race on every bootstrap.
> Defer is valid while no consumer needs host→8443 (grep of this repo's
> consumer surface: zero 8443 references); mechanical flip trigger:
> `docker port smalt-control-plane | grep -q 30843` (see
> `courtroom-platform-az/scripts/egress_plane_discriminator.sh`).
- **G11-3 (MED)**: deploy a console workload referencing `smalt-console:local` (with `imagePullPolicy: Never`); pod reaches Running/Ready.
- **G11-4 (MED):** if a standing witness is required, give the witness pod a non-completing container (e.g. `sleep infinity` tail) or a DaemonSet-style keep-alive; READY 1/1+.
- **G11-7 (MED)**: after G11-1 lands, delete `kube-proxy-d2gwm` pod (self-heals); pod Running 1/1 on smalt-worker.
- **G11-5 (MED)**: run `docker image prune -af` + `docker builder prune -af` once the two smalt tags are re-buildable; `docker system df` reclaimable < 20% of colima disk, `/var` inside nodes < 80%.
- **G11-6 (LOW)**: script a deliberate `colima restart` resilience probe: capture `kubectl get nodes` before, restart, bounded-poll `kubectl get nodes` back to Ready and a pod to Running; store as a receipt in docs/jira/posh/v26.10.30/.

## Restart resilience (observed, unplanned)

Colima restarted at ~12:21:06 this session (host uptime 3h32; lima processes prove VM start 12:20:58; every kind
container "Up About a minute"). The kind cluster persisted across docker-daemon/VM loss: nodes returned to Ready
within ~2.5 min, control-plane static pods restarted, no data-plane loss beyond in-flight container state. kind on
colima with VZF uses persistent VM disk (virtiofs mount), so clusters DO survive colima restart (unlike raw docker
daemon loss on some setups). Evidence: etcd/apiserver AGE reset to 2m29s while pod AGE 32m unchanged.

## Verification ladder

Probes run: kubectl get nodes / pods -A / svc,endpoints / describe nodes (conditions) / deploy,sts -A; docker ps,
ps -a, images, system df; `docker exec <node> df -h /var/lib/containerd`; colima list/status; host uptime; process
start-time inspection for colima restart evidence. All read-only. No mutation, no prune, no restart was executed by
this lane (one file, read-only lane).
