# 17-unmapped-ports

Lane 17 gap census, 2026-10-30. Cluster `kind-smalt` live at probe time; pod
`smalt-backend-0` container `smalt` running, sidecar `posh-membrane` in
CrashLoopBackOff (fresh pod, ~1 min old at probe time).

## Status

PARTIAL — cluster face is 4 of 13 ports; the host face is masked by a
native host substrate binding the same loopback ports.

## Port matrix

Legend: Service = in a k8s Service; NodePort = numeric nodePort allocated;
Host = kind `extraPortMappings` (colima ssh-mux forward, loopback only).

| Port | Face | Service | NodePort | Host mapping | Consumer from host |
|---|---|---|---|---|
| 9443 | ARM mgmt (HTTP) | smalt-backend, smalt-backend-nodeport | 30943 | yes (9443) | docs/scripts bootstrap; host curl → 401 MissingBearerToken |
| 9444 | ARM TLS twin | smalt-backend, smalt-backend-nodeport | 30944 | yes (9444) | host curl → 401 (TLS) |
| 8443 | data egress | smalt-backend, smalt-backend-nodeport | 30843 | NO (GAP11) | none from host to cluster |
| 8445 | egress TLS (opt) | no | no | no | none; optional Bandit, `egress_tls_port` (data_supervisor.ex:77) |
| 5672 | AMQP / Service Bus | smalt-backend, smalt-backend-nodeport | 30572 | yes (5672) | emulator-parity consumers (MIGRATION_FROM_EMULATORS.md) |
| 5673 | EventHubs | headless only | no | no | in-test only: `dev_shared_key_derivation_test.exs:74` uses 127.0.0.1:5673 — resolved against the native host beam, not the cluster |
| 5675 | WS AMQP relay | no | no | no | none from host; in-pod/native listener (data_supervisor.ex:98) |
| 5676 | Web PubSub | no | no | no | none from host; in-pod/native listener (data_supervisor.ex:102) |
| 9092 | Kafka wire | no | no | no | docs/TESTBED.md documents it as part of smalt's face; listener is native-host only from the laptop |
| 8444 | ConfLedger | no | no | no | none from host (`confidential_ledger/supervisor.ex:28`) |
| 9445 | SAML IdP TLS edge | r30-10-identity ClusterIP | no | no | none; r30 identity pod NOT running at probe time |
| 9446 | OIDC HTTPS | r30-10-identity ClusterIP | no | no | `scripts/p08_kind_gate.sh:46` asserts `localhost:9446` — this resolves to the NATIVE host beam, not the cluster; gate is vacuous against kind |
| 9545 | MCP router | no | no | no | docs/TESTBED.md; native-host listener only |
| 4369 | epmd | headless only | no | no | in-cluster dist only (correct design) |
| 9000-9009 | Erlang dist | headless only | no | no | in-cluster dist only (correct design) |

## Silent-service findings

1. **GAP11 confirmed**: nodePort 30843 exists for 8443 but has no
   `extraPortMappings` entry. TFPOSH data-plane legs that assume
   `localhost:8443` reach the cluster do not — the cluster leg is
   host-unreachable without `kubectl port-forward`.
2. **Loopback collision masks the whole matrix**: a native host smalt
   (beam.smp pid 98191, cwd `/Users/sac/smalt`) binds 127.0.0.1 on 9443,
   9444, 5672, 5673, 8443, 8444, 9092, 9545, 9445, 9446, 5675, 5676 —
   every port in the table. Colima's ssh mux binds `*:9443/9444/5672/9080`
   for the kind mappings. On macOS the more-specific loopback bind is the
   one a `127.0.0.1` client resolves to, so **host traffic on the four
   "mapped" ports most likely lands on the native host smalt, not the
   kind pod**. Both return identical `401 MissingBearerToken` bodies, so a
   plain curl cannot tell them apart. Discriminating experiment (not run —
   would disturb the native substrate): stop the native beam, re-curl
   9443, compare payload. LAN-IP probe (`192.168.12.205:9443`) failed to
   connect, so the colima mappings are loopback-only in practice.
3. **p08_kind_gate is vacuous against the cluster**: it checks
   `localhost:9446` and `localhost:3000`; 9446 is ClusterIP-only in k8s
   (r30-10-identity.yaml:192/210) and the r30 identity pod was not
   running. A pass means the native host substrate answered, not the
   cluster.
4. **Courtroom SAML/OIDC e2e has no host path**: SAML flows target
   `idp.smalt.svc.cluster.local:9445` / `29445` pod-internal names;
   in-cluster only. From the host, `https://127.0.0.1:9445` currently
   answers from the native beam (if the identity faces are up natively) —
   a courtroom e2e "pass" from the laptop proves the native substrate,
   never the kind deployment.
5. Console (9080→30080) mapping exists, but console pod was not running at
   probe time (curl 000). Mapping is fine; workload absent.
6. Ports 5675/5676/9092/8444/8445/9545 listen in-pod but are not declared
   as containerPorts, so even in-cluster pod-IP reachability is
   best-effort (containerPort is documentation-only, but its absence means
   no Service was ever written for them either).

## Close conditions

- GAP11: add `containerPort: 30843 -> hostPort 8443` to
  `k8s/kind-config.yaml`.

> UPDATE 2026-10-30 per gaps/35-egress-mapping-decision.md: GAP11 is DEFERRED
> behind a mechanical trigger. The staged fix maps host **18443** →
> containerPort **30843**, NOT hostPort 8443 — the native beam binds
> `127.0.0.1:8443` at present, so the hostPort 8443 close text above collides
> with the native substrate as-written. Defer stands while no host consumer
> needs 8443; flip trigger: `docker port smalt-control-plane | grep -q 30843`
> (courtroom-platform-az/scripts/egress_plane_discriminator.sh).

  Cost: **kind cluster recreate required** —
  extraPortMappings are immutable per cluster; the 2-replica StatefulSet,
  r30 identity stack, console, TLS secret and any in-cluster state must be
  re-bootstrapped. Alternative with zero recreate:
  `kubectl port-forward -n default svc/smalt-backend 8443:8443` (collides
  with the native beam's 127.0.0.1:8443 bind — must stop the native
  substrate first, see finding 2).
- 9445/9446: either a host-mapped NodePort Service for r30-10-identity
  (same recreate cost) or a documented port-forward recipe in
  `k8s/README.md`; until then p08_kind_gate must assert against
  pod-exec or port-forward URLs, not localhost.
- Loopback collision: the native host smalt and the kind cluster must not
  share the loopback port namespace. Pick one: bind the native substrate
  to alternate ports, or gate host-side tests on `smalt.doctor` output
  that identifies which face (native vs cluster) owns each port.
- 5675/5676/9092/8444/9545: decide whether they are cluster faces at all.
  If laptop-side consumers exist (TESTBED.md claims 9545/9092), either
  expose via NodePort or register them as native-substrate-only faces in
  docs so no test assumes cluster reachability.

## See Also

- `k8s/kind-config.yaml` (extraPortMappings)
- `k8s/smalt-backend.yaml:95-105` (nodePort Service)
- `k8s/r30-10-identity.yaml` (9445/9446 ClusterIP Services)
- `scripts/p08_kind_gate.sh:46`
- `lib/smalt/plane/data_supervisor.ex` (5675/5676/8445/9092 defaults)
