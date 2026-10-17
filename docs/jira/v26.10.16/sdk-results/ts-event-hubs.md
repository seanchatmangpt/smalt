# SDK lane TS-5 — real @azure/event-hubs (TypeScript) against the smalt Event Hubs plane

- **Date**: 2026-10-16 · **Lane**: lane333
- **Repo/SHA**: `/Users/sac/smalt` @ `main` `fd9cfea`
- **SDK**: `@azure/event-hubs` (from `test/sdk-full/node_modules`)
- **Runtime**: Node, macOS arm64 (Darwin 25.2.0)
- **Substrate**: probe self-boots its own substrate on its documented private block (AMQP 39690 / EH 39691 / ARM 39692 / EGRESS 39693 / ARM-TLS 39694), anonymous auth, `MIX_BUILD_ROOT=_build-lane333`, under `flock /tmp/smalt-substrate.lock` (fd closed)
- **Probe**: `test/sdk-full/eventhubs.probe.mjs`
- **Verdict**: 6/6 probes PASS, exit 0

## executed commands (receipt)

```bash
SMALT_TSEH_AMQP_PORT=39690 SMALT_TSEH_EH_PORT=39691 SMALT_TSEH_ARM_PORT=39692 \
SMALT_TSEH_EGRESS_PORT=39693 SMALT_TSEH_ARM_TLS_PORT=39694 \
  node test/sdk-full/eventhubs.probe.mjs   # exit 0
```

## results (2026-10-16, raw probe output)

```
PASS [0.0s] get-event-hub-properties
PASS [0.0s] get-partition-properties
PASS [0.3s] wire-delivery-ordered-sequence
PASS [0.3s] wire-delivery-batch-unwrap-decode
PASS [0.3s] wire-delivery-annotations: offset=11 enqueuedTimeUtc=... seq=11 wire last_enqueued_offset=11 last_enqueued_sequence_number=11 last_enqueued_time_utc=... tracked={...} — SDK witness for GAP-A2-03/04
PASS [3.0s] negative-probes: nonexistent-partition: MessagingError(ServiceCommunicationError) PARTITION_NOT_FOUND || send-bad-partition: NO ERROR (accepted) || nonexistent-consumer-group: no synchronous error (processError channel observed)
[ts-eh-probe] done: 6/6 pass
```

EH $management routing (KD-19 closed) witnessed live this window:
get-event-hub-properties / get-partition-properties answer from the EH-mode
dispatcher. Delivery annotations and batch-unwrap decode (KD-18 family,
closed) also witnessed on the wire.

## notes

- $management metadata probes that were OPEN in v26.10.14 now answer — the
  closed KD-18/19/20 rows are witnessed green this window.
