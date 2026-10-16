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
| R1 | open/begin/attach/flow/transfer/disposition field order, mandatory fields | PARTIAL | Byte fences (c5_servicebus.exs `describe "open performative"`, `describe "begin/attach/flow"`). open=0x10, begin=0x11, attach=0x12, flow=0x13, disposition=0x15 orders are spec-exact; GAP R6 drags attach to PARTIAL |
| R2 | Trailing-null omission (OASIS 1.4.3) | PARTIAL | Performatives trim (frame_codec.ex:242, fence `trailing null fields are omitted`); source/target composite bodies do NOT (8-element padded source, fence `attach is a 14-field composite`) — spec-legal, non-minimal |
| R3 | Map count = pairs (OASIS 1.6.9) | CONFORMANT | primitive_codec.ex:141-160 writes count = 2 x pairs; fence `application-properties map8 writes count 2 x entries` pins exact bytes `0xC1 sz 4` for a 2-entry map. Decode accepts both pair-count and element-count forms (primitive_codec.ex:396-415) |
| R4 | Described types + delivery states | CONFORMANT | accepted/rejected/released/modified descriptors 0x24-0x27 (frame_codec.ex:142-147, fence `accepted 0x24 / released 0x26 ...`); section descriptors 0x70-0x78 correct |
| R5 | rejected carries flat error list [condition, description, info] | CONFORMANT | Fence `rejected carries error list` pins the flat 3-element list. Decode ergonomics note: detach/disposition errors decode to the raw positional list, not a map (frame_codec.ex:496-500 has no error-normalizing decode_fields clause) |
| R6 | **GAP** attach source/target descriptor selection | GAP | frame_codec.ex:285: descriptor picked by `Map.has_key?(map, :filter)` — a SOURCE without a filter encodes with the TARGET descriptor 0x29. Falsifier: fence `attach is a 14-field composite` pins 0x29; fix flips it to 0x28 for source, 0x29 for target |
| R6a | sasl-outcome descriptor | CONFORMANT | 0x44 (frame_codec.ex:66); live SASL ANONYMOUS round-trip passes (c5_servicebus.exs `handshake/1`) |
| R6b | SASL wrong-mechanism refusal | CONFORMANT | sasl-outcome code 1 + close with amqp:unauthorized-access (connection.ex:235-238); encode-side only this lane, not live-probed |
| R7 | Flow semantics: credit, delivery-count grant | CONFORMANT | Connection.ex handle_attach grants link_credit 1000 WITH delivery_count 0 (connection.ex:498-505, rhea sender-credit contract); live round-trip delivers on flow credit and settles accepted |
| R7a | drain/echo flow fields | PARTIAL | drain is a no-op (no flow echo; pinned in test/amqp/flow_credit_test.exs moduledoc); echo=true not honored (no flow echo path in connection.ex handle_amqp(:flow)) |
| R8 | amqp:error-conditions vocabulary + exact conditions | CONFORMANT | unauthorized-access (connection.ex:547-549, LIVE-verified detach on unauthorized attach), session-cannot-be-locked encoded at connection.ex:474, resource-limit-exceeded (connection.ex:104-107), not-allowed (connection.ex:290), not-implemented (connection.ex:396), link-message-size-exceeded (connection.ex:649), internal-error; error lists encode as [symbol condition, description, info] |
| R9 | **GAP** session filter decode drops the selector | GAP | frame_codec.ex:535-543: the string-key clause binds the whole `{:described, ...}` value as selector without unwrapping; extract_session_filter then yields a non-binary and Connection.handle_attach silently falls back to base attach — NO session lock, NO session-cannot-be-locked detach for SDK-form attaches (string-keyed filter map -> described value). Live probe: second acceptSession on the same session id gets a plain attach reply, not the typed error. Falsifier: c5_servicebus.exs `second acceptSession ...` asserts the current attach reply; fix flips it to the detach assertion (in-file comment carries the exact expected frame) |
| R9a | Session filter encode (attach request) | PARTIAL | filter-set map keys encode as STRINGs, not symbols (rhea/Azure write symbol keys for filter names); values correctly the described com.microsoft:session-filter composite |
| R9b | locked-until-utc filetime | CONFORMANT | DeliveryEncoder.filetime_from_ms/1 (delivery_encoder.ex:127-128): (ms + 62_135_596_800_000) x 10_000; fence pins 1_700_000_000_000 ms -> 638_355_968_000_000_000 ticks, dual x-opt-locked-until timestamp + filetime annotation. DOC DRIFT: moduledoc example (delivery_encoder.ex:122) says 62_135_596_800_000_000 for ms=0 — 10x low vs the code's 621_355_968_000_000_000 |
| R9b-i | attach properties com.microsoft:locked-until-utc on session attach | CONFORMANT | connection.ex:460-462 (filetime form in attach properties when a session lock is held) |
| R10 | $cbs put-token | CONFORMANT | LIVE-verified: application-properties operation/type/name + token body, 200 reply carrying BOTH dotted and legacy statusCode/statusDescription keys (connection.ex:774-784). delete-token returns 200 unconditionally |
| R11 | $management operations | PARTIAL | renew-lock / renew-session-lock / peek-message / update-disposition / **receive-by-sequence-number** (added V261014-08 08-2: deferred receive re-locks, batch-atomic 410 MESSAGE_NOT_DEFERRED, peek envelope; pinned in test/amqp/management_rpc_test.exs); Service Bus emulator dialect also defines orphaned-locks / peek-by-session / entity ops — absent = UNSUPPORTED_OPERATION 501. **Typed UNSUPPORTED (V261014-08):** session reply-to (`reply_to`/`reply_to_session_id`) — field observed **dropped, not rejected** on requires-session queues; subscription rules (add-rule / remove-rule / SQL filter / correlation filter / `$Default`) — no subscription concept; add-rule stays `:unknown-op` fail-closed. Parked: reply-to store/emit + census probe (next window). |
| R12 | Entity paths: queue / $DeadLetterQueue | CONFORMANT | $DeadLetterQueue -> $deadletterqueue casing normalize (connection.ex:529-535); not live-probed this lane (QueueStore DLQ flow covered by test/amqp/queue_store_test.exs) |
| R13 | delivery-count semantics on redelivery | PARTIAL | delivery_count emitted from stored msg.delivery_count (connection.ex:965); release path increments via QueueStore.release — increment exists in queue_store.ex but was NOT live-probed on the wire this lane |
| R14 | Session end keeps connection alive | CONFORMANT | end -> end ack + per-channel link drop (connection.ex:371-388); live SDK census finding honored |

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
