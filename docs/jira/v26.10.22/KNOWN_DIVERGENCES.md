# Known Divergences — v26.10.22 (pointer)

Canonical KD register: [`../v26.10.14/KNOWN_DIVERGENCES.md`](../v26.10.14/KNOWN_DIVERGENCES.md)
(the table is ground truth). Mint from KD-182 (highest minted id is
KD-181 — lane KD-FV0 2026-10-22 minted the Kafka Fetch-v0 legacy-face
magic-2 verbatim-serve divergence row, canonical table). This doc REGISTERS; it
does not close. Flips only via
`scripts/kd_flip.py --apply`, gated on a PASS witness receipt postdating the
shim mtime.

## Rows minted this window

- W32-10 — SB namespace PUT answers 202 Accepted — CLOSED-NOT-A-DIVERGENCE
  (lane BK-W3210, 2026-10-22; registrar disposition row, NO KD id minted —
  the candidate never earned a row because the premise was wrong, not the
  wire). Candidate lineage: w32-api-conformance.md typed "PUT → 202 vs real
  Azure 200/201" as a NEW-candidate divergence; BK-REWIT3 wave 3 carried it
  as the last open W32 candidate. Fresh real-wire probe (bearer over
  loopback 9443, api-version 2021-04-01, sku body): PUT answered 202 with
  the FULL real-Azure LRO face — `Azure-AsyncOperation` +
  `Location` (operation URL) + `Retry-After: 1` headers, body an
  AsyncOperationStatus resource (`status: InProgress`, `resourceId`,
  `startTime`); GET operation → terminal record with `endTime` and the
  provisioned namespace payload; idempotent retry PUT → 200 (KD-124 second
  face, unchanged). This IS the real-Azure semantics: Microsoft.ServiceBus
  namespaces create/update is a long-running operation answering 202
  Accepted with Azure-AsyncOperation/Location/Retry-After
  (learn.microsoft.com REST reference, Namespaces Create Or Update). The
  202-vs-200/201 typing compared against a naive read of the sync face;
  real Azure is async here. Close condition: n/a — nothing to close; the
  w32 receipt's `sb-ns-put2` capture ask is satisfied by
  `receipts/bkw3210-ns202.md` (embedded probe transcript). Status:
  CLOSED-NOT-A-DIVERGENCE — no `lib/` change owed, no shim, no flip.
- KD-181 — Kafka Fetch-v0/v1 legacy face serves stored magic-2 batches
  verbatim, no down-conversion (KD-FV0, 2026-10-22; `lib/smalt/messaging/kafka/conn.ex`
  fetch response path; registration-only row, `# KD-COVERS: KD-181` for a
  fetch-face down-conversion shim): Fetch v0/v1 responses carry message-set
  v0/1 — real Kafka down-converts magic-2 RecordBatches to legacy frames on
  low-version fetches; smalt serves the stored magic-2 bytes verbatim. Fresh
  witness (lane KD-FV0 probe, self-booted test-tier app, ephemeral port):
  kafka-python-ng api_version=(0,9) → Fetch v0 over a partition holding 3
  real-client legacy produces + 1 raw magic-2 batch (in-matrix Produce v0,
  err=0) delivered the magic-2 bytes as a GARBAGE legacy record — value =
  raw batch bytes, timestamp None, offset 0. bkkfkc's struct.error witness
  is an order/content-dependent client arm of the same verbatim-serve
  (typed residue). KD-174's truth cell does NOT cover this: KD-174 is the
  PRODUCE face (magic-2 payload accepted in-matrix, close = client
  negotiating magic-2 produce); KD-181 is the FETCH face. Typed posture:
  CLOSED-SIMULATED (lane BK-DOWNCV, 2026-10-22: fetch-face down-conversion
  landed in `lib/smalt/messaging/kafka/conn.ex` — `serve_batch/3`
  version-dispatched, `# KD-COVERS: KD-181`; close condition executed:
  real kafka-python-ng api_version=(0,9) client fetches a magic-2-stored
  partition byte-exact, values intact, ts None — court 23/23 across
  downcv+exp4+wire, standalone witness exit 0. Flip receipt-gated via
  `scripts/kd_flip.py --apply --only KD-181`). Disposition: closed by
  BK-DOWNCV; next action = none. Close condition: met (see canonical row).
  Status: CLOSED-SIMULATED (flip applied). Evidence: receipt
  `receipts/kdfv0-row.md` + `receipts/bkkfkc-legacy-count.md` (typed
  residue) + `receipts/bkdowncv-fetch-v0.md` (close witness).

- KD-179 — sas_verifier `loopback_host?` accepts inet_aton shorthand loopback
  literals (BK-ATON, 2026-10-22; `lib/smalt/messaging/amqp/sas_verifier.ex`
  `loopback_ipv4?/1` via `:inet.parse_address/1`): the AMQP SAS audience check
  accepts `0177.0.0.1`, `0x7f.0.0.1`, `127.1`, `2130706433` (each witnessed
  `{ok,{127,0,0,1}}`), forms real Azure's dotted-quad URI-authority parsing
  would 401. **Typed posture: accepted-because-genuinely-loopback** — every
  accepted shorthand parses to `{127,0,0,1}` itself and an address literal
  never consults DNS, so no accepted shape can name a foreign host; the
  KD-173 host-scoping law's intent holds. Also: `[::ffff:127.0.0.1]` refuses
  fail-closed (safe-direction false negative). KD-COVERS shim: none —
  registration row, `lib/` unchanged. Disposition: owner = none owed now;
  next action = only if a divergence is ever witnessed downstream (shorthand
  resolving non-loopback, or a real-SDK leg 401ing where smalt accepts), land
  a strict dotted-quad shape guard with a witness receipt, then flip via
  `scripts/kd_flip.py --apply`. Close condition: strict dotted-quad-only
  shape guard (4 dot-separated decimal octets, no `0x`/short/integer forms)
  landed with a witness receipt on that downstream divergence, or the row is
  re-registered under a stronger typed posture. Status: OPEN — TYPED
  ACCEPTED-BECAUSE-GENUINELY-LOOPBACK DISPOSITION (PINION-WITNESSED,
  registration-only; no repair owed). Evidence: receipt
  `receipts/bkampv-parse-verify.md` (BK-AMPV ALIVE, Context: solo) +
  `receipts/bkampf1-loopback-parse.md` (BK-AMPF1 repair provenance).

- KD-180 — Kafka legacy-face recordsCount divergence — garbage watermark
  advance from one legacy produce (BK-KFKSKEP audit → BK-KFKC repair →
  BK-KFKV verify, 2026-10-22; `lib/smalt/messaging/kafka/records.ex`
  `count/1` clause ordering + legacy F3 cross-check in `parse_records/1`;
  shim = the BK-KFKC magic-first dispatch, `# KD-COVERS: KD-180` added by
  lane KD-KLV): `admit_one` called `Records.count(raw)` BEFORE dispatching
  on magic, so the magic-2 recordsCount clause (bytes 57..60) won for ANY
  binary >= 61B — a legacy magic-0/1 frame >= 61B (value >= 47B) got count
  = payload bytes: a single 60-byte real-client produce jumped hwm
  0 → 0x42424242, and journal replay restored the corrupted counts (legacy
  parse still returned 1 record, so F3 never fired; delivery byte-exact).
  Real Kafka: exactly one record per legacy message-set frame.
  KD-COVERS shim: `lib/smalt/messaging/kafka/records.ex`
  `# KD-COVERS: KD-180` (BK-KFKC magic-first `count/1` dispatch + legacy
  F3 cross-check). Disposition: owner = BK-KFKC (landed); next action =
  none — row minted-then-closed per the KD-175/KD-176 precedent (witness
  receipts postdate the fix). Close condition: legacy frame >= 61B advances
  hwm by exactly 1; a planted lying count never advances it — met
  (BK-KFKV: mixed-size series replayed 3/3/254B byte-exact across
  seal→kill→restart; count=5 lie over 2 frames → hwm delta exactly 2;
  magic-2 header count=5 vs 2 records → typed err=2, hwm unchanged; suites
  18 passed). Status: CLOSED-WITH-EVIDENCE (registrar close-typing, lane
  KD-KLV 2026-10-22). Evidence: `receipts/bkkfkskep-kafka-audit.md` +
  `receipts/bkkfkv-replay-verify.md` (ALIVE, Context: solo); canonical
  table is ground truth (KD-180 canonical row minted this lane).

- KD-169 — Web PubSub server API faces are unauthenticated on the emulator
  (EXPL-4 F5, 2026-10-22): `POST /webpubsub/hubs/:hub/generateToken`,
  `POST .../negotiate`, and `POST .../groups/:group/send` accept no
  credential at all, and `roles_from_conn/1` DEFAULTS to both all-groups
  wildcards when no `role` param is given. The real service gates these
  server-API faces behind the connection-string access key / AAD
  (HMAC-SHA256 `Authorization` header). **Typed posture: deliberate
  loopback-open**, per the air-gap law — smalt is a loopback-only, air-gapped
  emulator (`workspace/` has zero-egress lint; all faces bind loopback), so
  there is no network trust boundary to defend at these faces; the client
  WS upgrade face IS token-gated (`Token.verify/2`, and after EXPL-4 F1 it
  refuses absent-claim tokens). This row exists so the open face is
  registered, not silent. KD-COVERS shim: landing in flight (KD-169R —
  `lib/smalt/webpubsub/router.ex` carries `# KD-COVERS: KD-169` in the
  working tree, uncommitted at this edit's pin time). Disposition: owner =
  KD-169R lane; next action = land the server-credential gate with an
  off-host witness receipt, then flip via `scripts/kd_flip.py --apply`.
  Close condition: a server-credential gate
  (access-key HMAC or Bearer check in `Smalt.WebPubSub.Router` on
  generateToken/negotiate/groups-send, closing the default-wildcard role
  mint) is landed with a witness receipt, or the faces are re-registered
  under a stronger typed posture. Status: CLOSED-WITH-EVIDENCE (KD-169R,
  2026-10-22 — repair landed in `lib/smalt/webpubsub/router.ex`: real-wire
  server-credential gate, Bearer-JWT / SharedAccessKey, typed 401 naming
  the face; court 8/8 + regressions 7/7 + 10/10; witness receipt
  `receipts/kd169r-cred-gate.md`; finding origin `receipts/wps-exp4-repairs.md`
  F5 / `receipts/expl4-wirefronts-errc.md`).

- KD-170 — Azure Confidential Ledger REST face — receipt proof algebra
  (AZ-3, 2026-10-21; minted here as part of the BK-139r dual-claim fold,
  2026-10-22): the receipt `proof` is a **full-witness sha256-chain fold**
  over the segment's leaves (`Smalt.Sync.Receipt` algebra), not a CCF sparse
  Merkle-tree proof; `cryptosuite` is the classical `smalt-rs256-jws` (no
  registered W3C Data-Integrity suite); the face is served on a dedicated
  port (8443 `/app/*` remains the pre-existing ETS-ledger face). The row was
  originally mis-minted as KD-166 in the v26.10.21 pointer (colliding with
  the Web PubSub WS-handshake row); renumbered to KD-170. KD-COVERS shim:
  `lib/smalt/confidential_ledger/{service,router}.ex`
  (`# KD-COVERS: KD-170`). Status: CLOSED-WITH-EVIDENCE (AZ-3 court 6/6
  green over the real HTTP face). Evidence: receipt
  `receipts/az3-confidential-ledger.md`.

- KD-171 — BFF sync + bench/debug route faces are loopback-open (EXPL7-R1,
  2026-10-22): `POST /api/sync/state` (whole sync-container write path),
  the N-7 stream storm/stats/drift faces, the N-4 ingest debug GET, and the
  N-6 isr-revalidate/isr-stats mutating POSTs accept no caller credential.
  The real services gate these behind a session/AAD. **Typed posture:
  deliberate loopback-open** per the air-gap law (KD-169 precedent) — smalt
  is a loopback-only emulator. Partial gates landed in EXPL7-R1:
  `assertLoopbackCaller` on /api/sync/state (Host/Origin loopback check,
  typed 403 `sync_state_non_loopback`; best-effort vs header spoofing, not
  real auth) and an env gate `SMALT_DEBUG_FACES=1` on all bench/debug faces
  (404 when unset; lanes N-6/N-7 must launch their Next server with it).
  The false "requires the BFF session" contract sentence was repaired in
  the same pass. KD-COVERS shim: `workspace/lib/caller-gate.ts` (`# KD-COVERS: KD-171`,
  KD-171R; called from `workspace/app/api/sync/state/route.ts`). Close condition: a shared-secret/HMAC caller
  gate on the sync/state face lands with a witness court (unauthed
  non-loopback POST -> 403 witnessed from off-host, not just a header
  probe), or the faces are re-registered under a stronger typed posture.
  Status: CLOSED-WITH-EVIDENCE (KD-171R 2026-10-22 — shared-secret caller
  gate landed in `workspace/lib/caller-gate.ts` `# KD-COVERS: KD-171`
  (`SMALT_BFF_SYNC_SECRET` set -> `x-smalt-sync-secret` required,
  timingSafeEqual; env unset keeps the loopback-open dev posture); off-host
  witness court `workspace/scripts/kd171r-court.mjs` 6/6 PASS — unauthed
  non-loopback POST to the real LAN IP -> 403, missing/wrong secret -> typed
  403, correct secret -> real apply; receipt
  `receipts/kd171r-secret-gate.md`). Evidence: receipts
  `receipts/expl7r1-bff-repairs.md`, `receipts/kd171r-secret-gate.md`.

- KD-172 — SAS verifier `sb:` audience wildcard (KD-SASV / EXPL-6 F4,
  2026-10-22): `lib/smalt/messaging/amqp/sas_verifier.ex:192`
  `audience_matches?("sb", _host, _port, _config), do: true` — a CBS
  put-token signed for ANY `sb://<anything>` audience verifies against ANY
  configured endpoint with namespace-key rights; real Azure Service Bus
  validates the audience against the presenting namespace and would 401 a
  foreign-namespace audience. **Typed posture: deliberate loopback-open**
  (KD-169 class): real SDKs mint `sb://`-scheme audiences from the
  connection-string namespace while the socket rides loopback, so
  host-scoping the match risks 401-ing real handshakes; smalt is
  loopback-only air-gapped, no network trust boundary at the CBS face.
  Witness probe: foreign `sb://foreign-namespace.evil.example/path` and
  `sb://attacker.example` tokens (dev-key-signed, real compiled module,
  `mix run --no-start`) both verify `{:ok, ...}` against
  `%Audience{scheme:"sb", host:"127.0.0.1", port:5672}` while a foreign
  NON-sb scheme (`amqps://127.0.0.1:5672`) is 401-refused — the wildcard is
  the load-bearing accept path, wired-compat posture check passed
  (SASL ANONYMOUS / CBS put-token unaffected; no pinion touched).
  NOTE: minted during a concurrent wave as KD-171, which the EXPL7-R1 BFF
  lane had already claimed; renumbered to the next free id KD-172 (KD-170
  mis-mint precedent). KD-COVERS shim: `lib/smalt/messaging/amqp/sas_verifier.ex:190`
  (`# KD-COVERS: KD-172`, KD-173R host-scoped `sb:` audience match; receipt
  `receipts/kd173r-audience-repair.md`). Close condition: host-scoped `sb:` audience match
  (endpoint host or endpoint-host-suffix) landed with a witness receipt
  proving real-SDK CBS put-token flow still verifies, or the row
  re-registered under a stronger typed posture. Status: CLOSED-WITH-EVIDENCE (KD-173R 2026-10-22 — host-scoped `sb:` audience match landed in
  `lib/smalt/messaging/amqp/sas_verifier.ex` `# KD-COVERS: KD-172`; court 4 passed; real-SDK
  witness fix4.probe.cjs TOTAL pass=6 fail=0 exit 0 incl. kd131.cbs-put-token-200; canonical
  register row updated; receipt `receipts/kd173r-audience-repair.md`).

- KD-173 — N-4 ingest POST dev default HMAC key is public-source (`n4-dev-key`,
  BK-BFFSEC, 2026-10-22): `POST /api/v1/ingest` is credential-gated (hex
  HMAC-SHA256 over the raw body, `timingSafeEqual`, 401 on missing/invalid;
  witnessed live) but when `SMALT_INGEST_HMAC_KEY` is unset the gate verifies
  against a key hardcoded in `workspace/app/api/v1/ingest/route.ts` — anyone
  with source access mints a valid signature. The real service gates ingest
  behind a provisioned shared secret. **Typed posture: deliberate dev-default
  credential** per the KD-169/KD-171 loopback-open class — smalt is a
  loopback-only emulator and the lane census (2026-10-22, receipt
  `receipts/bkbffsec-census.md`) found no OTHER ungated mutating face in
  `workspace/app/api/**` beyond the KD-171 set. KD-COVERS shim: none yet
  (registration-only row; a gate landing in
  `workspace/app/api/v1/ingest/route.ts` carries `# KD-COVERS: KD-173`).
  Close condition: the route refuses boot (or the face 503s) when
  `SMALT_INGEST_HMAC_KEY` is unset in a non-dev plane, witnessed with a real
  server leg proving a default-key signature is rejected, or the row is
  re-registered under a stronger typed posture. Status: CLOSED-SIMULATED
  (shim landed, witness receipt at
  `receipts/kd173c-devplane-close.md`; window refresh KD-WFIX 2026-10-22 —
  canonical is ground truth, prior window text was stale OPEN). Evidence:
  receipt `receipts/bkbffsec-census.md` (probe 6: default-key sig ->
  202 accepted, no-signature -> 401) + witness
  `receipts/kd173c-devplane-close.md`.

- KD-174 — Kafka wire face serves the (0,10,0)-negotiated legacy message-set
  surface only (AZ-1, 2026-10-22): the ApiVersions matrix advertised by
  `Smalt.Messaging.Kafka.Wire.version_matrix/0` (Produce v0-2, Fetch v0-2,
  ListOffsets v0-1, Metadata v0-1, ApiVersions v0) infers as broker 0.10.0
  to real clients (kafka-python-ng `_infer_broker_version_from_api_versions`),
  so real-SDK produce legs ride legacy magic-0/1 message sets (IEEE CRC32),
  not magic-2 RecordBatches. Magic-2 produce IS served fail-closed
  (CRC32C-verified, crash-only kill on bad CRC/magic — the negative probe's
  named falsifier), but no client version negotiates it on the produce face;
  the real Azure Event Hubs Kafka endpoint is Kafka protocol 1.0+ (magic-2
  RecordBatches, Produce v3+... Produce v7 for EH). Magic-2 is exercised at
  the wire tier by the EXPL-4 F3/F4 raw courts. (Truth-cell addendum,
  KD-174F 2026-10-22: the two witnesses reconcile as TWO LAYERS —
  out-of-matrix Produce v3 REQUESTS take the crash-only kill
  `{:unsupported_version, 0, 3}`, while magic-2 RecordBatch PAYLOADS inside
  in-matrix Produce v0-v2 requests are CRC32C-verified, stored, and re-served
  byte-exact; KD-174F dual-stamp precision (BK-KFKV-1, lane KD-KLV
  2026-10-22): the broker stamps the base offset into BOTH the served
  wrapper offset field AND the batch's inner baseOffset field (batch bytes
  0..7, CRC-neutral) — a no-op at base 0 (every prior byte-compare witness
  produced onto an empty partition), so exact-compare witnesses at base > 0
  must stamp both; the canonical-row cell carries the full reconciliation. No
  flip: the close condition — a client NEGOTIATING magic-2 produce, needing
  Produce v3+ advertisement — stands unmet.) Typed posture: deliberate
  legacy-face parity scope (the served matrix was verified field-by-field
  against kafka-python's versioned schemas this window — Produce/Metadata/
  Fetch/ListOffsets response shapes now byte-match the client's parsers).
  KD-COVERS shim: none yet (registration-only row; a magic-2 client-facing
  produce path landing in `lib/smalt/messaging/kafka/` carries
  `# KD-COVERS: KD-174`). Close condition: a real client negotiates magic-2
  produce through this listener with a witness receipt (requires advertising
  Produce v3+ with matching v3+ response/record shapes), or the row is
  re-registered under a stronger typed posture. Status: OPEN (registered).
  Disposition: owner = BK-122r kafka-parity lane; next action = advertise
  Produce v3+ with matching v3 record shapes, witness a real client
  negotiating magic-2 produce through this listener, then flip via
  `scripts/kd_flip.py --apply` — else re-register under a stronger typed
  posture. Evidence: receipt `receipts/az1c-kafka-receipt.md`.

- KD-175 — Egress blob faces answer a NAKED adapter 500 on oversized
  bodies (EXPL-9 F2/F4, 2026-10-22): unguarded
  `Plug.Conn.read_body/1` in the `{:put_range, s, p}` and
  service-properties arms of `lib/smalt/egress_router.ex` returns
  `{:more, _, _}` over the 8MB cap; the MatchError escaped the router (no
  crash-path fence) and Bandit rendered a NAKED adapter 500 — empty body,
  no envelope, no `x-ms-request-id`. Real Azure answers typed **413
  RequestBodyTooLarge**. Witnessed EXPL-9 P3 (HTTP=500, EMPTY body).
  KD-COVERS shim: `lib/smalt/egress_router.ex` `# KD-COVERS: KD-175`
  (EXPL9-R1 repair landed in dd73b160: `{:more,_,_}` → 413
  RequestBodyTooLarge envelope, `{:error,_}` → 400 InvalidRequestBody,
  plus a `use Plug.ErrorHandler` crash-path fence rendering the Storage
  `<Error><Code>InternalServerError</Code>` envelope; the five fences
  originally carried a mis-minted `# KD-COVERS: KD-174` token, re-tokened
  to KD-175 by lane EXPL9-REG 2026-10-22 — KD-174's scope is the Kafka
  legacy message-set surface only). Close condition: oversized bodies on
  the guarded faces answer the typed 413 RequestBodyTooLarge envelope
  with x-ms-request-id (already witnessed — flip receipt-gated via
  `scripts/kd_flip.py --apply`), or the row is re-registered under a
  stronger typed posture. Status: CLOSED-WITH-EVIDENCE (KD-175F 2026-10-22
  — flipped OPEN → CLOSED-SIMULATED via `scripts/kd_flip.py --apply --only
  KD-175`, witness receipt `receipts/expl9r1-egress-guards.md` postdating
  the shim; registrar close-typing to CLOSED-WITH-EVIDENCE — real-HTTP
  court 5/5, not a simulation. Disposition: close condition satisfied by
  the witnessed naked-500 → 413 RequestBodyTooLarge flip; owner handoff
  complete). Evidence: receipt
  `receipts/expl9r1-egress-guards.md` (real HTTP court 5/5: 9MB Put Range
  → 413 RequestBodyTooLarge XML envelope w/ x-ms-request-id; 9MB Put
  Properties → 413; small-body typed baselines unchanged).

- KD-178 — Web PubSub broker restart vs Bandit child supervision split —
  broker-wipe silent to connected clients (KD-N1, 2026-10-22): a real
  supervised crash of `Smalt.WebPubSub` (`lib/smalt/webpubsub/service.ex`)
  restarts the broker one-for-one with groups registry + witness buffer
  wiped, while client WebSockets ride the separately-supervised Bandit
  child and stay connected — no disconnect is delivered, publish honestly
  answers `{:ok, 0}` over dead membership, rejoin succeeds first-try. Real
  Azure drops client connections on broker restart, forcing
  reconnect+rejoin. Witnessed 5/5 in BK-WPSS2 with the real supervised kill.
  **Typed posture: deliberate in-memory contract** (not a wire-format delta,
  no credential face opened; the surviving-socket channel is the same
  separately-supervised listener that keeps the wire face alive through
  broker restarts). KD-COVERS shim: none yet (registration-only row; a
  broker-death→socket-drop link landing in `lib/smalt/webpubsub/` carries
  `# KD-COVERS: KD-178`). Close condition: socket lifetime linked to broker
  death (monitor from the socket/upgrade path so a broker crash closes
  connected WebSockets) landed with a witness receipt, or the row is
  re-registered under a stronger typed posture. Status: OPEN (registered).
  Disposition: owner = Web PubSub follow-up lane; next action = land the
  socket-lifetime link with a witness receipt, then flip via
  `scripts/kd_flip.py --apply`. Evidence: receipt
  `receipts/bkwpss2-recovery.md` (ALIVE, Context: solo).

- KD-176 — MAA attestation nonce registry — unbounded attacker-keyed ETS
  state (BK-MAASKEP P6, 2026-10-22): the `:smalt_maa_nonces` registry in
  `lib/smalt/attestation/maa.ex` was `:public :set` ETS with `heir: :init`
  and no TTL, no sweep, no entry cap — every consumed nonce row persisted
  for VM lifetime, monotonic growth keyed by attacker-controlled client
  input. Witnessed on HEAD by the BK-MAASKEP probe (200 real attests →
  ETS {0, 200}, permanent rows; `receipts/bkmaaskep-maa-audit.md` P6).
  Real MAA handles nonce state with bounded, expiring structures.
  KD-COVERS shim: none — the BK-MAAP6 repair site carries
  `# KD-COVERS: KD-168`, so this is a registration-style row documenting
  the minted-then-closed class, not a tool-flip anchor. Close condition
  (met): bounded intake (256-byte key cap, TTL sweep on token TTL,
  65 536-entry cap with oldest-consumed eviction, owner-ref'd release)
  landed with the 5/5×20 bounds court receipt postdating the fix.
  Status: CLOSED-WITH-EVIDENCE (registrar close-typing, KD-P6 lane
  2026-10-22 — minted post-repair; divergence class is attacker-controlled
  unbounded registry state vs real MAA's bounded nonce handling, a
  resource-bound divergence not a wire-format delta). Evidence: receipt
  `receipts/bkmaap6-nonce-bounds.md` (real ETS, real future-timestamp
  sweeps: 220 rows freed → 0; 257-byte nonce → typed `invalidparameter`,
  no row written; entry cap evicts uniquely-oldest; P5 owner-ref keeps a
  foreign nonceReplay release from deleting a live `:pending` row).

- KD-177 — Environment-gated hardware-anchored trust surfaces —
  loopback-unwitnessable CLASS row (KD-177 registrar lane, 2026-10-22;
  registration-only class row — KD-168's row is the MAA-TEE-quote
  single-surface member, this row carries the CLASS: hardware-backed trust
  that loopback cannot witness. Window row added by KD-WFIX 2026-10-22,
  mirroring canonical row 357; was canonical-only since mint — KD-MIR2
  projection-lag finding). Census members (v26.10.22 receipts, all typed
  in-receipt not row-registered): (a) MAA TEE quote validation — KD-168
  (`lib/smalt/attestation/maa.ex`; az2-maa-attestation.md: real
  SEV-SNP/TDX quote production UNSUPPORTED, no SNP/TDX firmware / AMD PSP /
  TDX module); (b) MHSM FIPS-level hardware isolation — KD-167
  hardware-isolation leg (az4-mhsm-policies.md + az4b-mhsm-receipt.md: no
  HSM silicon, a real MHSM pool cannot be provisioned on this machine);
  (c) SKR/MAA evidence MINTING on key release — KD-106 face
  (typed-UNSUPPORTED in az4 receipts, unchanged); BK-130
  WebAuthn/permission hardware gates are class-adjacent but carry their own
  typed runtime-unsupported disclosure path, not registered here. NOTE
  (census honesty): the dispatch premise named a DKLS-PRIME/KLDRM/cert-mint
  attestation wave landing v26.10.22 — grep of `docs/jira/v26.10.22/receipts/`
  for dkls/kldrm/cert-mint attest receipts found NONE on disk; the only
  cert-mint hit is PRD.md COURT-CERT-OBS (TLS cert court work, not machine
  attestation), so the class row is grounded in the az2/az4 receipts only.
  The emulator serves the protocol-real attestation/custody faces (MAA
  attest shape, MHSM release-policy evaluation, SKR envelope) but every
  member surface carries a hardware-anchored leg — VCEK/VCEM-signed quotes,
  HSM-silicon key custody, firmware measurement — that no loopback witness
  can produce or verify; the receipts type these legs UNSUPPORTED
  per-surface, but no register row carried the class, so the shared close
  condition (hardware becomes producible/verifiable on-host) was duplicated
  per-receipt rather than registered once. Evidence: receipt census
  `receipts/kd177-envclass.md` (embedded grep census; members KD-168 +
  KD-167 hardware leg + KD-106 face; az2-maa-attestation.md,
  az2b-maa-receipt.md, az4-mhsm-policies.md, az4b-mhsm-receipt.md).
  Close condition: per-member close conditions unchanged and remain
  row-authoritative (KD-168: a real VCEK/VCEM-signed TEE quote becomes
  producible/verifiable on-host; MHSM leg: a real MHSM pool becomes
  provisionable on-host; KD-106 face: MAA evidence minting on release
  becomes producible on-host); class-level falsifier: any of these hardware
  legs becomes producible/verifiable on this host and the corresponding
  member row's gate refuses the tampered/unguarded case — at that point the
  member row flips via its own close condition and this class row closes
  registrar-typed; DO-NOT-FLIP as a class: no loopback receipt can lawfully
  close any member, per the KD-168 hold precedent. Status: OPEN — TYPED
  ENVIRONMENT-GATED DISPOSITION (class row, KD-177 lane 2026-10-22):
  loopback cannot witness any member's hardware leg (no TEE/HSM silicon,
  Darwin arm64, no /dev/sev, per kd166-witness.md); owner: az2/az4
  attestation lanes; next action: none owed by smalt on loopback — the
  protocol-real stand-ins are court-witnessed non-vacuous (az2_maa_court.sh;
  az4 court) and stay until hardware is real; no new spurious eligibility
  minted — kd_flip read-only FLIP-ELIGIBLE 0 pre- and post-mint, KD-168
  DO-NOT-FLIP hold intact.
