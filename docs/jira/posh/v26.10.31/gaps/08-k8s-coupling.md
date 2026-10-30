# Gap 08 — k8s-facing logic census: smalt-side vs posh charter scope (migration lane 8)

Date: 2026-10-30. Migration wave v26.10.31, lane 8 (read-mostly). Subject repos:
`/Users/sac/smalt` (smalt side) and `/Users/sac/smalt/posh` (posh side).
Cross-refs: gaps/03-kind-vs-aca.md, gaps/11-kind-ops.md, gaps/17-unmapped-ports.md (all
`docs/jira/posh/v26.10.30/gaps/`), gap 04 (posh-vs-charter) for the charter law quoted below.

Status line: **PARTIAL (wave-2 re-probed 2026-10-30 — see annex)** — every cell below is dispositioned from on-disk evidence; the posh
k8s shim exists only as kube_healer (exec-based, no client-go dep), and the smalt-side kind
estate is ALIVE (witnessed this session per gaps/11: nodes Ready, restart resilience held
through a real colima restart; backend CrashLoopBackOff at last probe — cluster face is
PARTIAL).

## Charter anchor

POSH charter-master §Rule 1 (docs/jira/posh/v26.10.30/dfcharter/charter-master.md:44):
"Go is restricted exclusively to ephemeral, stateless peripheral translation shims
(HashiCorp Plugin Framework v6, Kubernetes client-go). Go shall hold zero domain state and
zero persistent databases." client-go is *named* as the allowed Go k8s surface; nothing in
the current posh tree imports it (`grep k8s.io posh/go.mod` → 0 hits). The only k8s logic in
posh is `posh/internal/doctor/kube_healer.go` (259 lines), which drives `kubectl`/`curl` via
`exec.Command`/CommandRunner seams — a CLI-wrapper shim, not a client-go shim.

## Disposition table

Legend: ADAPTER-WORK = migrates to posh's k8s shim (image load, pod health probe,
kube_healer-style healing); DEPLOYMENT-TOPOLOGY = stays smalt-owned (what the manifests
declare, kind-config shape); COURT-INFRASTRUCTURE = operator/court tooling, arguably neither
tier's product. `MIG` = direction of migration.

| # | Surface (file) | What it does | Disposition | Notes / close condition |
|---|---|---|---|---|
| 1 | `k8s/kind-config.yaml` (39 L) | 1 CP + 2 workers, podSubnet/serviceSubnet, 4 extraPortMappings (9443/9444/5672/9080) | DEPLOYMENT-TOPOLOGY (smalt-owned) | Declares topology. Note: posh's kube_healer hardcodes its ports (DefaultNodePort 30943 / DefaultHostPort 9443) to this file's mapping — see row 10. |
| 1b | `k8s/kind/cluster.yaml` | Burn blueprint cluster (coordinator-owned, distinct from kind-config) | DEPLOYMENT-TOPOLOGY (smalt-owned) | Explicitly "distinct from the coordinator-owned k8s/kind/cluster.yaml" per kind-config header. |
| 2 | `k8s/smalt-backend.yaml` (281 L) | StatefulSet + headless/ClusterIP/NodePort Services, cookie/TLS Secrets, ConfigMap env contract, probes on /metadata/endpoints | DEPLOYMENT-TOPOLOGY (smalt-owned) | Hand-written manifest is canonical (BK-MKTG typed diff: `*.gen.yaml` renders never applied). Env contract matches lib/smalt/config.ex. Shared-TLS decision + close condition documented in header. |
| 2b | `k8s/smalt-console.yaml`, `k8s/posh-sidecar.yaml` (82 L) | Console Deployment + NodePort 30080; posh UDS sidecar witness pod | posh-sidecar.yaml: DEPLOYMENT-TOPOLOGY with an ADAPTER-WORK seam — the UDS socket-poll+connect witness (busybox nc -U) is exactly what a posh k8s shim should own (socket-present vs socket-connectable). Close: posh shim provides `posh doctor --k8s sidecar-verify` equivalent; then retire the busybox witness. | |
| 2c | `k8s/*.gen.yaml` renders (7 files) | Gate-checked REFERENCE renders, never applied | COURT-INFRASTRUCTURE (operator tooling) | BK-MKTG typed diff: renders cannot model StatefulSet/multi-port/env. Close: coverage compiler cell (SDK-parity register), not a migration target. |
| 2d | `k8s/burn/*` (5 files) | Burn blueprint (deployment, services, jobs) | DEPLOYMENT-TOPOLOGY (smalt-owned) | |
| 3 | `justfile.d/52-kind.just` (310 L) | kind lifecycle: up/down/status, image build+load, disk preflight (20000MB fail-closed + crictl prune), TLS mint, deploy/undeploy, console deploy, swarm-up, swarm-status (net_adm:ping witness) | SPLIT by recipe, mostly ADAPTER-WORK | Image build+`kind load docker-image` (row: kind-images), disk preflight+prune, TLS mint, deploy+readiness-wait, and swarm-status witness are all k8s-facing *operations* — the exact class the charter names as Go shim surface. kind-up/down and the fail-closed tool checks are operator ergonomics; migrate logic, keep `just` as thin wrapper. Close: each recipe's body lives in a posh subcommand (`posh doctor --k8s ...` family or a `posh kind` family); justfile recipes become one-line invocations with byte-comparable output. Falsifier: `just kind-images` and the posh shim disagree on preflight verdict for the same node state. |
| 3b | `k8s/r30-*` (namespace/identity/probe/driver/TLS-front) + `r30-driver-image/` | r30 courtroom runtime manifests + driver image | DEPLOYMENT-TOPOLOGY (smalt-owned) | |
| 4 | `scripts/court_plane_discriminator.sh` | GAP09/G17 plane discriminator: NATIVE/KIND/SPLIT/NONE verdict from lsof ownership + two-probe cross-check (body diff proven non-signature, header comment) | COURT-INFRASTRUCTURE | Operator tooling that disambiguates which plane answers a probe — neither tier's product. If anything, the *logic* (socket-ownership + advertised-endpoint cross-check) is a posh-diag-shaped concern; register as a typed divergence rather than migrating the bash. Close: posh diag owns the ownership+liveness cross-check natively and the bash is retired, or the divergence is registered. |
| 5 | `posh/internal/doctor/kube_healer.go` (259 L) + `kube_healer_test.go` | Cluster NodePort reachability + port-forward self-heal; hardcoded DefaultNodePort 30943 / HostPort 9443; exec-based (kubectl/curl), CommandRunner/Dialer/HTTPGetter seams; wired into `posh doctor` (doctor.go:611-615) | ADAPTER-WORK (posh-owned, partially built) | This is the fenced-dial consumer named by the lane. Gap: charter names client-go; tree uses exec-kubectl. Close condition either direction: (a) import client-go for typed pod/svc watch and drop exec-curl probes; or (b) register the exec-based shim as the typed divergence with a falsifier (client-go-only capability posh cannot express: watch streams, informer cache). Until then the charter-vs-tree mismatch is open. |
| 6 | `justfile.d/59-posh-ops.just` | posh operator recipes | COURT-INFRASTRUCTURE | Thin wrappers over `posh doctor` etc.; stay thin when the shim migrates. |
| 7 | k8s-facing scripts in `scripts/` (posh_doctor.sh, posh_status.sh, posh_sla.sh, posh_version.sh, harness_court.sh, harness_mutation_court.sh, posh_mutation_court.py, isolation_court.py, live_gate_court.sh, overlap_court.sh, p06_ingress_court.sh, r30-court.sh, courtroom_kind_court.sh, egress_plane_discriminator.sh) | Court/gate scripts over the k8s estate | COURT-INFRASTRUCTURE | Operator tooling; migrate logic to posh shim only when the shim exists (row 3). |
| 8 | `docker/Dockerfile.posh` + `kind load docker-image posh:sidecar` | posh sidecar image build/load | ADAPTER-WORK (image-load class, row 3) | Falls out of the kind-images migration. |

## Coupling findings (cross-tier)

1. **Port pinning skew.** kube_healer hardcodes DefaultNodePort 30943 / DefaultHostPort
   9443 as Go constants mirroring kind-config's extraPortMappings; kind-config is
   smalt-owned. A kind-config port change silently breaks posh's healer.
   KubeHealerOptions already carries NodePort/HostPort options — the default constants are
   the coupling point. Close: one source of truth (parse kind-config extraPortMappings or
   pin both to one config), keeping the env override. Falsifier: change 9443→9445 in
   kind-config and observe posh doctor's default-path healer probe the wrong port. This is
   the same port-matrix class as gaps/17
(4-of-13-port cluster face) and gaps/11 (8443 unmapped at docker boundary).
2. **exec vs client-go.** Charter names client-go as the allowed surface; tree has zero
k8s.io imports — the k8s shim is exec-kubectl/curl inside kube_healer. Either land
client-go (typed watch/informer) or register the exec shim as a KNOWN_DIVERGENCES row
(posh/KNOWN_DIVERGENCES.md exists for exactly this register).
3. **Witness split-brain risk.** gaps/17 documents that host-loopback gates
(scripts/p08_kind_gate.sh:46 → localhost:9446) resolve against the native host beam, not
the cluster — plane discrimination (court_plane_discriminator.sh exists for GAP09/G17
precisely because both planes answer). Any migration of probes into posh must go through
the discriminator's ownership-based signature, not host-loopback curl.

## Close conditions (summary)

- CC-1: posh k8s shim owns image-load, disk-preflight, TLS-mint, deploy+readiness-wait,
  swarm-status witness; `just` recipes are one-line wrappers; byte-comparable outputs
  (shim-court-able: shim the justfile body → shim must flip the verdict).
- CC-2: kube_healer port constants derive from kind-config (single source of truth) with
  env override; falsifier = kind-config port change flips posh doctor default-path verdict.
- CC-3: client-go import or a KNOWN_DIVERGENCES row registering the exec-based shim,
  with the client-go-only-capability falsifier.
- CC-4: posh-sidecar witness (busybox nc -U socket-connectability check) replaced by a
  posh-shim subcommand, or registered divergence.
- CC-5: COURT-INFRASTRUCTURE cells each get a coverage-compiler cell (pass /
  registered-divergence / loudly-MISSING), never a silent skip.

## Standing

- smalt-side kind estate: PARTIAL/ALIVE — cluster ALIVE per gaps/11 (nodes Ready, mappings
  present, restart resilience witnessed through a real colima restart); backend workload
  CrashLoopBackOff at last probe (PARTIAL).
- posh k8s shim: PARTIAL — kube_healer ALIVE inside posh doctor; charter-named client-go
  surface absent (0 k8s.io imports).
- Court infrastructure: ALIVE as operator tooling, PARTIAL as a coverage-registered surface
  (no coverage cells).

## Falsifier for this gap file itself

A disposition above is refuted if: (a) a file listed DEPLOYMENT-TOPOLOGY contains runtime
probe/heal logic (it would be ADAPTER-WORK), (b) posh already imports client-go anywhere
(`grep -r 'k8s.io/client-go' posh/ --include='*.go'` nonempty), or (c) a justfile recipe
body already delegates to a posh subcommand (row 3 close already satisfied).
## Wave-2 re-probe annex (2026-10-30, gap lane 8)

Fresh witnesses this session, per cell. Machine state note: colima VM is Running
(`colima list` exit 0) but the docker daemon inside is DOWN — the socket exists
(`/Users/sac/.colima/default/docker.sock`, mtime 14:39 today) yet nothing listens:
`docker ps` → "Cannot connect to the Docker daemon"; `nc -z 127.0.0.1 64378` → exit 1;
`kubectl --context kind-smalt get nodes` → "The connection to the server 127.0.0.1:64378
was refused", exit 1. A colima/docker restart was NOT attempted (concurrent wave lanes on
this host). The cluster-face probes therefore resolve BLOCKED (environment), not PARTIAL.

| # | Cell | Re-probe (cmd → exit) | Disposition | Inversion? |
|---|---|---|---|---|
| 1/1b | kind-config.yaml, cluster.yaml | `ls k8s/kind-config.yaml` on disk; topology files unchanged, no runtime logic | DEPLOYMENT-TOPOLOGY — ALIVE (as file-cells; live cluster face BLOCKED) | No |
| 2 | smalt-backend.yaml | On-disk, unchanged; `kubectl` probe unreachable (exit 1 above) | DEPLOYMENT-TOPOLOGY — ALIVE as manifest; live face BLOCKED | No |
| 2b | console/posh-sidecar.yaml | On-disk; cluster unreachable | Unchanged disposition; witness-retirement close (CC-4) still open | No |
| 2c | 7 *.gen.yaml renders | `ls k8s/*.gen.yaml | wc -l` → 7 | COURT-INFRASTRUCTURE — ALIVE (count matches) | No |
| 2d | k8s/burn/* | `ls k8s/burn/ | wc -l` → 5 files | DEPLOYMENT-TOPOLOGY — ALIVE | No |
| 3 | 52-kind.just (310 L) | `grep 'posh ' 52-kind.just` → 0 hits — no recipe delegates to a posh subcommand; `kind load docker-image` bodies present (lines 184-185) | SPLIT — ALIVE as documented; falsifier (c) NOT triggered | No |
| 3b | r30-* manifests | `ls k8s/r30-* | wc -l` → 9 | DEPLOYMENT-TOPOLOGY — ALIVE | No |
| 4 | court_plane_discriminator.sh | On-disk, unchanged | COURT-INFRASTRUCTURE — ALIVE | No |
| 5 | kube_healer.go (259 L) | `wc -l` → 259; constants intact (DefaultNodePort 30943 L17, DefaultHostPort 9443 L20); wired at doctor.go:611-615; refs in doctor.go/doctor_test.go/kube_healer_test.go | ADAPTER-WORK — ALIVE as code; live probe BLOCKED (docker down) | No |
| 6 | 59-posh-ops.just | Thin wrappers, unchanged | COURT-INFRASTRUCTURE — ALIVE | No |
| 7 | court/gate scripts | On-disk | COURT-INFRASTRUCTURE — ALIVE | No |
| 8 | Dockerfile.posh + kind load | On-disk; load path unreachable this session | ADAPTER-WORK — unchanged; BLOCKED live | No |

Charter-mismatch falsifier (b): `grep -rn 'k8s.io' posh --include='*.go'` → 0 hits;
`grep -c k8s.io posh/go.mod` → 0 (exit 1). Client-go remains 0-import — the exec-vs-client-go
divergence (CC-3) is still OPEN; `posh/KNOWN_DIVERGENCES.md` exists but carries no row for it.

### Cell status after wave-2

- Cluster face (rows 1-3b, 8 live probes): **BLOCKED** — docker daemon down inside a Running
  colima VM; unprobe-able without a host-state restart mid-wave. Prior gaps/11 witnesses
  (nodes Ready, restart resilience) stand as-of-date, not refreshed.
- File/manifest cells (all rows, static): **ALIVE** — every file cited in the table exists
  at the documented size/count; no cell inverted to a different tier.
- posh shim (row 5): **PARTIAL** — code ALIVE (259 L, wired, constants intact), charter
  divergence (exec vs client-go) OPEN, live probe BLOCKED.
- Close conditions CC-1..CC-5: all remain OPEN; none satisfied by this session; none refuted.

### Risks

- Port-pin skew (finding 1) unchanged: kube_healer constants still mirror kind-config by
  hand; untestable live this session.
- Docker-daemon-down inside a Running colima VM is itself a new environment defect — if it
  persists into the next wave it degrades every kind/k8s court lane, not just this one.
