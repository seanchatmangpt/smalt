# R200b: KD-71 witness — x-opt-* annotations mapped onto ReceivedEventData

Standing: PASS
Lane: 259 probe/witness · 2026-10-16
Surface: `lib/smalt/messaging/amqp/connection.ex` `eh_event_annotations/1` (~:1596, `# KD-COVERS: KD-71`), `lib/smalt/messaging/event_hubs.ex` `send_event/3` (partition_key capture)
Subject: real `@azure/event-hubs` 6.0.4 (`/Users/sac/smalt/workspace/node_modules`) against lane-private smalt substrate (anonymous auth, ports 39292/39293/39294, `MIX_BUILD_ROOT=_build-lane259`)

## Claim

KD-71 falsifier: on a real EH receive, `event.offset` (string),
`event.enqueuedTimeUtc` (Date), and `event.partitionKey` are defined —
mapped by the SDK's `fromRheaMessage` from the smalt-stamped message_annotations
`x-opt-offset` / `x-opt-enqueued-time` / `x-opt-partition-key`
(`x-opt-sequence-number` pre-existing).

## Re-run evidence

Command: `node /tmp/smalt-lane259/witness-run.mjs; echo exit=$?` (exit 0;
transcript of the canonical run in
`/tmp/smalt-lane259/full-witness-output.txt`, embedded below). Probe:
`/Users/sac/smalt/tmp/lane259-kd70-kd71-witness.cjs` (partition path) +
`/tmp/smalt-lane259/pk_probe.cjs` (partition-key phase).

```
$ node /tmp/smalt-lane259/witness-run.mjs; echo exit=$?
[witness-run] substrate up on 39292/39293/39294 after 2008ms
[witness] partition 0 received 2 events
[witness] lastEnqueuedEventProperties: {"sequenceNumber":2,"enqueuedOn":"2026-10-16T11:13:28.509Z","offset":"2","retrievedOn":null}
[witness] hub partitions: ["0","1"]
[witness] partition 0 events: kd70-witness-a|kd70-witness-b
[witness] partition 1 events:
[witness] rawAmqp messageAnnotations: {"x-opt-enqueued-time":"2026-10-16T11:13:28.509Z","x-opt-offset":"1","x-opt-sequence-number":1}
[PASS] kd71-offset-string            (offset "1", string)
[PASS] kd71-enqueuedTimeUtc-Date     (Date from x-opt-enqueued-time)
[PASS] kd71-sequenceNumber-number    (1)
[PASS] kd71-monotonic-sequence       (1 -> 2)
=== WITNESS SUMMARY: 10 pass / 0 fail === (KD-71 share: 4/4 partition-path)
```

Partition-key phase (hub-address sender — the SDK's own routing for
partitionKey sends — receive + SDK `fromRheaMessage` mapping):

```
PK-PROBE wire message_annotations={"x-opt-enqueued-time":"2026-10-16T11:13:28.511Z","x-opt-offset":"1","x-opt-partition-key":"pk-a","x-opt-sequence-number":1}
PK-PROBE wire delivery_annotations={"last_enqueued_offset":"2","last_enqueued_sequence_number":2,"last_enqueued_time_utc":"2026-10-16T11:13:40.657Z"}
PK-PROBE fromRheaMessage: partitionKey="pk-a" offset="1" sequenceNumber=1 enqueuedTimeUtc=2026-10-16T11:13:28.511Z
PK-PROBE VERDICT: PASS
[witness-run] main=0 pk=0
```

Honest out-of-row finding (not a KD-71 annotation defect): a partitionKey
send rides the hub entity address; smalt stores hub-address events under the
hub key (`kd70-hub`), so a `subscribe("0"|"1")` partition subscription never
delivers them — the event is stored and round-trips on the hub-address
receiver, but partition-scoped consumers don't see pk-routed sends. Separate
KD-row candidate; classification owned by kd-registrar.

## Verdict

KD-71 witness PASS: offset / enqueuedTimeUtc / sequenceNumber asserted on the
public `ReceivedEventData` surface (4/4), partitionKey witnessed through the
SDK's own `fromRheaMessage` on a real delivered message (x-opt-partition-key
round-trips). No errors. Row flip remains with kd-registrar; this receipt is
the post-shim PASS evidence naming KD-71.
