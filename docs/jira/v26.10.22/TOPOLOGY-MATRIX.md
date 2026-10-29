# Deployment Topology Matrix (BK-TOPO)

Lane BK-TOPO deliverable, v26.10.22. Companion receipt:
`receipts/bktopo-matrix.md`. Every cell is typed SUPPORTED-NOW /
SUPPORTED-WITH-THIS-WORK / UNSUPPORTED (typed falsifier). All identifiers
below are read from the tree (lib/smalt/config.ex, workspace/lib/smalt.ts,
lib/smalt/cluster.ex, scripts/gen_dev_cert.sh, workspace/next.config.mjs,
test/integration/peer_two_node_court_test.exs,
docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md).

## Dimensions and values

| dim | values |
|---|---|
| Backend | `host` (current `just up`) · `kind-1` (single kind pod) · `kind-swarm` (N replicas, Erlang distribution via `Smalt.Cluster`) |
| Frontend | `host-dev` (`next dev`/`next start` on the laptop) · `kind-pod` (console in-cluster behind a Service/Ingress) |
| Runner | `laptop` (docker/kind local) · `act` (GitHub Actions run locally, CI of the k8s path) |
| Scale | `1` · `swarm` (backend-only; swarm frontend = backend swarm + one frontend pod aimed at the backend Service) |

## Matrix (frontend x backend; runner and scale annotated per cell)

| # | Frontend \ Backend | host | kind-1 | kind-swarm |
|---|---|---|---|---|
| 1 | host-dev | **SUPPORTED-NOW-WITNESSED** (runner: laptop, scale 1; receipt `receipts/bkcell1-witnessed.md`) | SUPPORTED-WITH-THIS-WORK (laptop, 1; BK-IMG + BK-K8SM + BK-JUSTK) | SUPPORTED-WITH-THIS-WORK (laptop, swarm; BK-SWARM) |
| 2 | kind-pod | SUPPORTED-WITH-THIS-WORK (laptop, 1; BK-IMG + BK-JUSTK) | SUPPORTED-WITH-THIS-WORK (laptop, 1; BK-IMG + BK-K8SM + BK-JUSTK + BK-TOPOV) | SUPPORTED-WITH-THIS-WORK (laptop, swarm; all of the above + BK-SWARM) |
| 3 | kind-pod + act | UNSUPPORTED (F3) | UNSUPPORTED→flips via BK-ACT (F3+F8) | UNSUPPORTED (F3+F8+F10) |

## Per-cell status, wiring contract, falsifiers

Notation: `ARM=9443`, `TLS-twin=9444`, `data=8443`, `amqp=5672`,
`eh=5673` are the substrate's fixed surfaces. Work-item owners: BK-IMG
(images), BK-K8SM (k8s manifests), BK-JUSTK (justfile recipes), BK-SWARM
(clustering), BK-ACT (local CI), BK-TOPOV (verification lane running the
per-cell falsifiers).

### Cell 1a — host / host-dev / laptop / 1 — SUPPORTED-NOW-WITNESSED (BK-CELL1, `receipts/bkcell1-witnessed.md`)

- Wiring: backend `just up` (`SMALT_BIND_IP=127.0.0.1` default posture);
  console `next dev` with `NEXT_PUBLIC_SMALT_ARM=http://127.0.0.1:9443`,
  `NEXT_PUBLIC_SMALT_EGRESS=http://127.0.1:8443` defaults already in
  `workspace/lib/smalt.ts`. SDK legs ride the 9444 TLS twin with
  `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`; `SSL_CERT_FILE` same CA.
- Falsifier F1: `just up` + `next dev`, a console page issuing `smaltFetch`
  returns backend data and `assertLocalUrl` passes (it does by construction
  — loopback defaults). Cell falsified if console fetch throws
  `Air-gap violation`.
- Witnessed (BK-CELL1, 2026-10-22): F1 executed for real — console root
  HTTP 200 (air-gap headers intact), BFF `POST /api/sync/state` HTTP 200
  with a real cosmos etag applied through `smaltFetch` to the loopback
  data plane :8443 (substrate UP, `:enforce` mode, STS mint leg). Output
  embedded in `receipts/bkcell1-witnessed.md`.
- Scale=swarm on host: UNSUPPORTED sub-cell (F2): `Smalt.Cluster` is
  DNS-poll based (`dns_name` required); a laptop host boot has no headless
  DNS name, so multi-node on host requires /etc/hosts fakery — typed
  UNSUPPORTED rather than half-wired. Falsifier F2: boot two host nodes
  with `config :smalt, :cluster, enabled: true, dns_name: nil` →
  `Smalt.Cluster.start_link/1` raises (enabled requires dns_name).

### Cell 1b — kind-1 backend / host-dev frontend / laptop / 1 — SUPPORTED-WITH-THIS-WORK

- Wiring: backend pod exposes 9443/8443 via kind `extraPortMappings` (or
  NodePort); console stays on the laptop with
  `NEXT_PUBLIC_SMALT_ARM=http://127.0.0.1:<mapped>` — loopback allowlist in
  `assertLocalUrl` still passes because the URL hostname stays 127.0.0.1.
  TLS twin: laptop trusts the in-cluster CA by exporting the pod's CA
  secret and pointing `SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS` at it.
- Work items: BK-IMG (backend image), BK-K8SM (backend Service + Deployment
  manifest), BK-JUSTK (`just k8s-up/k8s-down/k8s-status`).
- Falsifier F3a: `just k8s-up` boots a single backend pod; from the laptop,
  `curl --cacert <exported-ca> https://127.0.0.1:<mapped-tls>/` answers
  200-class and an SDK probe exits 0 (exit-code contract: 0 pass / 1 fail /
  2 substrate down / 3 skip). Falsified if the pod boots but the mapped
  probe exits != 0.

### Cell 1c — kind-swarm backend / host-dev frontend / laptop / swarm — SUPPORTED-WITH-THIS-WORK (BK-SWARM)

- Wiring: backend headless Service `<name>-headless` (DNS A records);
  backend Deployment sets
  `config :smalt, :cluster, enabled: true, dns_name: "<name>-headless.<ns>.svc.cluster.local", node_prefix: "smalt"`,
  remote nodes are `:"smalt@<pod-ip>"` (cluster.ex contract). Cookie via
  `RELEASE_DISTRIBUTION`-style env: set the Erlang cookie (shared Secret
  mounted or `vm.args`-equivalent `-setcookie`), `--sname`/`--name` with
  the pod IP, bounded `inet_dist` port range published on the headless
  service. State: single-node ETS/DETS tables are per-node — the swarm
  cell is typed in-memory-per-node (no cross-node table merge work item in
  this wave; that is a separate order if wanted).
  No code change required in lib/ — `Smalt.Cluster` already implements
  DNS-based joining with bounded retries; the work is manifest + cookie
  plumbing only.
- Falsifier F4: N=2 replicas on kind; `:erpc.call(:"smalt@<pod-ip>",
  Node.list, :self, [])` from pod A shows pod B, and
  `Smalt.Cluster.cluster_status().joined == 2`. Falsified if `joined`
  stays 1. Precedent court: `peer_two_node_court_test.exs` (loud-skip
  without a distributed runner node — BK-SWARM must run it under
  `elixir --name ... --cookie ...`).

### Cell 2a — kind-pod frontend / host backend / laptop / 1 — SUPPORTED-WITH-THIS-WORK

- **Required code change (typed)**: `assertLocalUrl`
  (workspace/lib/smalt.ts) hard-refuses every non-loopback hostname. A
  k8s-hosted console must reach the backend via service DNS. Change: an
  env-typed allowlist extension, e.g.
  `NEXT_PUBLIC_SMALT_ALLOWED_HOSTS` (comma list, default empty ⇒
  behavior byte-identical today; build-time inlined like the other
  NEXT_PUBLIC_* vars), appended to the hostname check in
  `assertLocalUrl`. Companion: `caller-gate.ts` `sync_state_non_loopback`
  host/origin gate needs the same typed extension (`SMALT_BFF_*` posture
  preserved — the allowlist widens only the host check, never disables
  the gate). Air-gap posture is preserved: default empty ⇒ today's
  behavior; non-empty ⇒ explicitly operator-declared hosts only, still
  no wildcard egress. ESLint raw-fetch ban unchanged — traffic stays on
  `smaltFetch`.
- Wiring: console pod, `NEXT_PUBLIC_SMALT_ARM=http://smalt-arm.<ns>.svc:9443`
  (or the TLS twin `https://...:9444` for SDK-parity legs),
  `NEXT_PUBLIC_SMALT_EGRESS=http://smalt-data.<ns>.svc:8443`; backend stays
  on the host (kind reaches the laptop host via `host.docker.internal` on
  the pod side or the console in-cluster calls out only to in-cluster —
  this cell is typed as console-pod → host backend via the kind
  host-mapping, the weaker of the two frontend-pod cells; the strong cell
  is 2b).
- Work items: BK-TOPOV runs the falsifier; the code change above is a
  required work item assigned to the lane owning workspace/lib (named
  BK-IMG-adjacent; see §Work items, WI-1).
- Falsifier F5: console pod in-cluster, backend on host; a console page
  issues `smaltFetch` to a non-loopback backend URL and succeeds only when
  `NEXT_PUBLIC_SMALT_ALLOWED_HOSTS` names that host; with the var unset
  the fetch must still throw `Air-gap violation` (non-vacuity leg).

### Cell 2b — kind-pod frontend / kind-1 backend / laptop / 1 — SUPPORTED-WITH-THIS-WORK

- Wiring: everything in-cluster. Console → backend over service DNS
  (`smalt-arm`/`smalt-data`/`smalt-tls` Services). TLS twin: the CA
  (`scripts/gen_dev_cert.sh` material in a k8s Secret) is mounted into the
  console pod; `NODE_EXTRA_CA_CERTS` points at the mounted CA. The existing
  leaf is `CN=localhost` only — no SAN for service DNS names, so
  **WI-2 (required)**: extend `gen_dev_cert.sh` (or a k8s variant) to mint
  a leaf with SANs `smalt-tls.<ns>.svc` (+ cluster-local FQDN), OR the
  console dials the plaintext 9443 arm port in-cluster and the twin is
  exercised only from the laptop via port-forward. Both postures are
  typed; the SAN-mint posture is the supported one.
- Laptop trust of the k8s-hosted twin: `kubectl port-forward` + the
  exported CA at `SSL_CERT_FILE`, or an Ingress with the same leaf (SAN
  must then also cover the Ingress host).
- Work items: BK-IMG (console image: next.config.mjs gains
  `output: "standalone"` — **WI-3**, currently absent from
  workspace/next.config.mjs), BK-K8SM (console Deployment + Service +
  optional Ingress, backend Services), BK-JUSTK recipes.
- Falsifier F6: console pod → backend pod; `smaltFetch` over service DNS
  succeeds (200 from an arm read), console pod → any host NOT in the
  allowlist still throws. SDK-parity leg: from the laptop through
  port-forward, a ts SDK probe against the k8s-hosted twin exits 0.

### Cell 2c — kind-pod frontend / kind-swarm backend / laptop / swarm — SUPPORTED-WITH-THIS-WORK

- Wiring: cell 2b + cell 1c. Console pod points `NEXT_PUBLIC_SMALT_ARM` at
  the backend **ClusterIP Service** (load-balanced across replicas — note:
  ARM is stateful-per-node for ETS tables; typed hazard H1: requests may
  land on a replica that lacks the entity; mitigation = the BK-B4R
  send-gate `ensure_entity/1` pattern (KD-86, closed —
  receipts/bkb4rc-send-gate-court.md) applied to the write paths the
  console exercises; this is **WI-4**, owner BK-SWARM with BK-TOPOV
  verifying). AMQP: console-side send via the same gate over
  `smalt-amqp.<ns>.svc:5672`.
- Falsifier F7: N=2; through the ClusterIP Service, send-to-queue then
  receive-from-queue across 20 requests that must round-robin (typed by
  reading `Smalt.Cluster.cluster_status()` from each pod to prove both
  were hit); every send+receive delivers the intact body (KD-86 posture).
  Falsified if any request 500s for lack of the entity on the receiving
  replica.

### Cell 3 — runner = act

- 3a (host backend under act): UNSUPPORTED. Falsifier F3: no kind/k8s
  workflow exists (`.github/workflows/` has no kind-path workflow);
  `act` runs workflows, not bare compose — there is nothing to run. Closes
  when BK-ACT lands the workflow AND a green local `act` run receipt
  exists.
- 3b (kind-1 under act): UNSUPPORTED→SUPPORTED-WITH-THIS-WORK via BK-ACT:
  a workflow job that creates a kind cluster, loads the BK-IMG images,
  applies BK-K8SM manifests, runs falsifiers F5/F6 as the court, emits a
  receipt. Falsifier F8: `act -j k8s-court` locally exits 0 with the
  court receipt; falsified if the job passes only on GitHub-hosted
  runners.
- 3c (kind-swarm under act): UNSUPPORTED (F3+F8+F10) until 1c and 3b
  close; additional falsifier F10: the act job's kind cluster must carry
  DNS-resolvable headless service (kind's default CoreDNS does — the
  court asserts `Smalt.Cluster.cluster_status().joined == N` from inside
  a pod via `kubectl exec`, not from the host).

## Work items (each closes one or more cells)

| WI | item | owner | closes |
|---|---|---|---|
| WI-0 | Backend image (Erlang/OTP + smalt release, `SMALT_BIND_IP=0.0.0.0`, planes env) | BK-IMG | 1b, 2a, 2b, 2c |
| WI-1 | `assertLocalUrl` + `caller-gate.ts` env-typed allowlist (`NEXT_PUBLIC_SMALT_ALLOWED_HOSTS`, default empty = byte-identical) | BK-IMG (workspace owner-adjacent; reassign if a workspace lane exists) | 2a, 2b, 2c |
| WI-2 | TLS leaf SANs for service DNS (`gen_dev_cert.sh` k8s variant or SAN flag) + CA/leaf k8s Secrets; laptop trust doc line | BK-K8SM | 2b, 2c (and 1b trust path) |
| WI-3 | `output: "standalone"` in workspace/next.config.mjs + console image | BK-IMG | 2a, 2b, 2c |
| WI-4 | Swarm hazard H1 mitigation: `ensure_entity/1`-class gate on console-exercised write paths behind the ClusterIP Service | BK-SWARM | 2c (partial), 1c |
| WI-5 | k8s manifests: backend Deployment/Service(+headless), console Deployment/Service/Ingress, cookie Secret, CA/leaf Secrets | BK-K8SM | 1b, 1c, 2a–2c |
| WI-6 | justfile module `justfile.d/NN-k8s.just`: `k8s-up/down/status/court` (per-module prefix rule, `ROOT :=` per-module naming law) | BK-JUSTK | all kind cells |
| WI-7 | `Smalt.Cluster` enablement plumbing in Deployment env (dns_name, node_prefix, cookie, dist port range) | BK-SWARM | 1c, 2c |
| WI-8 | act workflow `k8s-court` + green local run receipt | BK-ACT | 3a→close, 3b, 3c |
| WI-9 | BK-TOPOV: run F1–F10 per closed cell, emit receipt per cell, exit-code contract 0/1/2/3 | BK-TOPOV | verification of every cell |

## Hazard register

- H1: ClusterIP load-balancing across a stateful-per-node backend (ETS) —
  mitigated by WI-4; unmitigated, 2c stays UNSUPPORTED.
- H2: cookie sharing across replicas — a shared cookie Secret is required;
  a missing/mismatched cookie shows up as `cluster_status().joined` stuck
  below N (F4 catches it).
- H3: the peer court loud-skips without a distributed runner node — any
  swarm court must launch `mix test` under `--name`/`--cookie` or the skip
  reads as a fake pass. (BK-SWARM + BK-ACT obligation.)
- H4: NEXT_PUBLIC_* are build-time inlined — the allowlist is baked at
  image build; changing it requires an image rebuild, not a pod restart.
  Typed, not a defect.

## Boundary

- State persistence across pod restarts (DETS/PVC) is OUT of this wave's
  matrix; all kind cells are typed ephemeral-state. Adding PVC-backed state
  is a future order.
- Multi-namespace, TLS termination at Ingress with external CAs: OUT.
- Windows/WSL runners: OUT.
