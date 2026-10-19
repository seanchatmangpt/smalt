# V261019-02 — SOVEREIGN_MIDNIGHT G-register: G2 X-ARR mTLS, G3 EG DLQ spillover, G4 split-brain failover

- **Release:** v26.10.19
- **Lane:** sovereign-g2g3g4
- **Base:** HEAD `4fd2ff2ba80e618341dc85de3ef84fcb8702bff3`
- **Status:** ready-for-work (G2/G3); G4 scheduled behind G2/G3

## Objective

Close the three MISSING rows of the Sovereign Midnight gap register
(`docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md`, §"Gap register
(build order for v26.10.19)"), each receipt-gated. All 18 existing test bodies
run untagged and green on HEAD (18/0 —
`docs/jira/v26.10.18/receipts/i29-midnight-map-refresh.md`); the register is
hand-maintained prose — flips cite receipts, no GAP tokens minted unilaterally.

- **G2 MISSING** — X-ARR-ClientCert mTLS gateway termination + spoof injector.
  `grep -ri "X-ARR-ClientCert" lib/` → 0 hits today; the token-bucket 429 arm
  exists (`lib/smalt/arm_gateway/router.ex:54,132-187`).
- **G3 MISSING** — Event Grid DLQ blob spillover. Extends the azb-07 engine
  (`lib/smalt/messaging/event_grid.ex`: no DLQ/blob path today); at-least-once
  delivery exists, dead-letter does not.
- **G4 MISSING** — Split-brain regional failover plane. New architecture
  (grep: 0 hits); largest item, deliberately sequenced behind G2/G3.

G5 is narrowed to injectors-only and G6 is CLOSED
(`docs/jira/v26.10.18/receipts/i29-azb20-lib-land.md`; ResourceGraph route
family at `lib/smalt/egress_router.ex:1515`) — both out of scope here.

## Files owned (this lane)

| File | Scope |
|---|---|
| `lib/smalt/arm_gateway/router.ex` (G2 only) | X-ARR-ClientCert termination plug on the ARM surface |
| `lib/smalt/messaging/event_grid.ex` + DLQ face (G3) | dead-letter blob spillover path, typed dead-letter face |
| `test/azsim/sovereign_midnight/sovereign_midnight_test.exs` | G2 spoof-injector test; G3 delivery-failure→DLQ wire test |
| new `lib/smalt/...` failover plane module(s) (G4) | split-brain failover architecture |
| `docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md` | register row flips MISSING→COVERED, each citing a receipt |
| `docs/jira/v26.10.19/receipts/` | G2/G3/G4 witness receipts |

**NOT owned by this lane:** `docker/Dockerfile` + build lease (lane 01);
`lib/smalt/plane/control_supervisor.ex`, ARM ResourceGraph route, crash-path
header plug (lane 03); `arm_throttle` 429 semantics beyond what the G2 plug
composes with.

## Tasks

### Task 1 — G2: X-ARR-ClientCert mTLS termination
APIM-style gateway termination on the ARM surface: extract/verify
`X-ARR-ClientCert` on the protected ARM routes, refuse (401/403 per ARM shape)
when absent/invalid. Compose with the existing `arm_request_id`/`arm_throttle`
plug chain (`router.ex:53-54`). Include the spoof injector: a test presenting
a forged/spoofed cert must be refused. Grep gate: `grep -ri "X-ARR-ClientCert"
lib/` > 0 hits.

### Task 2 — G3: Event Grid DLQ blob spillover
Extend `lib/smalt/messaging/event_grid.ex` with a delivery-failure path that
spills the dead event to a blob-backed DLQ (reuse the blob storage engine, no
new StoreTable unless required), with a typed dead-letter face (structured
reason: delivery attempts exhausted / TTL). Wire test: force delivery failure
→ assert DLQ blob write + typed face.

### Task 3 — G4: split-brain regional failover plane
New architecture (design note required in the receipt before code): two
regions, lease/heartbeat-based primacy, split-brain detection and failover
witness. Schedule strictly behind G2/G3; the row flips only with a real
failover witness receipt (kill primacy → secondary promotes; partition →
exactly one active).

### Task 4 — register flips
Flip G2/G3 (and G4 when witnessed) in
`docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md`, each citing its
receipt. No GAP tokens minted from this register unilaterally.

## Acceptance criteria

```bash
grep -ri "X-ARR-ClientCert" lib/                      # > 0 hits (G2)
mix test test/azsim/sovereign_midnight/sovereign_midnight_test.exs
# G2 spoof-injector test present and refusing; G3 DLQ wire test present; 18+N tests, 0 failures
grep -n "dlq\|dead_letter\|dead-letter" lib/smalt/messaging/event_grid.ex   # > 0 hits (G3)
mix test test/data_plane/ test/arm/ test/wire/ test/azsim/   # regression green
```

## Falsifiers

- G2: a request carrying a self-signed/spoofed `X-ARR-ClientCert` must be
  refused — `curl -k --cert forge.pem ... https://.../subscriptions/...`
  returns 401/403, never 200. On the pre-fix tree any cert (or none) passes.
- G3: kill/deny the Event Grid subscriber past the retry budget — the event
  must appear as a DLQ blob with a typed reason; on the pre-fix tree it is
  dropped after retries with no DLQ artifact.
- G4: `kill -9` the primary region node mid-cycle — the secondary must promote
  exactly once; a network partition must never yield two simultaneous
  primaries. A flip without a witnessed failover run is invalid.
