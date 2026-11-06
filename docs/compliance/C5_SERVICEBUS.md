# C5 Service Bus AMQP Dialect Compliance

# C5_SERVICEBUS

Validation of the smalt broker (`lib/smalt/messaging/amqp/`) against the
combined OASIS AMQP 1.0 + Azure Service Bus dialect. Verdicts are grounded in
byte-level encode fences and live raw-frame probes over real `:gen_tcp`
sockets against a real `Smalt.AmqpBroker` on ephemeral ports.

Gate:

    mix test test/compliance/c5_servicebus.exs --include amqp_wire

## Results matrix

| # | Area | Verdict | Evidence |
|---|------|---------|----------|
| R1 | open/begin/attach/flow/transfer/disposition field order, mandatory fields | PARTIAL | Byte fences (c5_servicebus.exs `describe "open performative"`, `describe "begin/attach/flow"`). open=0x10, begin=0x11, attach=0x12, flow=0x13, disposition=0x15 orders are spec-exact; GAP R6 drags attach to PARTIAL. **arcus:** UNSUPPORTED(counterpart-absent) — no AMQP frame-performative layer in arcus `internal/dialect/azure` (REST-shaped face only); receipt p3-l5-c5-reanchor.md |
| R2 | Trailing-null omission (OASIS 1.4.3) | PARTIAL | Performatives trim (frame_codec.ex:264-277, fence `trailing null fields are omitted`); source/target composite bodies do NOT (8-element padded source, fence `attach is a 14-field composite`) — spec-legal, non-minimal. **arcus:** UNSUPPORTED(counterpart-absent) — no AMQP frame codec in arcus; receipt p3-l5-c5-reanchor.md |
| R3 | Map count = pairs (OASIS 1.6.9) | CONFORMANT | primitive_codec.ex:170-190 writes count = 2 x pairs; fence `application-properties map8 writes count 2 x entries` pins exact bytes `0xC1 sz 4` for a 2-entry map. Decode accepts both pair-count and element-count forms (primitive_codec.ex:454-472). **arcus:** UNSUPPORTED(counterpart-absent) — no AMQP primitive codec in arcus; receipt p3-l5-c5-reanchor.md |
| R4 | Described types + delivery states | CONFORMANT | accepted/rejected/released/modified descriptors 0x24-0x27 (frame_codec.ex:159-164, fence `accepted 0x24 / released 0x26 ...`); section descriptors 0x70-0x78 correct. **arcus:** UNSUPPORTED(counterpart-absent) — described-type descriptors did not travel (no AMQP codec in arcus); receipt p3-l5-c5-reanchor.md |
| R5 | rejected carries flat error list [condition, description, info] | CONFORMANT | Fence `rejected carries error list` pins the flat 3-element list. Decode ergonomics note: detach/disposition errors decode to the raw positional list, not a map (frame_codec.ex:486-506 has no error-normalizing decode_fields clause). **arcus:** UNSUPPORTED(counterpart-absent) — no AMQP decode layer in arcus; receipt p3-l5-c5-reanchor.md |
| R6 | **GAP** attach source/target descriptor selection | GAP | frame_codec.ex:316-330: descriptor picked by `Map.has_key?(map, :filter)` — a SOURCE without a filter encodes with the TARGET descriptor 0x29. Falsifier: fence `attach is a 14-field composite` pins 0x29; fix flips it to 0x28 for source, 0x29 for target. **arcus:** UNSUPPORTED(counterpart-absent) — attach descriptor law did not travel; receipt p3-l5-c5-reanchor.md |
| R6a | sasl-outcome descriptor | CONFORMANT | 0x44 (frame_codec.ex:69-73); live SASL ANONYMOUS round-trip passes (c5_servicebus.exs `handshake/1`). **arcus:** UNSUPPORTED(counterpart-absent) — KD pinion #2 (descriptor 0x44) has NO arcus byte pin: no SASL/AMQP layer exists in arcus `internal/dialect/azure`; receipt p3-l5-c5-reanchor.md |
| R6b | SASL wrong-mechanism refusal | CONFORMANT | sasl-outcome code 1 + close with amqp:unauthorized-access (connection.ex:371-380); encode-side only this lane, not live-probed. **arcus:** UNSUPPORTED(counterpart-absent) — SASL handshake layer did not travel; receipt p3-l5-c5-reanchor.md |
| R7 | Flow semantics: credit, delivery-count grant | CONFORMANT | Connection.ex handle_attach grants link_credit 1000 WITH delivery_count 0 (connection.ex:404-416, rhea sender-credit contract); live round-trip delivers on flow credit and settles accepted. **arcus:** UNSUPPORTED(counterpart-absent) — AMQP flow/credit law did not travel; receipt p3-l5-c5-reanchor.md |
| R7a | drain/echo flow fields | PARTIAL | drain is a no-op (no flow echo; pinned in test/amqp/flow_credit_test.exs moduledoc); echo=true not honored (no flow echo path in connection.ex handle_amqp(:flow)). **arcus:** UNSUPPORTED(counterpart-absent); receipt p3-l5-c5-reanchor.md |
| R8 | amqp:error-conditions vocabulary + exact conditions | CONFORMANT | unauthorized-access (connection.ex:371-380, LIVE-verified detach on unauthorized attach), session-cannot-be-locked encoded at connection.ex:795, resource-limit-exceeded (connection.ex:130-140), not-allowed (connection.ex:481), not-implemented (connection.ex:566), link-message-size-exceeded (connection.ex:1340), internal-error; error lists encode as [symbol condition, description, info]. **arcus:** PARTIAL counterpart — amqp:error-conditions symbols did NOT travel; the SB REST error vocabulary landed as `sb_rest.go:369-379` (SbErrEntityNotFound/SessionRequired/TooLarge/Capacity/LockLost/LockUnknown/LockMalformed/AbandonDLQ/MissingSAS); receipt p3-l5-c5-reanchor.md |
| R9 | **GAP** session filter decode drops the selector | GAP | frame_codec.ex:535-543: the string-key clause binds the whole `{:described, ...}` value as selector without unwrapping; extract_session_filter then yields a non-binary and Connection.handle_attach silently falls back to base attach — NO session lock, NO session-cannot-be-locked detach for SDK-form attaches (string-keyed filter map -> described value). Live probe: second acceptSession on the same session id gets a plain attach reply, not the typed error. Falsifier: c5_servicebus.exs `second acceptSession ...` asserts the current attach reply; fix flips it to the detach assertion (in-file comment carries the exact expected frame). **arcus:** UNSUPPORTED(counterpart-absent) — session-filter decode law did not travel; receipt p3-l5-c5-reanchor.md |
| R9a | Session filter encode (attach request) | PARTIAL | filter-set map keys encode as STRINGs, not symbols (rhea/Azure write symbol keys for filter names); values correctly the described com.microsoft:session-filter composite. **arcus:** UNSUPPORTED(counterpart-absent) — no attach/filter encode layer in arcus; receipt p3-l5-c5-reanchor.md |
| R9b | locked-until-utc filetime | CONFORMANT | DeliveryEncoder.filetime_from_ms/1 (delivery_encoder.ex:131-133): (ms + 62_135_596_800_000) x 10_000; fence pins 1_700_000_000_000 ms -> 638_355_968_000_000_000 ticks, dual x-opt-locked-until timestamp + filetime annotation. DOC DRIFT: moduledoc example (delivery_encoder.ex:124) says 62_135_596_800_000_000 for ms=0 — 10x low vs the code's 621_355_968_000_000_000. **arcus:** CONFIRMED counterpart — `amqp_annotations.go:31-50` ports the filetime law (FiletimeEpochOffsetTicks const :34 = 62_135_596_800_000 x 10_000 — matching the smalt CODE value, not the drifted moduledoc; FiletimeFromMs :43, FiletimeToMs :47 round-trip), dual x-opt-locked-until + com.microsoft:locked-until-utc annotation encode at :109-110; receipt p3-l5-c5-reanchor.md |
| R9b-i | attach properties com.microsoft:locked-until-utc on session attach | CONFORMANT | connection.ex:770-780 (filetime form in attach properties when a session lock is held). **arcus:** PARTIAL counterpart — AMQP attach-properties law did not travel; the annotation-encoding half of the law lives in `amqp_annotations.go:109-110` (annLockedUntilUTC filetime form); receipt p3-l5-c5-reanchor.md |
| R10 | $cbs put-token | CONFORMANT | LIVE-verified: application-properties operation/type/name + token body, 200 reply carrying BOTH dotted and legacy statusCode/statusDescription keys (connection.ex:1402-1445). delete-token returns 200 unconditionally. **arcus:** CONFIRMED counterpart — `cbs.go:59-60` (put-token/delete-token ops), `cbs.go:152+` CBSRouter.PutToken verify+cache per {owner, audience}, status vocabulary 200 LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY (:20,:43); receipt p3-l5-c5-reanchor.md |
| R11 | $management operations | PARTIAL | renew-lock / renew-session-lock / peek-message / update-disposition / **receive-by-sequence-number** (added V261014-08 08-2: deferred receive re-locks, batch-atomic 410 MESSAGE_NOT_DEFERRED, peek envelope; pinned in test/amqp/management_rpc_test.exs); Service Bus emulator dialect also defines orphaned-locks / peek-by-session / entity ops — absent = UNSUPPORTED_OPERATION 501. **Typed UNSUPPORTED (V261014-08):** session reply-to (`reply_to`/`reply_to_session_id`) — field observed **dropped, not rejected** on requires-session queues; subscription rules (add-rule / remove-rule / SQL filter / correlation filter / `$Default`) — no subscription concept; add-rule stays `:unknown-op` fail-closed. Parked: reply-to store/emit + census probe (next window). **arcus:** PARTIAL counterpart — REST-shaped arms only: renew-lock/unlock-abandon/settle arms (`sb_rest.go:10-12` renew via POST {seq}/{locktoken}, :332-333 SbLocationHeader); AMQP management RPC ops (renew-session-lock, peek-message, update-disposition, receive-by-sequence-number) counterpart-absent; receipt p3-l5-c5-reanchor.md |
| R12 | Entity paths: queue / $DeadLetterQueue | CONFORMANT | $DeadLetterQueue -> $deadletterqueue casing normalize (connection.ex:962-969); not live-probed this lane (QueueStore DLQ flow covered by test/amqp/queue_store_test.exs). **arcus:** CONFIRMED counterpart — `entitypath.go:10-11,34-35,63,208-218` ports the DLQ naming law (DLQSuffix "/$deadletterqueue", DLQName, IsDLQ, subscription DLQ from topic/Subscriptions/<sub>); casing-normalize half (smalt normalizes $DeadLetterQueue input casing) counterpart-absent — arcus admits lowercase only; receipt p3-l5-c5-reanchor.md |
| R13 | delivery-count semantics on redelivery | PARTIAL | delivery_count emitted from stored msg.delivery_count (connection.ex:2260); release path increments via QueueStore.release — increment exists in queue_store.ex but was NOT live-probed on the wire this lane. **arcus:** UNSUPPORTED(counterpart-absent) — delivery-count redelivery law did not travel; receipt p3-l5-c5-reanchor.md |
| R14 | Session end keeps connection alive | CONFORMANT | end -> end ack + per-channel link drop (connection.ex:517-532); live SDK census finding honored. **arcus:** UNSUPPORTED(counterpart-absent) — AMQP session/end law did not travel; receipt p3-l5-c5-reanchor.md |

## Live probe receipt

- Command: `mix test test/compliance/c5_servicebus.exs --include amqp_wire`
- Last run: 16 tests, 0 failures, 0.3s (plus seeds 123456 and 42: 16/0 each,
  flake check). 3 live probes (round-trip, unauthorized detach, second
  acceptSession), 13 byte-level fences. ExUnit config excludes :amqp_wire by
  default; the gate command includes it.
- Live round-trip: SASL ANONYMOUS -> open -> begin -> $cbs put-token (200,
  LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY) -> sender attach -> transfer
  -> server disposition(accepted) -> receiver attach -> flow(link_credit 10)
  -> delivery with message_id round-tripped -> disposition(accepted).
- Unauthorized probe: attach without a CBS claim -> detach
  [amqp:unauthorized-access, UNAUTHORIZED_ENTITY, nil].
- Session-conflict probe: second acceptSession with SDK-form session filter
  -> plain attach reply (GAP R9; expected detach pinned in the test comment).
- Broker key: random per-run `:smalt, :sb_shared_key`; private broker tree on
  probed ephemeral ports; on_exit restores the shared tree
  (SmaltTest.Lifecycle contract).

## Known-gap policy

Rows marked GAP run red-to-fix fences: the fence currently pins the observed
(gap) bytes and the in-file comment carries the spec-correct expectation, so
a fix must flip both the assertion and the row. Rows marked PARTIAL name the
missing half explicitly.
