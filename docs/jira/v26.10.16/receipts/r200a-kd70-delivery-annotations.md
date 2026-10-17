# R200a: KD-70 witness — EH delivery_annotations last_enqueued_* on real @azure/event-hubs receive

Standing: PASS
Lane: 259 probe/witness · 2026-10-16
Surface: `lib/smalt/messaging/amqp/connection.ex` `eh_delivery_annotations/1` (~:1615, `# KD-COVERS: KD-70`), `lib/smalt/messaging/event_hubs.ex` `last_enqueued/1`
Subject: real `@azure/event-hubs` 6.0.4 (from `/Users/sac/smalt/workspace/node_modules`) against a lane-private smalt substrate (anonymous auth, private ports 39292/39293/39294, `MIX_BUILD_ROOT=_build-lane259`)

## Claim

KD-70 falsifier: a real EH receive carries the delivery_annotations section —
`last_enqueued_offset` (string), `last_enqueued_sequence_number` (number),
`last_enqueued_time_utc` (AMQP timestamp) — and the SDK maps them to
`lastEnqueuedEventProperties` on the public surface (requires
`trackLastEnqueuedEventProperties: true`; field names in v6 are
`offset` / `sequenceNumber` / `enqueuedOn`).

Surface note (supersedes the register row's literal wording): the register
falsifier text says "ReceivedEventData.lastEnqueued*"; in SDK 6.0.4 those
fields do not exist on `ReceivedEventData` — the truth rides the
delivery_annotations section into `partitionContext.lastEnqueuedEventProperties`.
The witness asserts both the raw wire section and the public v6 surface.

## Re-run evidence

Command (lane runner): `node /tmp/smalt-lane259/witness-run.mjs; echo exit=$?`
(exit 0 — main phase 10 pass / 0 fail; pk phase PASS; full transcript below,
same run)

```
[witness-run] substrate up on 39292/39293/39294 after 2008ms
[witness] partition 0 received 2 events
[witness] lastEnqueuedEventProperties: {"sequenceNumber":2,"enqueuedOn":"2026-10-16T11:13:28.509Z","offset":"2","retrievedOn":null}
[witness] hub partitions: ["0","1"]
[witness] partition 0 events: kd70-witness-a|kd70-witness-b
[witness] partition 1 events:
[witness] rawAmqp deliveryAnnotations: {"last_enqueued_offset":"2","last_enqueued_sequence_number":2,"last_enqueued_time_utc":"2026-10-16T11:13:28.509Z"}
[witness] rawAmqp messageAnnotations: {"x-opt-enqueued-time":"2026-10-16T11:13:28.509Z","x-opt-offset":"1","x-opt-sequence-number":1}
[PASS] kd70-wire-last_enqueued_offset
[PASS] kd70-wire-last_enqueued_sequence_number
[PASS] kd70-wire-last_enqueued_time_utc
[PASS] kd70-lep-offset
[PASS] kd70-lep-sequenceNumber
[PASS] kd70-lep-enqueuedOn
[PASS] kd71-offset-string
[PASS] kd71-enqueuedTimeUtc-Date
[PASS] kd71-sequenceNumber-number
[PASS] kd71-monotonic-sequence
=== WITNESS SUMMARY: 10 pass / 0 fail ===
PK-PROBE VERDICT: PASS
[witness-run] main=0 pk=0
```

Direct wire receipt (raw rhea receiver, separate probe run, same lane substrate):

```
RAW MESSAGE KEYS: ["message_annotations","delivery_annotations","body"]
RAW delivery_annotations: {"last_enqueued_offset":"1","last_enqueued_sequence_number":1,"last_enqueued_time_utc":"2026-10-16T11:05:13.992Z"}
```

Residual: `retrievedOn: null` — `runtime_info_retrieval_time_utc` is not
stamped; the KD-70 row already carries this as the remaining gap.

## Verdict

KD-70 witness PASS: 6/6 KD-70 assertions pass on the real SDK receive path
(3 wire + 3 public-surface). No errors. Row flip remains with kd-registrar;
this receipt is the post-shim PASS evidence naming KD-70.
