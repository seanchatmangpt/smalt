# R200c: KD-68 falsifier — EH selector-filter (eventPosition {sequenceNumber}) ignored on real @azure/event-hubs receive

Standing: FAIL (falsifier confirmed — KD-68 divergence reproduced on the real SDK surface; this is the falsifier firing, not a test-harness failure)
Lane: 274 probe/witness · 2026-10-16
Surface: `lib/smalt/messaging/amqp/connection.ex` EH receiver attach / `deliver_eventhubs` (no `apache.org:selector-filter:string` handling — the selector decoded by `frame_codec.ex:619` as `{:selector_filter, selector}` falls through unused in `handle_attach/3`), `lib/smalt/messaging/event_hubs.ex` `receive_events/3`
Subject: real `@azure/event-hubs` 6.0.4 (`/Users/sac/smalt/workspace/node_modules`) against a lane-private smalt substrate (anonymous auth, private ports amqp 39295 / eh 39296 / arm 39297, aux listeners pinned to verified-free 43925/43926/43927 — the shared substrate holds 9443/9444/8443/9545 and was never touched; `MIX_BUILD_ROOT=_build-lane274`)

## Claim (register falsifier)

v26.10.14 `KNOWN_DIVERGENCES.md:151` (KD-68, OPEN): "decode/apply selector-filter;
falsifier: attach with fromSequenceNumber(n) → first delivery
x-opt-sequence-number >= n (today 1)".

Real API used (SDK 6.0.4 surface — `EventPosition` has no `fromSequenceNumber`;
the sequence-number position rides `startingPosition`):
`EventHubConsumerClient.subscribe(partition, handlers, { startingPosition: { sequenceNumber: 2, isInclusive: true } })`.
The SDK converts that to the wire selector
`amqp.annotation.x-opt-sequence-number >= '2'`
(`dist/commonjs/eventPosition.js:35`, `getEventPositionFilter`; internal module
not requirable through the package `exports` — value read from source, not
asserted on the wire directly).

Harness: `/tmp/smalt-lane274/witness-run.mjs` (runner, adapted from the
r200a/r200b lane-259 harness) + `/tmp/smalt-lane274/kd68-falsifier.cjs` (probe).
Exit-code contract honored: 0 pass / 1 probe fail / 2 substrate never up /
3 loud skip. No skip fired — the SDK fully expresses the falsifier.

## Re-run evidence

Command: `node /tmp/smalt-lane274/witness-run.mjs; echo exit=$?` (exit 1 —
probe FAIL as the register predicts; transcript of the canonical run embedded
below, unedited).

```
[witness-run] substrate up on 39295/39296/39297 (aux 43925/43926/43927) after 2009ms
[falsifier] SDK selector expected on the wire: "amqp.annotation.x-opt-sequence-number >= '2'"
[falsifier] sent 4 events to partition "0" (expected seq 1..4); selector position n=2
[falsifier] rawAmqp keys: ["header","footer","messageAnnotations","deliveryAnnotations","applicationProperties","properties","body","bodyType"]
[falsifier] rawAmqp messageAnnotations: {"x-opt-enqueued-time":"2026-10-16T12:07:53.850Z","x-opt-offset":"1","x-opt-sequence-number":1}
[falsifier] rawAmqp deliveryAnnotations: {"last_enqueued_offset":"4","last_enqueued_sequence_number":4,"last_enqueued_time_utc":"2026-10-16T12:07:53.851Z"}
[falsifier] rawAmqp body: Section {
  typecode: 117,
  content: <Buffer 22 6b 64 36 38 2d 65 31 22>,
  multiple: undefined
}
[falsifier] delivered 4 events; sequenceNumbers=[1,2,3,4]; bodies=["kd68-e1","kd68-e2","kd68-e3","kd68-e4"]
[FAIL] kd68-first-delivered-seq-gte-n  (first=1, n=2)
[FAIL] kd68-no-events-before-n  (seqs=[1,2,3,4])
[FAIL] kd68-inclusive-boundary  (first seq expected exactly 2 (isInclusive), got 1)
[falsifier] control (fresh conn, earliest): seqs=[1,2,3,4]
[PASS] kd68-control-earliest-receives  (got 4)
=== FALSIFIER SUMMARY: 1 pass / 3 fail ===
  FAIL  kd68-first-delivered-seq-gte-n  (first=1, n=2)
  FAIL  kd68-no-events-before-n  (seqs=[1,2,3,4])
  FAIL  kd68-inclusive-boundary  (first seq expected exactly 2 (isInclusive), got 1)
  PASS  kd68-control-earliest-receives  (got 4)
[witness-run] probe=1
exit=1
```

## Findings

1. **KD-68 reproduced exactly as registered.** With
   `startingPosition {sequenceNumber: 2, isInclusive: true}`, the first
   delivered event has `x-opt-sequence-number = 1` (< n), and all 4 events
   (1..4) are delivered — the selector is ignored and the receiver starts from
   cursor 0. This is the register row's literal "(today 1)" prediction. The
   falsifier is non-vacuous: the control leg (fresh connection, earliest
   position) delivers the same 4 events, proving the receive path itself is
   alive and the failures are the filter, not the harness.
2. **Adjacent surfaces are intact on this tree**: message_annotations
   (x-opt-sequence-number / x-opt-offset / x-opt-enqueued-time) and
   delivery_annotations (last_enqueued_*) are present on the same deliveries —
   the r200a/r200b KD-70/KD-71 witness behavior still reproduces.
3. **No shim to flip**: `connection.ex` on this tree carries no
   `KD-COVERS: KD-68` marker (HEAD neither — the r115 reference to
   `connection.ex:1538` describes the v26.10.14 numbering and predates the
   current file). The register row correctly remains OPEN with no
   simulated-coverage claim. Register flip is NOT performed (kd-registrar
   owns rows; and this receipt closes nothing — it re-opens nothing either,
   the row was already OPEN).

Machine (`just bench-machine`): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Verdict

KD-68 witness FAIL — falsifier fires on the real @azure/event-hubs 6.0.4
receive path: selector-filter `amqp.annotation.x-opt-sequence-number >= '2'`
is ignored, first delivered event sequenceNumber = 1 < 2. 3 falsifier
assertions fail, control leg passes, zero harness errors. KD-68 row stays
OPEN; close condition unchanged (decode/apply the selector filter in
`handle_attach`/`deliver_eventhubs`), now with a PASS-shaped witness harness
ready to re-run green the moment the shim lands
(`node /tmp/smalt-lane274/witness-run.mjs`).
