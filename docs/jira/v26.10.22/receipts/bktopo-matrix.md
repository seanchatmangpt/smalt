# Receipt: BK-TOPO — deployment topology matrix (docs lane)

- **Date**: 2026-10-22
- **Lane**: BK-TOPO (docs/design)
- **Standing**: PARTIAL_ALIVE (design landed; cells typed, none yet executed)
- **Context**: solo
- **Deliverable**: `docs/jira/v26.10.22/TOPOLOGY-MATRIX.md` (new)

## What landed

The frontend x backend matrix over runners (laptop / act) and scale (1 /
swarm), every cell typed SUPPORTED-NOW / SUPPORTED-WITH-THIS-WORK /
UNSUPPORTED, with per-cell wiring contracts (env vars, service DNS names,
cert paths), falsifiers F1–F10, work items WI-0–WI-9 with owner lanes
(BK-IMG, BK-K8SM, BK-JUSTK, BK-SWARM, BK-ACT, BK-TOPOV), hazard register
H1–H4, and an explicit boundary section (no PVC/state persistence, no
multi-namespace, no Windows runners this wave).

## Ground truth read (exact files, this checkout)

- `lib/smalt/config.ex` — env surface: SMALT_BIND_IP, SMALT_PLANES
  (refuses `{:invalid_plane, name}` via lib/smalt/planes.ex), SMALT_PROFILE,
  SMALT_ARM_RATE_LIMIT, SMALT_COSMOS_RU_LIMIT, SMALT_TLS_CERTFILE/KEYFILE,
  SMALT_SB_SHARED_KEY; amqp_port default 5672; sb_endpoint default
  `sb://127.0.0.1:5672`.
- `workspace/lib/smalt.ts` — `assertLocalUrl` loopback-only allowlist
  (127.0.0.1/localhost/[::1]/::1), `NEXT_PUBLIC_SMALT_ARM` /
  `NEXT_PUBLIC_SMALT_EGRESS` defaulting to http://127.0.0.1:9443/8443;
  `smaltFetch` redirect:"error".
- `workspace/lib/caller-gate.ts` — `sync_state_non_loopback` host/origin
  gate; `SMALT_BFF_SYNC_SECRET` posture.
- `lib/smalt/cluster.ex` — `config :smalt, :cluster` (enabled/dns_name/
  port/poll_ms/node_prefix "smalt"/max_retries), remote node name
  `smalt@<ip>`, DNS-poll join with bounded retries, `cluster_status/0`;
  default OFF, boot byte-identical when disabled.
- `test/integration/peer_two_node_court_test.exs` — two-node
  `:peer`/`:erpc` court; loud skip without a distributed runner node
  (`elixir --name ... --cookie ...`); hazard H3 sourced here.
- `scripts/gen_dev_cert.sh` — `.smalt/tls/ca-cert.pem` CA:TRUE root,
  leaf CN=localhost; SSL_CERT_FILE trust anchor. Leaf has no service-DNS
  SANs → WI-2.
- `workspace/next.config.mjs` — no `output: "standalone"` today → WI-3.
- `docs/jira/v26.10.22/receipts/bkb4rc-send-gate-court.md` — KD-86
  send-gate (`QueueStore.enqueue` / `ensure_entity/1`) closed; reused as
  the swarm write-path mitigation pattern (WI-4).

## Verification performed (this lane, docs-only)

- Read-only ground-truth pass over the files above; matrix identifiers are
  quoted from them, not invented.
- No test or substrate runs (docs lane; falsifiers F1–F10 are owned by
  BK-TOPOV per WI-9, none executed here — stated, not claimed).

## Out of scope (typed)

PVC-backed state, multi-namespace, Ingress TLS termination with external
CAs, Windows/WSL runners — all recorded in the matrix Boundary section.
