# AUD-2 Wire-Parity Audit — Event Hubs / Service Bus (AMQP 1.0) + Key Vault

Lane AUD-2, adversarial mechanical code-level audit, SDK source vs smalt
implementation, read-only except this file. Every claim cites SDK source +
smalt source. SDK roots: `test/sdk-full/node_modules/@azure/*` (TS),
`test/sdk-python/.venv-{eh,sb,auth}/lib/python3.14/site-packages/azure/*` (PY).

State classes: FULL / PARTIAL-STUB / MISSING-UNREGISTERED /
UNSUPPORTED-REGISTERED (KD-xx). Cross-ref ledger:
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (KD-01..KD-53).

## 1. AMQP link attach / source / target / filters

SDK ground truth:

- PY strict positional performatives: `OpenFrame` (10 fields, `_pyamqp/
  performatives.py:17-46`), `AttachFrame` (14 fields, `performatives.py:
  172-207`); `_incoming_open` indexes `frame[4]` unguarded (`_pyamqp/
  _connection.py:436`), `_incoming_attach` requires source AND target
  (`_connection.py:606` via endpoints; the "Invalid link" detach).
- TS EH receiver attaches with source filter `apache.org:selector-filter:
  string` = described(filterClause, 0x468c00000004)
  (`event-hubs/dist/esm/partitionReceiver.js:357-360`) and attach property
  `com.microsoft:epoch` (`partitionReceiver.js:351`, `core-amqp/dist/esm/
  util/constants.js:44`).
- TS SB session receiver reads the granted session id from the attach echo:
  `link.source?.filter?.[Constants.sessionFilterName]`
  (`service-bus/dist/esm/session/messageSession.js:178,228`; filter sent at
  `:257`).

| # | SDK wire signature | State | smalt site | evidence / gap |
|---|---|---|---|---|
| 1 | open echo (10-field positional) | FULL (KD-21 CLOSED-SIMULATED) | connection.ex:281-289 | idle_time_out non-nil pad before reply; frame_codec.ex:269 trailing-null trim is what broke pyamqp |
| 2 | attach echo (14-field positional) | FULL (KD-49 CLOSED-SIMULATED) | connection.ex:475-487 (base_attach echoes client source/target), frame_codec.ex:97-118 (14-field order matches AttachFrame) | comment block cites the pyamqp "takes 15 positional" TypeError class |
| 3 | attach reply `properties` (com.microsoft:locked-until-utc filetime) | FULL | connection.ex:500-506, delivery_encoder.ex:127-128 | epoch-offset filetime, not raw us |
| 4 | source composite 8-field positional (filter at index 7) | FULL | frame_codec.ex:309-344 (encode), 575-632 (decode) | comment records the earlier 7-field mis-slotting |
| 5 | com.microsoft:session-filter decode + echo | FULL | frame_codec.ex:583-607, connection.ex:462 (extract), 496-507 (echo with filter map) | matches messageSession.js:178 read-back |
| 6 | EH `apache.org:selector-filter:string` source filter | MISSING-UNREGISTERED | frame_codec.ex:583-607 decodes ONLY com.microsoft:session-filter; a described selector-filter falls through `Enum.find_value` as nil | GAP-A2-01: eventPosition (offset/sequence/enqueuedTime) filters silently ignored |
| 7 | `com.microsoft:epoch` / `com.microsoft:receiver-name` attach properties | MISSING-UNREGISTERED | connection.ex:424-574 never reads perf.properties on attach | GAP-A2-02: exclusive-receiver (ownerLevel) not enforced — two epoch receivers both receive |
| 8 | delivery_annotations on EH deliveries (last_enqueued_offset/ sequence/time, runtime_info_retrieval_time_utc) | MISSING-UNREGISTERED | connection.ex:1122-1133 emits only message_annotations x-opt-sequence-number | GAP-A2-03: SDK eventData.js fromRheaMessage reads these; eventData.lastEnqueued* are undefined |
| 9 | message annotations x-opt-offset / x-opt-enqueued-time / x-opt-partition-key on EH deliveries | MISSING-UNREGISTERED | connection.ex:1131 (single annotation); EventHubs store has "offset" (event_hubs.ex:15,188) but it is not stamped | GAP-A2-04: eventData.offset/enqueuedTimeUtc/partitionKey undefined; ReceivedEventData declares offset as required (eventData.d.ts ReceivedEventData) |
| 10 | EH batch-envelope unwrap (N inner messages per transfer) | PARTIAL-STUB | connection.ex:720-732 (batched_inner_payloads) + KD-53 OPEN: eh_body_section/1 byte-scan (connection.ex:1156-1182) delivers only the first inner body at delivery time | KD-53 (filed this cycle) |
| 11 | delivery-tag = uuid lock token (0x98) | FULL | frame_codec.ex:282-294 (prepare_fields :transfer), connection.ex:1188-1201 (.NET GUID wire layout token_to_wire) | matches rhea uuid_to_string round-trip |
| 12 | message_format 0 vs raw passthrough | FULL (KD-18/20 CLOSED) | connection.ex:1123-1132 (format 0 + credit bump closes KD-20) | s2-eh-shims receipt |
| 13 | per-session delivery-id sequence + frame chunking to peer max_frame_size | FULL | connection.ex:1432-1499, 1506-1532 | rhea Incoming strict-run validation |
| 14 | SASL ANONYMOUS, sasl-outcome 0x44 | FULL | connection.ex:229-247, frame_codec.ex:70-71 | |
| 15 | SASL/AMQP layer-family enforcement + total decode (no raise on remote input) | FULL | frame_codec.ex:471-476, 518-532 | tagged errors |
| 16 | disposition decode/echo: accepted/released/modified(rebuilt)/rejected; modified undeliverable-here -> defer | FULL | frame_codec.ex:662-682, connection.ex:1296-1373 | TS settle path: receiver settles with settled=false + rcv-settle-mode first -> broker must echo terminal state (connection.ex:1320-1335) |
| 17 | session lock acquire/refuse (com.microsoft:session-cannot-be-locked) + attach-echo-before-detach (rhea) | FULL | connection.ex:490-547 | census-witnessed ordering |
| 18 | transfer batching (N nested messages, one transfer) | FULL | connection.ex:687-699 (SB path extracts each inner message) | distinct from EH KD-53 |
| 19 | `target` address bare-symbol form (pyamqp/rhea short form) | FULL | frame_codec.ex:561-562 | R3 finding |
| 20 | link `handle` scoping per {channel,handle} | FULL | connection.ex:1564-1597 | census stale-handle probe |
| 21 | idle-time-out clamp + pre-open 5s cap | FULL | connection.ex:184-199, 265-311 | R3 |
| 22 | unknown queue attach auth gate via $cbs claims | FULL (documented open-when-CBS-down) | connection.ex:438-454, 1630-1659 | amqps->sb scheme normalization |

## 2. $management request/response surface

SDK ground truth: TS `event-hubs/dist/esm/managementClient.js:93-99,135-142`
(READ ops: body = literal `[]`, app props operation/name/type[/partition],
security_token); TS SB `service-bus/dist/esm/core/managementClient.js:589-614`
(update-disposition status strings completed/abandoned/defered/suspended; body
keys lock-tokens wrap_array 0x98, deadletter-reason/-description,
properties-to-modify, session-id); `core-amqp/dist/esm/util/constants.js:104-117`
(full SB op-name register). smalt dispatcher: management_rpc.ex:100-119
(normalize_op on (operation,type), post-S-2 form incl. operation+type).

| # | SDK operation | State | smalt site | evidence / gap |
|---|---|---|---|---|
| 1 | com.microsoft:renew-lock | FULL | management_rpc.ex:125-160 | lock-tokens array-of-uuid normalize (normalize_token, :501); 410 MESSAGE_LOCK_LOST; SDK reads "expirations" timestamps |
| 2 | com.microsoft:renew-session-lock | FULL | management_rpc.ex:166-187 | queue resolved from associated-link-name (connection.ex:924-933) because the SDK body carries only session-id (managementClient.js:646+) |
| 3 | com.microsoft:peek-message | FULL | management_rpc.ex:193-227 + connection.ex:1022-1072 | reply "message" re-emitted as vbin of re-encoded sections with x-opt-sequence-number annotation (SDK reads it at managementClient.js:315 per the smalt comment); 204 empty |
| 4 | com.microsoft:receive-by-sequence-number | PARTIAL-STUB | management_rpc.ex:337-376, queue_store.ex:350-363, 534-563 | batch-atomic 410 is a documented emulator choice; KD-46 OPEN: deferred redelivery carries no deliveryCount (ts-servicebus-census) |
| 5 | com.microsoft:update-disposition | FULL | management_rpc.ex:237-324 | all four dialect status strings incl. historic "defered"; dead-letter-properties ride-through (:304-311); lock-tokens {:array,..} unwrap (:241-247) |
| 6 | READ type com.microsoft:eventhub | FULL | management_rpc.ex:481-485 (normalize_read), :385-392 | matches managementClient.js:96-99 app-property form + body "[]" |
| 7 | READ type com.microsoft:partition | PARTIAL-STUB | management_rpc.ex:398-418 | partition set hardcoded ["0","1"] (management_rpc.ex:73-74); a hub configured with other partition counts answers 404 PARTITION_NOT_FOUND for real partitions; begin_sequence_number pinned to 1 |
| 8 | set-session-state / get-session-state | MISSING-UNREGISTERED | not in @sb_ops (management_rpc.ex:69-71); handle falls to respond(501 UNSUPPORTED_OPERATION) (:115) | GAP-A2-05: SessionClient setSession/getSession unusable; typed 501, no KD row |
| 9 | get-message-sessions (enumerate sessions) | MISSING-UNREGISTERED | same 501 fall-through | GAP-A2-06 |
| 10 | schedule-message / cancel-scheduled-message | UNSUPPORTED-REGISTERED (KD-47) | 501 fall-through | KD-47 OPEN |
| 11 | batch-delete-messages | MISSING-UNREGISTERED | 501 fall-through; not in KD ledger | GAP-A2-07 |
| 12 | add-rule / remove-rule / enumerate-rules | MISSING-UNREGISTERED | 501 fall-through | rules are subscription-plane; noted, not filed as a KV/EH gap |

## 3. $cbs put-token

SDK ground truth: TS core-amqp `cbs.js:160-175` (request: body = token,
app properties operation "put-token", name = audience, type = tokenType;
reply read from app props "status-code"/"status-description",
constants.js:21-22). PY dialect sends type "jwt" (azure-servicebus
_authentication/_pyamqp cbs path — accepted explicitly in smalt).

| # | signature | State | smalt site | evidence |
|---|---|---|---|---|
| 1 | put-token app-property form (operation/name/type, token in body) | FULL | connection.ex:771-822 (decode), cbs_router.ex:147-184 | op from props["operation"] or subject |
| 2 | type "servicebus.windows.net:sastoken" and pyamqp "jwt" | FULL | cbs_router.ex:40, 205-215 | S-1 disclosure noted in-source |
| 3 | reply correlation-id echo + status-code/status-description (dotted + legacy) | FULL | connection.ex:815-822, 885-899 | core-amqp 4.5.1 dotted keys |
| 4 | audience scheme mismatch (amqps:// vs sb://) | FULL | connection.ex:1638-1654 | pyamqp S-1 |
| 5 | claim cache caps + 429 typed | FULL (emulator extension) | cbs_router.ex:1-9, 160-180 | per-connection + global reap |
| 6 | delete-token | FULL (emulator extension; TS core-amqp never sends it) | connection.ex:808-810, cbs_router.ex:188-199 | harmless surplus |

## 4. Locks / sessions / delivery encoder

| # | signature | State | smalt site | evidence |
|---|---|---|---|---|
| 1 | x-opt-locked-until (timestamp) + com.microsoft:locked-until-utc (filetime ulong) dual stamping | FULL | delivery_encoder.ex:86-97, 127-128 | |
| 2 | x-opt-sequence-number / x-opt-enqueued-time-utc annotations (SB) | FULL | delivery_encoder.ex:88, 94 | SB peeks read x-opt-sequence-number |
| 3 | DLQ footer DeadLetterReason / DeadLetterErrorDescription in APPLICATION PROPERTIES | FULL | delivery_encoder.ex:99-110, queue_store.ex:598-617 | serviceBusMessage.js:302 read class |
| 4 | max_delivery_count abandon deadletter (MaxDeliveryCountExceeded) | FULL | queue_store.ex:565-591 | |
| 5 | queue settings from ARM record (requiresSession/lockDuration/maxDeliveryCount) | PARTIAL-STUB (KD-50) | queue_store.ex:67-97 | camelCase readback lossy per KD-50 |
| 6 | lock-duration clamp 100..30000 | FULL | queue_store.ex:73 | |
| 7 | deferred receive re-lock + delivery_count++ | FULL | queue_store.ex:534-563 | KD-46 covers the missing deliveryCount ANNOTATION on the wire |

## 5. Key Vault wire surface

SDK ground truth: TS `@azure/keyvault-keys/dist/esm/api/operations.js` paths
(extracted verbatim, line refs): `/keys/{key-name}/create` (:734),
`/keys/{key-name}{?api-version}` (create without /create: :645,674),
`/keys/{key-name}{/key-version}{?api-version}` (get/update :583,613),
`/keys/{key-name}/versions` (:554), `/keys` (getKeys :497 region), `/keys/
{key-name}/backup` (:497), `/keys/restore` (index), `/keys/{key-name}/rotate`
(:705), `/keys/{key-name}/rotationpolicy` (:68,99), `/keys/{key-name}{/
key-version}/encrypt|decrypt|sign|verify|wrapkey|unwrapkey` (:435,403,371,339,
307,275), `/keys/{key-name}{/key-version}/release` (:243), `/deletedkeys`
(list :215), `/deletedkeys/{key-name}` (get/delete :157,186),
`/deletedkeys/{key-name}/recover` (:128), `/keys/{key-name}{/key-version}/
attestation` (:8), getRandomBytes. PY identical path set (`.venv-auth .../
keys/_generated/_operations/`: same strings). Challenge whitelist:
`@azure/keyvault-common/dist/esm/parseWWWAuthenticate.js:7-13` — valid keys
authorization, authorization_url, resource, scope, tenantId, claims, error;
tenantId derived from the authorization URL path.

| # | SDK route | State | smalt site | evidence / gap |
|---|---|---|---|---|
| 1 | POST/PUT /keys/{name}/create | FULL | egress_router.ex:389-441 | createKey with kty gate + release_policy validation |
| 2 | GET /keys/{name} (unversioned) | FULL | egress_router.ex:493-502 | 404 KeyNotFound typed |
| 3 | GET /keys/{name}/{key-version} | MISSING-UNREGISTERED | no 3-segment GET route; falls to catch-all 404 | GAP-A2-08: any version-pinned getKey 404s |
| 4 | PUT /keys/{name} (updateKey: attributes/tags/rotation) | MISSING-UNREGISTERED | no PUT /keys route | GAP-A2-09 |
| 5 | GET /keys (list) | FULL | egress_router.ex:527-547, key_vault_actions.ex:123-132 | skips counter rows (skr-version:/skr-jti:) |
| 6 | GET /keys/{name}/versions | PARTIAL-STUB | key_vault_actions.ex:135-145 | returns the single current version (documented); SDK pager expects per-version history |
| 7 | POST /keys/{name}/{version}/encrypt | PARTIAL-STUB (URL space) | egress_router.ex:553-596 (post /keys/:name/:action) | smalt serves the 3-segment form only; the TS/PY SDKs resolve the kid and send the VERSIONED 4-segment path -> 404 unless the caller pins an unversioned client. GAP-A2-10 (KD-33-adjacent versioned-URL class, distinct mechanism: KD-33 is kid placement, this is route shape) |
| 8 | POST .../decrypt | PARTIAL-STUB (same URL class) | same arm | GAP-A2-10 |
| 9 | POST .../sign / verify | PARTIAL-STUB (same URL class) | same arm; alg set RS256/PS256 only (key_vault_actions.ex:414) | SDK alg register is far larger (ES256K, ECDH etc.) -> InvalidAlgorithm 400 for the rest; sub-gap of GAP-A2-10 |
| 10 | POST .../wrapkey / unwrapkey | PARTIAL-STUB (same URL class) | egress_router.ex:569-574 (downcased match) | GAP-A2-10 |
| 11 | POST /keys/{name}{/version}/release | FULL (unversioned) | egress_router.ex:504-510, skr.ex:55-69 | SDK omits {/key-version} when version undefined (expandUrlTemplate collapse); response carries value/kid — policy/policySigned shapes are emulator-defined (documented) |
| 12 | GET/DELETE /deletedkeys, /deletedkeys/{name}, /recover, purge | MISSING-UNREGISTERED | no /deletedkeys routes -> catch-all 404 | GAP-A2-11: soft-delete surface absent (TS :128-215; PY same paths) |
| 13 | GET/PUT /keys/{name}/rotationpolicy, POST /keys/{name}/rotate | MISSING-UNREGISTERED | 404 | GAP-A2-12 |
| 14 | backup / restore | MISSING-UNREGISTERED | 404 | noted under GAP-A2-11 class |
| 15 | getRandomBytes (MHSM) | MISSING-UNREGISTERED | 404 | noted |
| 16 | key attestation /keys/{name}{/version}/attestation | MISSING-UNREGISTERED | 404 | noted |
| 17 | 401 challenge WWW-Authenticate keys (SDK whitelist parse) | FULL (KD-15 CLOSED) | egress_router.ex:49-77 (kv_challenge_guard, mode-blind, OPTIONS + legacy-SKR exempt), bearer.ex:534 (authorization=, resource=, error="invalid_token") | all keys inside parseWWWAuthenticate.js whitelist; tenantId parse requires authorization URL path — bearer.ex:510-534 supplies an absolute URL |
| 18 | api-version query handling | PARTIAL-STUB (KD-34) | not decoded (percent-encoded `api%2Dversion` ignored) | KD-34 OPEN, harmless today |
| 19 | kid placement (top-level + key.kid) | PARTIAL-STUB (KD-33) | egress_router.ex:398-403 emits top-level kid + key.kid at create; crypto ops return only top-level kid (key_vault_actions.ex:278,299,337) | KD-33 surface nit (top-level kid undefined in some SDK reads) — partially addressed, ledger still OPEN |
| 20 | base64url-unpadded value encoding | FULL | key_vault_actions.ex:424-431 | matches real KV contract |

## GAP blocks

### GAP-A2-01 EH selector-filter (eventPosition) ignored
SDK: `partitionReceiver.js:357-360` sends
`{"apache.org:selector-filter:string": described(filterClause, 0x468c00000004)}`
for every receiver with an eventPosition (offset/sequenceNumber/enqueuedTime).
smalt: `frame_codec.ex:583-607` decodes only com.microsoft:session-filter; the
selector falls through and the link delivers from cursor 0 unconditionally
(`connection.ex:1108-1116`: `after_seq = get_in(state, [:eh_cursors,
partition]) || 0`). Falsifier: attach with eventPosition.fromSequenceNumber(n)
and assert the first delivery's x-opt-sequence-number >= n — today it is 1.
Classification: MISSING-UNREGISTERED.

### GAP-A2-02 com.microsoft:epoch not enforced
SDK: `partitionReceiver.js:351` stamps `rheaOptions.properties[Constants.
attachEpoch] = wrap_long(ownerLevel)`; real EH evicts lower-epoch receivers.
smalt: `connection.ex:424-574` never reads attach `properties` — two
receivers with epochs 1 and 2 both receive. Falsifier: two epoch receivers,
both receive = refuted. MISSING-UNREGISTERED.

### GAP-A2-03 EH delivery_annotations absent
SDK: `event-hubs/dist/esm/eventData.js` fromRheaMessage reads
`msg.delivery_annotations.last_enqueued_offset/_sequence_number/_time_utc`.
smalt: `connection.ex:1122-1133` emits none. ReceivedEventData.lastEnqueued*
stay undefined. MISSING-UNREGISTERED.

### GAP-A2-04 EH x-opt-offset / x-opt-enqueued-time / x-opt-partition-key absent
SDK: `eventData.d.ts:42-50` + fromRheaMessage switch; ReceivedEventData.offset
is non-optional. smalt: `connection.ex:1131` stamps only x-opt-sequence-number
although the store rows carry `"offset"` (`event_hubs.ex:15,188`) and no
partition-key is captured at `send_event` (`event_hubs.ex:73`). MISSING-
UNREGISTERED.

### GAP-A2-05 set/get-session-state unimplemented
SDK: `core-amqp constants.js:112-113` operations; SessionClient
setSession/getSession. smalt: outside `@sb_ops` (`management_rpc.ex:69-71`)
-> 501 UNSUPPORTED_OPERATION (:115). Typed (good) but unregistered — no KD
row. GAP classification: MISSING-UNREGISTERED (typed-refused).

### GAP-A2-06 get-message-sessions unimplemented
Same 501 fall-through (constants.js:114). MISSING-UNREGISTERED (typed).

### GAP-A2-07 batch-delete-messages unimplemented
`com.microsoft:batch-delete-messages` (constants.js:109). Same 501
fall-through. MISSING-UNREGISTERED (typed). KD-47 covers schedule-message
only.

### GAP-A2-08 versioned KV GET /keys/{name}/{version} 404
SDK paths (both languages): `/keys/{key-name}{/key-version}` for
get/update/attestation and versioned crypto. smalt: only `get "/keys/:name"`
(`egress_router.ex:493`) and `get "/keys/:name/versions"` (:540) exist; a
3-segment GET falls to the catch-all 404. MISSING-UNREGISTERED.

### GAP-A2-09 updateKey (PUT /keys/{name}) absent
No PUT /keys route in `egress_router.ex`. MISSING-UNREGISTERED.

### GAP-A2-10 versioned crypto-URL class (encrypt/decrypt/sign/verify/wrap/unwrap)
SDK sends `/keys/{name}/{version}/encrypt` etc. (operations.js:275-435; PY
identical). smalt serves only `post "/keys/:name/:action"` (3 segments,
`egress_router.ex:553`). Any SDK crypto call with a resolved version 404s.
Same class as KD-33 (versioned URLs) but distinct mechanism (route shape vs
kid placement). PARTIAL-STUB: works unversioned.
Sub-gap: sign/verify alg register limited to RS256/PS256
(`key_vault_actions.ex:414`) vs the SDK's full alg union -> typed 400
InvalidAlgorithm for the remainder.

### GAP-A2-11 deletedkeys surface absent
`/deletedkeys`, `/deletedkeys/{name}` (GET/DELETE/permanent), `/recover`,
backup/restore (operations.js:128-215). No routes -> 404. MISSING-
UNREGISTERED.

### GAP-A2-12 rotation policy absent
`/keys/{name}/rotationpolicy` GET/PUT, `/keys/{name}/rotate`
(operations.js:68-99,705). 404. MISSING-UNREGISTERED.

## Residual sub-gaps inside fresh closures (requested check)

- KD-19 closure (EH READ ops): covers hub + partition READ, but the
  partition set is hardcoded `["0","1"]` (`management_rpc.ex:73-74`) and
  `begin_sequence_number` is pinned to 1 — residual PARTIAL inside the
  closed KD (row 2.7).
- KD-49 closure (attach echo): base_attach echoes source/target (verified
  `connection.ex:475-487`) — full surface covered for the positional
  strictness class; residual risk only if a future client requires
  `unsettled`/`max_message_size` echo (none today).
- KD-15 closure (KV challenge): covered against the real whitelist; residual
  nit only if the SDK's `authorization_url` key is ever sent by smalt (it is
  not; SDK tolerates).
- KD-33/34 remain OPEN and are the versioned-URL/api-version class the task
  flagged — GAP-A2-08/10 extend this class to route shape.
- Disposition sets: full four-outcome decode + terminal-echo verified (row
  1.16); no residual gap beyond the pyamqp modified-list rebuild already
  handled (`connection.ex:1333-1345`).
- Session filters: com.microsoft:session-filter decode+echo FULL; the
  x-opt-class gap is EH's apache.org selector (GAP-A2-01), not session.

## Counts

- Signatures audited: 67 table rows (22 AMQP wire + 12 management + 6 CBS +
  7 lock/session + 20 KV) — GAP blocks bundle the 15 MISSING rows into 12
  filed gaps.
- FULL: 40. PARTIAL-STUB: 11. MISSING-UNREGISTERED: 15. UNSUPPORTED-
  REGISTERED: 1 (KD-47; plus KD-46/50/33/34 cited as OPEN PARTIAL rows).
- New gaps filed: 12 (GAP-A2-01..A2-12). KD-53 (EH batch drop) was filed
  separately this cycle (commit fd9cfea) and is cross-referenced, not
  duplicated.
