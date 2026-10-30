# R4 Baseline Triage Receipt

Standing: PARTIAL_ALIVE — 249/249 failures extracted and classified from real logs;
classification evidence is quoted per cluster; no fix work executed.
Root cause is dominated by one systemic regression (see D1).

## Method

- Inputs: `/tmp/smalt-validate/test-offline.log` (1274/1417 passed, 143 failed,
  8 skipped, 12 excluded; exit 2) and `/tmp/smalt-validate/integration.log`
  (106 failed / 671 tests).
- All 249 failure headers extracted with
  `grep -E "^ *[0-9]+\) test"` (143 + 106, exact match to the run totals).
- Every failure's first error line was read; clusters below quote the log
  verbatim. No `mix test` was run; no git state changed; no lib/test files
  edited.

## Per-class counts

| class | offline | integration | total |
|---|---|---|---|
| (a) flake/environment | 6 | 3 | 9 |
| (b) dirty-tree | 2 | 0 | 2 |
| (c) known-documented | 4 | 3 | 7 |
| (d) real defect | 131 | 100 | 231 |

Classification unit = failure (test × log), module-clustered.

## Class (a) flake/environment — 9

| count | module | evidence |
|---|---|---|
| 2 | Smalt.Test.Internal.TraceSessionCourtTest | offline:553 — trace race (quote A) |
| 2 | Smalt.EventGridWebhookTest | offline:9169 — singleton already-started race (quote B) |
| 3 | Smalt.GraphlawEx.GateCourtTest (37-39) | offline:4380 — wasm host artifact absent (quote C) |
| 1 | InternalTier.Kd115CreditFirstDel. | offline:10121 — npm `rhea` missing (quote D) |
| 1 | Ath3LawCourtTest | offline:3121 — graphlaw wasm build artifact missing (quote E) |

Quote A: `assert :trace.function(session, mfa, [], [:local]) >= 1` /
`left: 0 / right: 1` — trace never fired; host load 25.5/16.

Quote B: `failed to start child with the spec Smalt.Messaging.EventGrid.`
`Reason: bad child specification, got: {:already_started, #PID<0.20609.0>}` —
global singleton vs async sibling; port/state race.

Quote C: `code: :call_exited, message: "no host is registered as GraphlawEx"`
plus the loud skip `[SKIP] GL28-2 gate courts: no wasm artifact at`
`/Users/sac/smalt/test/priv/graphlaw/graphlaw.wasm (set PRIV_WASM ...)` —
environment (artifact absent), not code.

Quote D: `Error: Cannot find module 'rhea'` under
`/Users/sac/smalt/verification/ts` — npm dependency not installed.

Quote E: `** (File.Error) could not read file` 
`"/Users/sac/graphlaw/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm":`
`no such file or directory`.

## Class (b) dirty-tree — 2

| count | test | evidence |
|---|---|---|
| 1 | GateCourtTest "16 MiB + 1 body refuses :smalt_oversize" | offline:4349 — quote F below |
| 1 | Internal.Expl11r3.PlanesMetaCourt F4 | offline:8678 — quote G below |

Quote F: at test/graphlaw_ex_gate_court_test.exs:211,
`right: {:refused, :smalt_no_receipt, %{missing_keys: [:engine_digest]}}` —
the in-flight `lib/smalt/graphlaw_ex/admission_gate.ex` edit now demands
`:engine_digest`; the committed test has not caught up.

Quote G: `expected exit 3 (typed refusal), got 0:` — real-subprocess boot
refusal court ran against the dirty tree; boot outcome diverged from the
pinned refusal. Lower confidence: load could also explain it; re-run on a
quiet tree.

## Class (c) known-documented — 7

| count | module | evidence |
|---|---|---|
| 7 | Smalt.Internal.AppconfigEventsTest | offline:5499 — quote H below |

Quote H: `Assertion failed, no matching message after 0ms` on events that
DID arrive carrying an etag (mailbox shows the Modified/Deleted event with
etag "3364...") — etag-CAS event shape; README names the
`appconfig-etag-cas` gate (DEF-2) as an open typed defect. One of the four
also crashes `Plug.Conn.WrapperError ... FunctionClauseError` at
test/integration/appconfig_events_test.exs:74 on key|label; if a quiet-tree
re-run still crashes, escalate that one to (d).

README's other documented family ("shifting-failure flake family in the
semantic projection suite") produced ZERO failures in either log — no semantic
projection module appears in the 249.

## Class (d) real defects — 231

Deterministic: the same tests fail identically in both runs (e.g. all 12+12
ServiceBus failures at the same file:line in both logs), so none of these are
load artifacts. Dominant root cause D1 below covers the majority.

### D1 — EgressRouter "v26.10.29 undock" regression (~100+ of the 231)

`lib/smalt` EgressRouter source (quoted in a failing assert, offline:8678
block) says: "The undock's queue/blob rule-CORS variants ... are NOT restored
here — next-wave scope." Consequences visible in the logs:

- Plug.ErrorHandler fence gone:
  `assert src =~ "use Plug.ErrorHandler"` — left side has none
  (test/internal/expl9r1_egress_guard_court_test.exs:107).
- `Smalt.EgressRouter.safe_dispatch/2 is undefined or private`
  (test/internal/bk101_g3_seam_probe_test.exs:14).
- `function Smalt.EgressRouter.Peers.build_event/2 is undefined`
  (test/internal/armstrong_idiom_court_test.xs:174).
- Route families return RouteNotFound:
  "No route matches POST /saas/subscriptions/resolve"
  (marketplace_saas_test.exs:241); "No route matches PUT /expl9r1acct"
  (service-properties, expl9r1 :131); "POST /sync/journal/batch ... Sent 404"
  (ath1_batch_frame_receiver_court_test.exs:230); KV crypto face:
  "Jason.DecodeError ... 0x3C (\"<\")" on GET /keys (kv_crypto_face_test.exs:12),
  KvEcCreateTest 5+5, KdS3S4 2+0, Bk19Kd10KvPutRoute 1+1.
- /sbns REST face: 404/400 vs expected 401/200 — ServiceBusRestDataplaneTest
  12+12 failures, e.g. "code: assert conn.status == 401 / left: 404"
  (servicebus_rest_dataplane_test.exs:101).

D1 module roll-up (offline+integration counts): ServiceBusRestDataplane 24,
MarketplaceSaas 20, EventGridPushCourt 10, Ath1BatchFrameReceiver 6,
KvCryptoFace 4, KvEcCreate 10, KdS3S4 2, Bk19Kd10KvPutRoute 2, Expl9r1 5,
Bk101G3SeamProbe 1, ArmstrongIdiom 1, Bk132 (cors/service-props legs) 4,
BKEGS1.FenceCourt 1, QueueMessageCt 1, plus parts of BlobParity/BlobXmlError/
BlobKdFixes/KD130/BlobQuotaHeaders/KdBlobCourt/TlsBlobDispatch/
DeletedkeysPurgeRoute/LedgerAppendEnvelope/EhThrottleWiring/MCPT1Dispatch/
KafkaWire/IacExport — these smaller modules share the 404/typed-envelope
signature but were not individually deep-read; verify membership before
filing per-module work orders.

### D2 — tenant fence not enforced (security-class)

- "t2 GET foreign blob expected 403: 200 \"hello-g5\""
  (tenant_fence_blob_kv_queue_test.exs:185) and "t2 version-addressed GET
  expected 403: 200" (:30) — cross-tenant reads return 200.
- "t1 versions list: 501 NotImplemented" (:106) — fence-plane KV versions
  face unimplemented.
- TenantFenceRegistry "Refute with =~ failed" (tenant_fence_registry_test.exs
  :27, :96, both logs) — registry leak.

### D3 — APIM gateway answers blanket 400 on /apim-gw

All 6+6 ApimWireTest failures: "code: assert conn.status == 200 / left: 400"
including the default-off case expecting 404 (apim_wire_test.exs:76) and the
typed 401/429 falsifiers (:116, :95). The gateway plug rejects before any
policy runs.

### D4 — other real defects (name file:line)

- ThrottleCourt 5+5: "assert conn.status == 429 / left: 400" and
  "left: 404" (throttle_court_test.exs:91, :182) — throttle planes return
  early 400/404 before exhaustion can be simulated; EhThrottleWiringTest
  1+0 agrees.
- CosmosChangeFeed 4+4: change feed on a fresh collection "expected 200
  empty envelope ... right: {404, NotFound}" (cosmos_change_feed_test.exs:102).
- SignInsLog 3+3: "MissingXMsVersion ... Missing required x-ms-version
  header, SAS token, or allowlisted host" (signins_log_test.exs:125) — the
  Entra face's version gate rejects the documented client shape.
- Expl11r3 PlanesMetaCourt F4 (offline-only, counted (b)): if a quiet-tree
  re-run still shows "expected exit 3 ... got 0", reclassify (d) at
  test/internal/expl11r3_court_test.exs:86.
- AcceptanceProbe 2+2: "tamper probe must actually mutate the payload" —
  probe vacuity (acceptance_probe_test.exs:89) plus a 400-vs-expected at :45.
- IacExport 3+0: "FunctionClauseError ... String.contains?/2" — nil subject
  passed to String.contains? (iac_export_test.exs:79/116/152).
- KdConformance 4+4 + KdConfCourt 4+0: "future api-version must be refused"
  (kd_conformance_test.exs:92), "id must be vault-host shape, got:
  https://www.example.com:8443/secrets/..." (:72), "first create must be 201
  per KV secrets 7.4" (:51), "_gen must never cross the wire" (:144) — KD
  parity gates (KD-147..151) failing against the wire; not in any open-KD
  register row, so class (d) parity regressions, not (c).
- Bk132CorpusTriage 4+4: "comp value 'tier' is not supported" (:41),
  RouteNotFound on service-properties (:86), sync-copy 201-vs-404 (:82),
  "container create failed: 200" (:54) — blob parity gaps.
- KdBlobCourt 4+0: "Put Blob 201 must be empty-body" (kd_blob_court_test.exs:237),
  "want 400, got 201" (:160) — blob 201 body/etag wire shape.
- EventGridPushCourt 10 (in D1 roll-up but distinct shape): MatchError on the
  push delivery contract + one Jason "<" at :271 — verify whether the push
  face is a D1 route casualty or an envelope-shape defect on its own.
- MarketplacePersistence 1+1: MatchError (marketplace_persistence_test.exs:65).
- KafkaWire 2+0: MatchError (kafka_wire_test.exs:52, :112).
- AmqpWebsocketBridge 1+2: "function SmaltTest.WsClient.connect/2 is
  undefined" (amqp_websocket_bridge_test.exs:51, :84) — stale test helper API.
- TlsBlobDispatch 1+1, DeletedkeysPurgeRoute 1+0, QueueMessageCt 1+1,
  BKEGS1 "Refute with == failed, both sides are exactly equal"
  (bkegs1_fence_court_test.exs:698), BlobQuotaHeaders 1+1,
  BlobXmlError 4+4, BlobParity 4+4, KD130ContainerExists 4+4,
  BlobK1RowsWitness 2+2, Kd62UdkWitness 2+2, BlobKdFixes 6+6,
  LedgerAppendEnvelope 2+2, MCPT1Dispatch 2+0,
  SmaltTest.Integration.IacExportTest counted above.

## Recommended next-window work orders

- WO-1 (D1, highest yield): restore the EgressRouter undock losses —
  safe_dispatch/2, Plug.ErrorHandler fence, Peers.build_event/2, and the
  /saas, /sbns REST, KV crypto face, /sync/journal/batch and
  service-properties route families. One lane, ~100+ failures.
- WO-2 (D2): re-arm the tenant fence (403 on cross-tenant blob/KV/queue +
  registry refute) — security class; do not batch with WO-1.
- WO-3 (D3): APIM /apim-gw blanket 400 — trace the gateway plug's
  pre-policy rejection.
- WO-4 (a-class env): install `rhea` in verification/ts and set PRIV_WASM /
  build graphlaw wasm so GateCourt/Ath3/Kd115 stop failing env-class.
- WO-5: quiet-tree re-run of the 9 (a)/(b) tests to confirm class flips
  (GateCourt engine_digest, PlanesMeta F4, TraceSession, EventGridWebhook).

## Falsifier

A quiet-tree re-run on a clean tree (no in-flight edits, load < 16) that
returns the same 249 minus at most the 9 (a) + 2 (b) confirms the (d) set is
deterministic; any (d) module that goes green on a quiet clean tree was
mis-classified and moves to (a) with a receipt update.