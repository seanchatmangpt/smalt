# BK-KIND2 — swarm spread on the multi-node kind cluster

- **Lane**: BK-KIND2
- **Date**: 2026-10-22
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: 3-node kind cluster `kind-smalt` (1 CP + 2 workers, from
  `k8s/kind-config.yaml`), swarm StatefulSet `smalt-swarm` (2 replicas,
  required podAntiAffinity on `kubernetes.io/hostname`), image
  `smalt-hermetic:v261019` (sha256 `eeebb540…da35`, loaded into all 3 nodes).

## What changed vs BK-SWARM

BK-SWARM's kind witness ran on a 1-node cluster: the honest typed limitation
was that the 2 replicas could not spread. This lane closes it: the cluster was
recreated from `k8s/kind-config.yaml` (1 CP + 2 workers) and the swarm
StatefulSet redeployed with REQUIRED podAntiAffinity added
(scratch manifest `/tmp/bkkind2/smalt-swarm-spread-sts.yaml`, not committed —
same pattern as BK-SWARM's /tmp/bkswarm scratch manifest). The anti-affinity
is the only manifest delta vs BK-SWARM's STS; container contract is identical.

## Leg 0 — cluster + spread (kubectl get pods -o wide)

```
$ kind create cluster --config k8s/kind-config.yaml --wait 240s
 ✓ Ready after 11s
Set kubectl context to "kind-kind-smalt"

$ kubectl get nodes -o wide
NAME                       STATUS   ROLES           AGE   VERSION   INTERNAL-IP
kind-smalt-control-plane   Ready    control-plane   18m   v1.34.0   172.18.0.2
kind-smalt-worker          Ready    <none>          18m   v1.34.0   172.18.0.4
kind-smalt-worker2         Ready    <none>          18m   v1.34.0   172.18.0.3

$ kubectl get pods -o wide -l app=smalt-swarm   (post anti-affinity STS apply)
NAME            READY   STATUS    RESTARTS   AGE   IP           NODE
smalt-swarm-0   1/1     Running   0          3s    10.244.2.2   kind-smalt-worker2
smalt-swarm-1   1/1     Running   0          2s    10.244.1.3   kind-smalt-worker
```

pod-0 on worker2, pod-1 on worker — **different hosts**, the spread
BK-SWARM's 1-node cluster could not witness.

## Leg 1 — cross-NODE net_adm:ping, all-pairs (both directions, fresh)

```
p0_to_p1_fresh: :pong
p1_to_p0_fresh: :pong
```

(witnessed after `:erlang.disconnect_node/1` of the prior incarnation's
connection — see "Typed notes" for the transient-pang episode).

Peer liveness additionally witnessed via erpc, both directions:

```
erpc_p0_to_p1: :"smalt@smalt-swarm-1.smalt-swarm-headless.default.svc.cluster.local"
erpc_p1_to_p0: :"smalt@smalt-swarm-0.smalt-swarm-headless.default.svc.cluster.local"
```

Final stable mesh from pod-0 (`node(), :erlang.nodes()`):

```
final_mesh_from_p0: [
  :"smalt@smalt-swarm-0.smalt-swarm-headless.default.svc.cluster.local",
  [:"smalt@smalt-swarm-1.smalt-swarm-headless.default.svc.cluster.local"]
]
```

The distribution now crosses the docker network boundary for real: pod-0's
BEAM talks to pod-1's BEAM through the worker-to-worker pod route
(10.244.2.x on worker2 ↔ 10.244.1.x on worker), not a shared kernel.

## Leg 2 — StatefulSet scale witness (swarm-up 3)

```
$ kubectl scale sts smalt-swarm --replicas=3
smalt-swarm-2   0/1   Pending   0s   <none>   <none>

$ kubectl describe pod smalt-swarm-2   (typed scheduler verdict)
Warning  FailedScheduling  0/3 nodes are available: 1 node(s) had untolerated
taint {node-role.kubernetes.io/control-plane: }, 2 node(s) didn't match pod
anti-affinity rules. preemption: 0/3 nodes: 1 Preemption is not helpful, 2 No
preemption victims found.
```

The anti-affinity refuses a third placement — the swarm is capacity-capped at
2 schedulable hosts (2 workers; CP is tainted and correctly untolerated).
Scaled back to 2; both pods Running, same nodes as Leg 0. Swarm-up-3 with
spread requires a third schedulable worker — recorded as the successor
condition, not a failure: the anti-affinity did exactly its job, loudly.

## Leg 3 — per-pod partitioned contract, re-witnessed CROSS-NODE

```
put_on_p0:            :ok          (Smalt.Store.put(:smalt_subscriptions, "bkkind2-crossnode-key", %{v: 42, node: node()}))
get_on_p1_expect_error: :error     (Smalt.Store.get(:smalt_subscriptions, "bkkind2-crossnode-key"))
get_on_p0_expect_ok:    {:ok, %{node: :"smalt@smalt-swarm-0…", v: 42}}
```

The BK-SWARM consistency contract (write on one pod, `:error` on the other,
read-your-write only on the writer) holds with the pods on DIFFERENT k8s
nodes — partitioned, not replicated, now proven beyond the single-host case.

## Typed notes (blockers hit and resolved mid-lane)

1. **Cluster recreate**: the pre-existing single-node cluster was internally
   named `smalt` (not `kind-smalt`), so `kind delete cluster --name kind-smalt`
   panicked without deleting; `--name smalt` deleted it cleanly. The new
   cluster is `kind-smalt` per the config.
2. **Shared-kubeconfig corruption (concurrent-lane hazard)**: mid-lane, the
   `kind-kind-smalt` entry in the shared `~/.kube/config` had its CA /
   client-cert fields replaced with 9–12 bytes of binary garbage — every
   kubectl call failed `unable to parse bytes as PEM block`. Worked around by
   driving the lane through a freshly generated
   `kind get kubeconfig --name kind-smalt > /tmp/bkkind2/kindcfg.yaml`. The
   shared kubeconfig entry remains corrupted and needs `kind export kubeconfig
   --name kind-smalt` to repair — left to the coordinator (other lanes'
   kubeconfig writes are in flight; a blind repair races them).
   Sibling-lane turbulence was heavy: pods were killed/recreated mid-lane
   (events showed `Killing … pod/smalt-swarm-0/1` plus a sibling lane's
   `smalt-backend` apply with `ErrImageNeverPull` on `smalt:local`).
3. **Transient DNS NXDOMAIN window**: right after a churn wave, CoreDNS
   returned NXDOMAIN for the headless pod FQDNs from the pods for several
   minutes; it recovered on its own (witnessed `:pong`-grade resolution via
   busybox nslookup afterwards). Not persisted; if it recurs, it is a
   kindnet/CoreDNS convergence issue, not smalt.
4. **net_adm:ping :pang episode** — the first several ping attempts returned
   :pang despite TCP-9000/epmd-4369 probes being green. Bisect with a
   throwaway BEAM (`-boot <release>/start -boot_var RELEASE_LIB …`) proved
   cross-node handshake works. Root pattern: after a pod replacement, the
   survivor holds a connection entry to the DEAD incarnation; `net_adm:ping/1`
   toward that entry returns :pang, and `:erlang.disconnect_node/1` clears it
   (fresh ping :pong). Repetition check (3x on the stable pair) showed
   ping-while-connected also :pong — so this is stale-incarnation semantics,
   not a "ping pangs connected nodes" law. Operational face for swarm courts:
   after any pod churn, `disconnect_node` (or tick expiry) before trusting a
   ping result.
5. **smalt-backend StatefulSet** (`k8s/smalt-backend.yaml`, image `smalt:local`)
   was NOT deployed — a sibling lane is concurrently driving that manifest
   (its `smalt-backend-0` ErrImageNeverPull event is in this lane's captured
   events). This lane's spread witness rides the hermetic-image swarm STS per
   BK-SWARM precedent. Successor: redeploy backend STS once `smalt:local` is
   loaded into the 3 nodes and the sibling lane's apply settles.

## Files

- `docs/jira/v26.10.22/receipts/bkkind2-spread.md` (this receipt — the only
  staged file; the spread STS manifest stays scratch in /tmp/bkkind2/, same
  pattern as BK-SWARM).
