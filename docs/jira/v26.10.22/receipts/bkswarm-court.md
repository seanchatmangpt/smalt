Standing: ALIVE (host-side 3-node legs + kind legs, 5/5 passed) · Context: solo

# BK-SWARM — swarm court receipt

## What was built

`test/integration/swarm_court_test.exs` — the swarm court. Host-side legs always runnable (loud typed skip when the runner is not distributed); kind leg runs real kubectl work when a kind cluster + >=2 Running `smalt-swarm` pods exist, loud typed skip (`{:skip, :no_kind_cluster}`) otherwise.

## Host-side 3-node swarm (laptop, self-booted)

Three :peer nodes (`swarm_a/b/c@127.0.0.1`, cookie `smalt_swarm_court`), each shipped a court-side `Smalt.Store` + Health face as beam binaries (`:code.load_binary/3`), full app booted under `mix test` on the runner.

Leg (a) all-pairs ping mesh — witnessed from inside every node, plus runner↔peer:

```
[swarm-court] 3-node mesh UP: [:"swarm_a@127.0.0.1", :"swarm_b@127.0.0.1", :"swarm_c@127.0.0.1"]
[swarm-court] all-pairs ping: 9/9 pong (3x3, self-diagonal included)
```

Leg (b) routing — runner→A→B (nested erpc), reply carries B's node name, state row written through the A→B route read back through the same route:

```
[swarm-court] route: runner→A→B executed on swarm_b@127.0.0.1; routed write read back via A→B
```

Leg (c) consistency contract typed — per-node partitioned, NOT replicated. Write on B, read same key on A → `:error`; on B → `{:ok, %{v: 42}}`:

```
[swarm-court] contract: per-node partitioned state proven (write on B invisible from A)
```

Leg (d) member death mid-mesh — stop B while a call is in flight: typed `{:error, {:node_down, B}}` (no hang); A and C keep serving; fresh peer re-boots under the same name and re-joins the mesh:

```
[swarm-court] member death: typed {:node_down, B}; A and C kept serving; fresh B re-joined mesh
```

## Kind legs (cluster `smalt`, ctx `kind-smalt`, 1 Ready node, 2-pod StatefulSet)

- Image `smalt-hermetic:v261019` (sha256 eeebb5405cb7…) loaded via
  `kind load docker-image smalt-hermetic:v261019 --name smalt`.
- Scratch manifest `/tmp/bkswarm/smalt-swarm-sts.yaml` (2-replica StatefulSet
  + headless Service `smalt-swarm-headless`, no anti-affinity so both pods
  schedule on the 1-node kind cluster; k8s/burn's Deployment needs >=2 nodes
  by required anti-affinity). Not committed — mission bounds the commit to
  court + receipt.
- Deploy command: `kubectl --context kind-smalt apply -f /tmp/bkswarm/smalt-swarm-sts.yaml`.
- Pods reached stable Running (initial RestartCount 4 during first boot,
  then 0 restarts across redeploy with fixed env order).

### Kind witness output (real, 2026-10-22 ~09:30 PDT)

```
$ kubectl --context kind-smalt exec smalt-swarm-0 -- .../smalt rpc 'Node.list() |> IO.inspect()'
[:"smalt@smalt-swarm-1.smalt-swarm-headless.default.svc.cluster.local"]
$ kubectl --context kind-smalt exec smalt-swarm-1 -- .../smalt rpc ':net_adm.ping(:"smalt@smalt-swarm-0...")'
:pong
$ kubectl --context kind-smalt exec smalt-swarm-0 -- .../smalt rpc 'Smalt.Store.put(:smalt_subscriptions, "bkswarm-kind-key", %{v: 42})'
:ok
$ kubectl --context kind-smalt exec smalt-swarm-1 -- .../smalt rpc 'Smalt.Store.get(:smalt_subscriptions, "bkswarm-kind-key")'
:error
$ kubectl --context kind-smalt exec smalt-swarm-0 -- .../smalt rpc 'Smalt.Store.get(:smalt_subscriptions, "bkswarm-kind-key")'
{:ok, %{v: 42}}
```

## Honest swarm data-plane contract (typed, with falsifiers)

- **Any pod serves any SDK call**: each pod is a full Azure-emulator surface.
  Falsifier: an SDK call to any pod returning an error class that a loopback
  boot does not return.
- **Cross-pod state: per-pod / partitioned / NOT replicated** — typed from
  both the host leg (c) and kind leg k3, both proving the partition. The ARM
  face's state lives in the same per-pod ETS, so the contract carries: a
  request to pod A that touches state is NOT consistent-readable from pod B.
  Falsifier: a write on one node visible from another — leg (c)/k3 actively
  asserts the NEGATIVE, so a future replication feature flips the leg to
  fail until the contract is re-typed (re-type, never delete the leg).
- **Member death**: typed `{:node_down, node}`, remaining swarm keeps
  serving (host leg (d)). Falsifier: a hang instead of the typed failure.
- **Loud-skip contract**: undistributed runner → all 5 tests invalid with
  the SKIP line on stderr, never a fake pass.

## Commands (real, embedded)

```
$ MIX_BUILD_ROOT=_build-bkswarm elixir --name bkswarm-court@127.0.0.1 --cookie smalt_swarm_court -S mix test test/integration/swarm_court_test.exs
Result: 5 passed
$ MIX_BUILD_ROOT=_build-bkswarm mix test test/integration/swarm_court_test.exs
[swarm-court] SKIP (loud): runner node is not distributed.
Result: 0 tests, 5 invalid        # loud skip path, exit non-zero, no fake pass
```

Reruns with different seeds (random leg order): 5 passed each.

## Typed notes for successor lanes

1. `smalt eval` boots NON-distributed (`:nonode@nohost`) — `smalt rpc` is
   the witness face that dials the live release node.
2. k8s env expansion: `$(POD_NAME)` expands only when POD_NAME is defined
   EARLIER in the pod env list. k8s/burn/smalt-deployment.yaml has
   RELEASE_NODE before POD_NAME — with a bare container env (no release
   env.sh re-expansion) the node name would carry a literal `$(POD_NAME)`.
   The burn Deployment is lane-owned (not edited here); successors deploying
   it should reorder the env entries.
3. k8s/burn Deployment requires >=2 real nodes (required anti-affinity);
   the current kind cluster has 1 Ready node, hence the scratch 2-pod
   StatefulSet as the kind subject.
4. test-budget will see 5 new unbudgeted tests at next seed.
5. Lane build root `_build-bkswarm` left in place (coordinator deletes lane
   build roots at integration per lane-lease law).
