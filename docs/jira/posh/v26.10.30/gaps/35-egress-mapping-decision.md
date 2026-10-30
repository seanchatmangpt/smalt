# 35: Egress 8443 NodePort Mapping — Decision (GAP11/G17)

## Status line

**Status: PARTIAL** — decision made and recorded (the decision is ALIVE as a
session-run observation; the mapping itself is UNDEPLOYED). Live-state
receipts below re-read from disk this session, 2026-10-30:

- `kubectl get svc smalt-backend-nodeport` → `8443:30843/TCP` NodePort exists
  in-cluster; `docker ps` shows smalt-control-plane maps `9080->30080`,
  `9443->30943`, `9444->30944`, `5672->30572` — **no `->30843` docker map**.
  GAP11 confirmed live.
- `lsof -nP -iTCP:8443 -sTCP:LISTEN` → `beam.smp` (pid 90813) holds
  `127.0.0.1:8443`. The native beam binds 8443 **right now** — option (b)'s
  collision is not hypothetical, it is the current state.
- `grep -rn 8443` over `scripts/`, `.github/`, `apps/`, `infra/` of
  courtroom-platform-az → **zero hits**. Nothing in this repo (the WAVE's
  consumer surface: guard scripts, CI workflows, tenant apps) references 8443.

## Which plane/port is actually in question

Port 8443 is the smalt **data-plane / egress** face (`:egress_port`, default
8443 — `~/smalt/scripts/release.txt:13`, `lib/smalt/egress_router.ex`). The
**ARM control plane is 9443** (already mapped and reachable: `9443->30943`).
Per `~/smalt/docs/jira/posh/v26.10.30/gaps/17-unmapped-ports.md`, GAP11
concerns only the 8443 leg.

Consumers checked:

- **TFPOSH**: ARM-only (9443). Not a consumer of 8443.
- **smalt health fallback**: the lane-10 8443 fallback is exercised inside the
  smalt tree's own probes (`scripts/acceptance_probe.exs` defaults
  `:data_base` to `127.0.0.1:8443`; `deferred_boot_probe.exs` same) — a
  smalt-internal consumer, not a courtroom-platform-az one.
- **This WAVE (courtroom-platform-az)**: zero 8443 references anywhere in
  scripts/.github/apps/infra. The posh-court 7-stage ladder is
  generate/build/fence/tf-apply — all ARM-plane. Data-plane legs are
  registered non-goals for local v1 (`~/smalt/docs/jira/posh/v26.10.30/gaps/07-secrets-identity.md`
  G2: KV is ARM-plane-only, "the gap is structural, not blocking").

**Answer to "is anything actually blocked today?": NO.** No court, workflow,
or consumer leg in this repo's WAVE needs host→8443.

## Decision: (c) DEFER, with the (a) fix pre-staged and gated

Recommend **option (c)** — defer — but not bare deferral: pre-stage the exact
(a) fix (kind-config diff below) behind a falsifier, so this is a **gated
deferral, not an abandonment** (a blocker branches the search graph, never
terminates work). Rationale by elimination:

- **(a) recreate now** — costs a full cluster re-bootstrap to map a port that
  no current court or consumer reads. Delete/tighten outranks generate: paying
  a bootstrap cost with zero information gain today is generation ranked ahead
  of nothing-to-repair. The only buyer of 8443 is the data-plane leg, a
  registered non-goal for local v1.
- **(b) per-court port-forward with cleanup traps** — actively rejected, not
  merely deferred: the native beam holds `127.0.0.1:8443` at this moment
  (receipt above), so every port-forward attempt on the canonical port fails
  at bind until the native substrate is stopped. Forwarding on a shifted host
  port via port-forward is strictly worse than (a)'s extraPortMappings — same
  host-port choice, but (b) adds a per-court process to leak (the same
  orphan-fd class as the lock-fd finding in [[same-checkout-fanout]] add. 4)
  and no structural receipt. (b) is dominated by (a) whenever the port is
  needed at all.
- **(c)** — zero cost today, and the trigger for revisiting is mechanical, not
  judgment: the moment any court needs host→8443, the discriminator below
  fires FAIL and the pre-staged diff lands with one re-bootstrap.

One refinement to (a) for when it runs: map host **18443**, not 8443. The
native beam's `127.0.0.1:8443` bind exists independently of the kind cluster
and will coexist with it; binding the cluster to host 8443 would force a
shutdown race between the native substrate and the kind lane on every
bootstrap. 18443 avoids the collision entirely, mirroring the existing
host-shifted pattern (9080 for console 30080). Update the smalt-side gap docs
(gaps/11, 17) to name 18443 when this lands — their current text says
`hostPort: 8443`, which collides with the native beam as-written.

## Discriminating court (extends G25's discriminator)

One command pair proves **which plane/port answered**, same shape as G25:

```sh
# G35-1: plane discriminator — ARM must answer on 9443, data-plane must NOT
# answer from the host on 8443 while GAP11 stands.
curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/health  # ARM plane: expect 200
curl -s  -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8443/health || echo "REFUSED-OR-TIMEOUT"
```

Pass condition while deferred: ARM answers (9443 = `2xx`/`3xx`), 8443 from the
host does NOT answer with the backend (connection refused/timeout — a
native beam answering on 8443 is the native substrate, not the kind backend;
the discriminator must name the plane, hence the kubectl cross-check below).

```sh
# G35-2: mapping existence check — the mechanical defer-flip trigger.
docker port smalt-control-plane | grep -q 30843 \
  && echo "G35: MAPPED (deferred state over; option (a) landed)" \
  || echo "G35: UNMAPPED (GAP11 stands, deferral valid)"
```

**Flip law**: when `G35-2` prints `MAPPED` AND a host curl to the mapped port
reaches the smalt-backend egress face (signed-egress court), the deferral is
over — reclassify GAP11/G17 CLOSED. When any WAVE consumer adds a host→8443
dependency (grep above goes nonzero), the deferral is void: apply the
pre-staged diff, recreate, run G35-1 with the data-plane leg expected to
answer through `18443`.

## Pre-staged kind-config diff (applies ONLY when the trigger fires)

`~/smalt/k8s/kind-config.yaml` — add one mapping to the control-plane node's
`extraPortMappings` (host **18443** → containerPort **30843**; do NOT use
hostPort 8443, the native beam holds it):

```diff
 nodes:
   - role: control-plane
     extraPortMappings:
       - containerPort: 30943
         hostPort: 9443
         protocol: TCP
       - containerPort: 30944
         hostPort: 9444
         protocol: TCP
       - containerPort: 30572
         hostPort: 5672
         protocol: TCP
+      - containerPort: 30843
+        hostPort: 18443
+        protocol: TCP
       - containerPort: 30080
         hostPort: 9080
         protocol: TCP
```

Apply path (full re-bootstrap — docker port surgery on a running container is
not possible):

```sh
kind delete cluster --name smalt
kind create cluster --config ~/smalt/k8s/kind-config.yaml
# then the documented bootstrap: just bootstrap (~/smalt/justfile:235)
```

Post-apply receipt: `docker port smalt-control-plane` shows `30843/tcp ->
18443`; `curl -s http://127.0.0.1:18443/health` reaches the backend egress
face. Update `~/smalt/docs/jira/posh/v26.10.30/gaps/11-kind-ops.md` (G11-2 fix
text: 8443→**18443**) and `gaps/17-unmapped-ports.md` (row: `8443 | 30843 |
YES (via host 18443)`) in the same landing.

## See Also

`~/smalt/docs/jira/posh/v26.10.30/gaps/11-kind-ops.md` (G11-2) ·
`~/smalt/docs/jira/posh/v26.10.30/gaps/17-unmapped-ports.md` (GAP11/G17) ·
`gaps/24-cross-repo-skew.md` (kind lane naming, G25 discriminator shape) ·
`~/smalt/docs/jira/posh/v26.10.30/gaps/07-secrets-identity.md` (G2, data-plane
non-goal registration)
