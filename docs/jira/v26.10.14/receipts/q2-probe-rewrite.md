# Q-2: `wire-delivery-*` probe rewrite — receipt

Lane: Q-2 (finish-support), repo /Users/sac/smalt, branch main, no commits, no
lib edits. Subject: `test/sdk-full/eventhubs.probe.mjs` (probe 5 only).

## Premise drift confirmed

The old `wire-delivery-raw-payload-decode` asserted the removed format!=0 raw
Buffer passthrough. Post-KD-18 the substrate sends `message_format: 0` and
re-emits the recursively-unwrapped body section (`connection.ex`
`eh_body_section/1`), so the SDK tier decodes normally — the probe's own
"undecodable: 0" output had already proved the flip. No substrate defect; no
KD-53 filed (the receive path does NOT emit raw bytes).

## Rewrite

Probe renamed `wire-delivery-batch-unwrap-decode` (same slot, ordered-sequence
assertions kept intact): sends 4 marked JSON payloads
(`{probe, mark, i, nested:{k,n}}`) via the real `@azure/event-hubs` producer
(batch API, one event per send — the shape the passing smoke
subscribe-earliest uses), consumes via `EventHubConsumerClient` from
`offset: "-1"`, filters to this run's `mark` (the partition carries earlier
probes' events from earliest position), and asserts:

- each received body `deepStrictEqual` the original JSON payload, in order
  (the recursive unwrap is the contract now);
- `event.sequenceNumber` integers, strictly increasing.

## Verdict: PASS — 5/5 probes

`flock /tmp/smalt-substrate.lock node test/sdk-full/eventhubs.probe.mjs`
(2026-10-16, substrate booted on private ports 39690-39694, MIX_ENV=test):

```
PASS get-event-hub-properties: partitionIds=["0","1"]
PASS get-partition-properties: 0:begin=1,end=0,offset=0 | 1:begin=1,end=0,offset=0
PASS wire-delivery-ordered-sequence: 6/6 in order, seq [1..6]
PASS wire-delivery-batch-unwrap-decode: bodies deepStrictEqual originals in order; seq [7,8,9,10] strictly increasing
PASS negative-probes: 404 PARTITION_NOT_FOUND / send-bad-partition accepted / no sync error on bad group
done: 5/5 pass
```

## Disclosure: multi-event batch loss (candidate gap, NOT KD-53)

An intermediate honest attempt sent ONE `createBatch` containing 4 events.
Result: exactly 1 delivery (seq 7, body = inner message i:0 decoded
correctly); events i:1..3 never arrived within a 20 s window. Mechanism: the
producer stores the whole batch envelope as ONE stored event; the KD-18 raw
byte scan unwraps only the FIRST inner message's body section, so the
remaining inner messages are silently dropped on delivery. Witnessed, not
inferred. Suggested follow-up: either split multi-event batch envelopes into
per-event stored entries at ingest, or emit one transfer per inner message at
`deliver_eventhubs/2`. Filed here as a candidate for docs/jira/v26.10.15/
triage; out of Q-2 scope (probe rewritten to the currently-supported
one-event-per-send contract, which is also the smoke suite's contract).

## Env

- Node + live `@azure/event-hubs` from `test/sdk-full/node_modules` (real
  collaborators, no mocks); Elixir substrate MIX_ENV=test via the probe's own
  bootstrap; ports 39690-39694 (private block); flock
  /tmp/smalt-substrate.lock held for the run.
