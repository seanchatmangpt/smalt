# SDK lane TS-5 — real @azure/event-hubs against the smalt EH lane

Date: 2026-10-15. Repo `/Users/sac/smalt` v26.10.14. SDK: `@azure/event-hubs`
6.0.4, real npm install into `test/sdk-full/`. Harness:
`test/sdk-full/eventhubs.probe.mjs` (new file, this lane), following the
`ts-run.mjs` bootstrap (boot eval with per-port app env, TCP poll, detached
process-group teardown). Run: `node test/sdk-full/eventhubs.probe.mjs`
(or `SMALT_TSEH_EXTERNAL=1 SMALT_TSEH_KEY=<key>` to attach to a running
substrate).

## Verdict

**The post-fix EH wire delivery path WORKS at the AMQP wire tier; the real-SDK
tier does NOT yet complete.** This is the first real-SDK witness of the
receiver-delivery path. Three typed hops from SDK-green, each named with its
fix:

1. **`message_format` omitted on EH deliveries (blocking, one-line fix).**
   `deliver_eventhubs/2` (`lib/smalt/messaging/amqp/connection.ex` ~line 1088)
   sends its transfer performative with only `handle`/`delivery_tag`;
   `message_format` is omitted. AMQP semantics treat omitted-as-0, but rhea's
   session decoder (`rhea/lib/session.js:389`,
   `current.format === 0 ? decode : raw passthrough`) requires the field to be
   literally present-and-0 before it decodes. Result: SDK and rhea consumers
   receive the payload as an opaque raw buffer — `ev.body`,
   `ev.sequenceNumber`, `ev.offset`, `ev.rawAmqpMessage` all `undefined` —
   while the transfer bytes on the socket are correct AMQP. The sibling SB
   queue path (`deliver_to_link`) sets `message_format: 0`; EH was missed.
   Fix: add `message_format: 0` to the `send_message` fields in
   `deliver_eventhubs/2`.
2. **`$management` EH ops answered 501.** `Smalt.Amqp.ManagementRpc.handle/2`
   (`lib/smalt/messaging/amqp/management_rpc.ex:96`) implements only Service
   Bus operations (renew-lock / peek / receive-by-sequence / disposition); the
   SDK bootstrap (`getEventHubProperties` / `getPartitionProperties`) receives
   `MessagingError(NotImplementedError) UNSUPPORTED_OPERATION` (501), so
   `subscribe()` bootstrap fails identically (it calls getEventHubProperties
   first). `Smalt.Amqp.Connection.route/2` routes all `$management` links to
   the SB dispatcher on both lanes.
3. **Credit not enforced on the EH lane.** `deliver_eventhubs/2` delivers
   transfers without decrementing link credit (the SB path does
   `bump_credit(link, -1)`); rhea logged `Received transfer when credit was 0`
   repeatedly (46 transfers against a credit_window-200 receiver plus backlog
   replay, 12 credit-0 transfers against the SDK consumer).

## Per-probe receipt (final run: 4/5 PASS)

Substrate: private ports 39690-39694 (39691 = EH lane), `mix run --no-start
--no-halt`, MIX_ENV=test, boot 2.0s. SAS: random 48-byte base64 key matched to
the substrate verifier. **Typed deviation:** `/tmp/smalt-substrate.lock` was
held (inherited fd) by a long-lived sibling substrate with ~19 queued waiters,
so this lane ran on verified-free private ports instead; all ports verified
clear at teardown.

| probe | result | evidence |
|---|---|---|
| get-event-hub-properties | PASS (GAP-CLASS recorded) | `MessagingError(NotImplementedError) UNSUPPORTED_OPERATION` (501) |
| get-partition-properties | PASS (GAP-CLASS recorded) | 501 for partitions `"0"` and `"1"` |
| wire-delivery-ordered-sequence | FAIL (typed) | 6 partition-pinned events sent; transfers arrive with correct wire bytes but SDK-visible fields all `undefined` (gap 1) |
| wire-delivery-raw-payload-decode | **PASS — the witness** | rhea receiver on `ts5-hub/ConsumerGroups/$Default/Partitions/0`: 46 transfers seen, **4/4 marked events decoded from the raw payload bytes: `x-opt-sequence-number=[43,44,45,46]` strictly increasing, bodies byte-exact** |
| negative-probes | PASS (typed witnesses) | `getPartitionProperties("does-not-exist")` → 501; **send to nonexistent partition ACCEPTED (no partition validation)**; nonexistent consumer group → attach accepted, no error surfaced |

## Wire evidence (TCP sniff, unmodified bytes)

Server-to-client transfer frame on channel 1 (139 B, captured through a local
TCP proxy; hex truncated):

```
0000008b 02 00 00 00 01  53 14                          ; transfer performative
  c0 0e 03  43  52 01  a1 08 <8B delivery-tag>          ; handle=0, delivery-id=1, tag (NO message_format field)
  00 53 72  c1 1a 02  a1 15 "x-opt-sequence-number" 52 01  ; message_annotations, seq=1
  00 53 75  a0 4c  <76B body>                           ; body_data (stored sender bytes)
```

Body_data payload = the stored event body = the sender's full encoded message
bytes (the SDK batch-envelope amqp-value). Sequence annotations observed
strictly monotonic across a 46-transfer backlog replay. The bytes are correct
AMQP; the decode failure is purely the absent `message_format` field.

## Smoke tier cross-check (test/sdk-smoke via eh-run.mjs)

`SMALT_SDK_ROOT=test/sdk-full node test/sdk-smoke/eh-run.mjs` — substrate up on
39172/39173/39444 in 1.5s; **smoke 0/4, exit 1** (fail-closed as designed):

- `get-properties` FAIL: `MessagingError UNSUPPORTED_OPERATION` — same
  $management 501 gap as above.
- `batch-send` FAIL: `TypeError: batch.canAdd is not a function` — smoke
  test-code defect (SDK 6.0.4 `EventDataBatch` surface drift), not a wire
  failure.
- `subscribe-earliest` FAIL: `MessagingError UNSUPPORTED_OPERATION` —
  subscribe bootstrap calls getEventHubProperties first (gap 2).

Corollary: `docs/WIRE_PARITY.md` row "Event Hubs AMQP wire lane ... Pinned on
the real wire by the @azure/event-hubs SDK smoke (getProperties / sendBatch /
subscribe) | ALIVE" is stale on the SDK tier — the smoke currently exits 1.
The module-tier court (`test/amqp/event_hubs_test.exs`, smalt's own codec) is
self-consistent and does not exercise a foreign decoder.

## Artifact inventory

- `test/sdk-full/eventhubs.probe.mjs` — probe harness (re-runnable,
  `SMALT_TSEH_*` port overrides, external-attach mode).
- `test/sdk-full/node_modules/` + `package.json`/`package-lock.json` drift —
  `@azure/event-hubs` install (NOT committed per instruction).
- No `lib/` or `test/` files edited. No commits. Substrate processes and
  proxies killed; ports 39690-39694 / 39172-39446 verified clear at teardown.
