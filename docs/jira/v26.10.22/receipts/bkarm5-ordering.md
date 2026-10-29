# Receipt: BK-ARM5 — Armstrong ordering audit (work → beautiful → fast)

**Standing: PARTIAL_ALIVE** — WORK and BEAUTIFUL stages audited to receipts + live witness; FAST stage measured with real docker/kind numbers but the full kind→first-200 chain is typed SUSPECT on one contaminated leg. Context: solo. Lane BK-ARM5, repo /Users/sac/smalt, 2026-10-22.

## 1. WORK — does the path work? YES (receipted + live)

- `receipts/bkswarm-court.md` (ALIVE, 5/5 at witness time): host-side 3-node `:peer` mesh — all-pairs ping 9/9, nested-erpc routing runner→A→B executing on B, per-node PARTITIONED state (write on B, `:error` from A), typed `{:node_down, B}` member death; kind legs with real kubectl exec + `smalt rpc` outputs embedded in the receipt (ping `:pong`, cross-pod `:ok`/`:error` partition proof).
- **Live re-witness this lane** (HEAD version of `test/integration/swarm_court_test.exs`, distributed runner `elixir --name court5@127.0.0.1 --cookie smalt_swarm_court -S mix test ... --include swarm_court`, `_build-ft-6be602ee`): **host-side legs 4/4 passed** ("route", "member death", mesh+contract legs); the 5th (kind leg) failed on cluster-selection collision — the leg grabs `kind get clusters | head -1`, which returned my scratch measurement cluster `arm5` (no smalt pods) mid-measurement. Typed as a leg defect (single-cluster assumption), not a regression; it passed 5/5 in BK-SWARM's witness on a single-cluster machine.
- BK-TOPO's matrix (`TOPOLOGY-MATRIX.md`, receipt `bktopo-matrix.md`) correctly types every cell SUPPORTED-WITH-THIS-WORK with falsifiers F1–F10 unexecuted — the design honestly pending, none claimed executed.

## 2. BEAUTIFUL — which artifact is the gate-checked one? Hand-written is deployable; rendered is the gate-checked REFERENCE

- The pack gates are real and non-vacuous: `gates/020_privilege_refusal.rq` (kubernetes-workload-pack v0.2.0) is fail-closed over raw securityContext blocks — only `privileged: false` / `allowPrivilegeEscalation: false` spelled exactly; any other mention = `PRIVILEGE_UNWAIVED` refusal, with a typed SecurityException waiver path. BK-MKTG witnessed a real mutation refused (FM-PACK-013, exit nonzero, no YAML written) and a clean render exit 0 (`receipts/bkmktg-pack-render.md`, PARTIAL_ALIVE).
- But the pack template renders **Deployment + one single-port Service** only. BK-MKTG's typed diff: the renders cannot model the backend StatefulSet, 3 Services (headless/ClusterIP/NodePort), 7 container ports, `RELEASE_NODE`/`POD_NAME` fieldRef env, nodePort 30080, tmpfs/Secret volumes. Rendered manifests "would boot a broken swarm".
- Deployable set confirmed in the recipes: `justfile.d/52-kind.just` header pins the law — hand-written `k8s/smalt-backend.yaml` (StatefulSet + Secret + ConfigMap + 3 Services) and `k8s/smalt-console.yaml` are applied; `k8s/*.gen.yaml` are "gate-checked REFERENCE only, never applied". Tree evidence agrees: `.gen.yaml` = Deployment+Service carrying the 4 hardening families (runAsNonRoot/allowPrivilegeEscalation/readOnlyRootFilesystem/resources); hand-written carries the same hardening (6 and 3 matches respectively) plus the deployable topology.
- **The beauty gate does not currently gate the deployable set.** The gates run over the RDF fact graph at render time; the deployable hand-written files have no equivalent gate. Path to beautiful-deployable (typed): (a) extend the pack to model StatefulSet + multi-port + env/volumes (pack backlog currently doesn't even list StatefulSet), then flips `.gen.yaml` → deployable; or (b) project a gate over `k8s/*.yaml` directly (e.g. a kubectl/dry-run + securityContext lint gate with a shim-court non-vacuity mutation), making the hand-written files first-class gate subjects. Either flips BK-MKTG's PARTIAL_ALIVE to ALIVE.

## 3. FAST — real docker/kind numbers (pre-built image; docker build excluded from timing)

Image sizes (docker images, this session):
```
smalt-hermetic:v261019   506MB   (the kind swarm image)
smalt-substrate:bkimg    738MB
smalt-console:bkimg      1.21GB
smalt:local              7.38GB  (the fat ancestor — 14.6x the hermetic image)
kindest/node:v1.34.0     1.48GB
```
The hermetic-image work (BK-IMG lanes, `tmp/kind-hermetic-build.log`, `tmp/kind-images-run*.log`) is exactly Armstrong-correct: work first, then the measured 7.38GB→506MB shrink.

Cold-start (scratch cluster `arm5`, image pre-built; logs `tmp/kind-arm5-coldstart.log` / `-2.log`):
- **Run 1: kind create FAILED at T=248s** — kubelet health (`127.0.0.1:10248/healthz`) refused; machine saturated (12+ concurrent test/witness processes; the live cluster's own `smalt-backend-0` sat in ContainerCreating 6+ min on the same pressure). Load-bound, not code-bound — the same lesson class as BK-ETSFLK: fixed bounds flake under load.
- **Run 2: kind create 35s (exit 0) → kind load 10s → kubectl apply→pods-Ready ≤1s each** (log receipts; BEAM release boots ~1s on the warm node). Total create→ready = **~46s**. But the port-forward → first-HTTP leg of run 2 returned `000` — contaminated: during the run the kubeconfig was rewritten under us (see §4 incident), killing the tunnel. The first-200 was instead witnessed **in-pod** after teardown of the pf leg: token dance (STS `POST /default/oauth2/v2.0/token` → 1274-byte bearer) then `GET /subscriptions?api-version=2099-01-01` → **HTTP 200** (and unauthenticated `GET /` → 401 RouteNotFound JSON proving the enforced-auth posture). Typed: cold-start = create 35s + load 10s + ready ~1s/pod; first-200 witnessed on the same pods, but the create→200 single-clock chain is SUSPECT (one contaminated leg), rerunnable on a quiet machine.
- Warm-path data point: the *previous* live `smalt` cluster showed a BEAM pod Ready in ~1s from apply, consistent with run 2.

## 4. Verdict + incident disclosures

**Ordering honored: YES, with one gate gap.** Work has receipts (swarm court ALIVE, host legs re-witnessed 4/4 live). Beautiful exists but is the *reference*, not the deployable set (typed gap above — the gate-checked artifact and the deployed artifact are different files). Fast came last and was measured, not smuggled: image shrink 7.38GB→506MB is a measured optimization landing after the courts; the cold-start numbers here are the first ones recorded, and where a bound failed it failed loudly (run 1, typed load-bound). No premature-optimization finding: no perf work preceded its court.

**Incident (typed, coordinator-visible):** mid-lane, another lane (BK-ACT's act runners, `act-kind-swarm-build-images-*` containers) deleted the live `smalt` kind cluster and created a 3-node `kind-smalt` cluster, rewriting `~/.kube/config` concurrently and repeatedly (contexts churned: `kind-smalt` vanished, reappeared as `kind-kind-smalt` with a CA that fails PEM parse; my python re-merge was clobbered twice; a read of ~/.kube/config returned an empty/truncated file mid-write). My scratch measurement cluster `arm5` was created/deleted cleanly and did not disturb the shared cluster; the port-forward contamination above is downstream of this storm. The new cluster's kubeconfig entry is left as its owner lane wrote it — I did not "fix" another lane's in-flight kubeconfig state. Successor hazard: any court that assumes `kind get clusters | head -1` is now ambiguous by construction.

**Lane hygiene disclosures:**
- Snapshot-swap per the no-stash law: the working-tree `test/integration/swarm_court_test.exs` carried another lane's non-compiling in-flight edit (malformed `defp kctx_exec` inside a `rescue` block, 67 uncommitted insertions — `defp` at line 492); I ran the court against the HEAD version (snapshot → restore, byte-verified via `git diff --stat` 67 insertions restored). Disclosure of the compile-freeze defect: the in-flight edit is still non-compiling in the tree.
- Findings for owners: (a) swarm court kind leg `head -1` cluster selection must pin the cluster (env `SMALT_KIND_CLUSTER` already exists); (b) BK-MKTG's PARTIAL_ALIVE closes only via the pack-extension or direct-manifest-gate path typed in §2; (c) cold-start has no committed receipt-level number before this receipt — this is the first.
