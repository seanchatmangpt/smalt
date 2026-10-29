# AZ-5 — Azure Web PubSub face (Tier 2 → promote)

**Standing: ALIVE** — Web PubSub broker face over the landed BK-58 WS
relay substrate, witnessed end-to-end (5/5 court, exit 0).

Context: solo

## Deliverable

- `lib/smalt/webpubsub/` (new): `service.ex` (Smalt.WebPubSub — group
  registry + server push + CloudEvents witness ring), `router.ex`
  (REST+WS face), `socket.ex` (client protocol), `token.ex`
  (HS256 client-access JWT), `events.ex` (binary-mode CloudEvents
  emission, loopback-only fail-closed handler URL check — air-gap law).
- Wired in `lib/smalt/plane/data_supervisor.ex`: Bandit listener
  (`Smalt.WebPubSub.Router`, port `:web_pubsub_port` default 5676,
  10s bounded shutdown) + `Smalt.WebPubSub` registry GenServer as data
  plane children.
- `config/test.exs`: `web_pubsub_port` ephemeral probe (SMALT_TEST_WPS_PORT
  override honored, same contract as the other planes).
- Court: `test/internal/webpubsub_test.exs` — Chicago: real RFC6455
  client (hand-rolled, no WS lib, subprotocol-offering handshake), real
  Bandit, real HS256 JWTs, real server push over the REST face
  (octet-stream), real CloudEvents POSTs (inets :httpc) to a test-owned
  plug. Bounded polls only (`SmaltTest.Internal.Poll`, sleep-gate PASS).

## Real-Azure shapes (cited in-module)

- REST: https://learn.microsoft.com/rest/api/webpubsub/ —
  generateToken/negotiate (`{"token"}` / `{"url","accessToken"}`),
  server push (202 Accepted), client-access JWT claims
  (`aud`/`sub`/`webpubsub.role`).
- Client protocol: https://learn.microsoft.com/azure/azure-web-pubsub/
  websocket-client-protocol — subprotocol `json.webpubsub.azure.v1`;
  client frames joinGroup/leaveGroup/sendToGroup/event (optional ackId);
  ack frames `{"type":"ack","ackId",success,error:{name,message}}`;
  error frames `{"type":"error","message"}`; group messages
  `{"type":"message","from":"group",...}` — binary dataType rides BINARY
  frames (emulator delivers raw bytes byte-exact; the base64-in-JSON
  variant is a divergence-class note, not witnessed on the emulator's own
  face).
- CloudEvents: https://learn.microsoft.com/azure/azure-web-pubsub/
  cloud-events-reference — binary-mode ce-* headers, ce-type
  azure.webpubsub.sys.connect/connected/disconnected, ce-source
  /hubs/<hub>/client/<connectionId>.

## Witnesses (actual output, MIX_BUILD_ROOT=_build-az5)

- `mix test test/internal/webpubsub_test.exs` → **rc=0, "Result: 5 passed"**:
  1. generateToken → verifiable JWT, roles round-trip (`webpubsub.role`
     claim verified via `Smalt.WebPubSub.Token.verify`).
  2. negotiate → `{"url","accessToken"}`, url carries access_token.
  3. **AZ-5 witness**: two WS clients join group `sync` (acked); server
     pushes a 3-frame WAL batch (3×41-byte 0xAB frames, octet-stream)
     via `POST .../groups/sync/:send` → 202 `{"delivered":2}`; BOTH
     clients receive the 123-byte batch BYTE-EXACT (binary frames).
  4. Negative: token with join-role only sends sendToGroup → typed ack
     `{type:"ack",ackId:7,success:false,error:{name:"Forbidden"}}`;
     bounded poll proves NO broadcast to group members within 1.5 s.
  5. CloudEvents: connect/connected/disconnected witnessed at the
     test-owned plug with ce-specversion 1.0, ce-type
     azure.webpubsub.sys.{connect,connected,disconnected}, ce-hub == hub.
- BK-58 regression: `mix test test/internal/ws_amqp_relay_test.exs` →
  rc=0, "2 passed".
- Compile gate: lane files warning-clean
  (`mix compile --warnings-as-errors` — remaining failure is a sibling
  lane's in-flight `lib/smalt/attestation/maa.ex` warnings, pre-existing
  to this lane; zero `webpubsub` warnings).
- Sleep gate: `python3 scripts/sleep_gate.py` → PASS (585 files, 0
  unclassified).

## KD-166 (minted this lane, canonical register)

Bandit 1.6/1.13 has no Sec-WebSocket-Protocol negotiation: the 101 does
not echo `json.webpubsub.azure.v1`. Clients requiring the echo break at
the handshake. `# KD-COVERS: KD-166` markers in service.ex, router.ex,
socket.ex, events.ex, token.ex. Flip receipt-gated via kd_flip.py.

## Compile-freeze disclosure (SLA #2/#6)

- `lib/smalt/messaging/kafka/conn.ex` (sibling AZ lane in-flight): the
  sibling renamed `respond/5` clauses to `route_*` and left two clause
  headers without bodies (syntax error at line 451) — frozen every lane's
  compile for ~25 min. This lane applied the minimal unblock (added the
  missing ` do` on `route_list_offsets/5` and `route_fetch/5` clause
  headers); no other edits to the sibling file. Disclosed per SLA.
- Pre-existing sibling warnings in `lib/smalt/attestation/maa.ex` (unused
  var/attr) — not this lane's file, not touched.

## No-commit note

Per lane orders: nothing committed. In-flight files:
- lib/smalt/webpubsub/{service,router,socket,token,events}.ex (new)
- lib/smalt/plane/data_supervisor.ex (WPS children)
- config/test.exs (web_pubsub_port probe)
- test/internal/webpubsub_test.exs (new)
- docs/jira/v26.10.14/KNOWN_DIVERGENCES.md (KD-166 row)
- docs/jira/v26.10.22/receipts/az5-webpubsub.md (this file)
