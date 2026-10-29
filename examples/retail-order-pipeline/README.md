# retail-order-pipeline

Fortune-500 archetype: a retail order pipeline running against the smalt
sovereign Azure drop-in substrate. Real wire, official `@azure/*` SDKs
(reused from `verification/ts/node_modules` via symlink), no mocks, no
emulator-internal imports, no fixed sleeps (waits ride the
`verification/ts/harness/poll.ts` bounded poll).

## The business story

A retailer's order pipeline has three planes:

1. **Order intake (Service Bus)** — checkout pushes 10 orders onto a queue;
   the fulfillment worker receives in peekLock mode and completes each one.
   Variants: an order placed **on hold** is deferred and later resumed by
   sequence number (`receiveDeferredMessages`); a slow worker holds a message
   past two lock durations while renewing its lock (`renewMessageLock`);
   a **poison order** is abandoned past `maxDeliveryCount=3` and lands in the
   `$DeadLetterQueue` with `DeliveryCount` and a dead-letter reason.
   (Scheduled enqueue is a typed loud skip: the schedule-message $management
   op is unlanded in the substrate — KD-118 — and is never faked.)
2. **Store/event ingestion (Event Hubs)** — 100 order events are pinned to
   the fixed partitions `["0","1"]` (smalt EH pinion), 50 per partition.
3. **Order state (Cosmos)** — order documents are persisted with etag CAS:
   upsert → conditional replace with `IfMatch` succeeds, a stale etag gets
   typed 412, and the final state is read back and asserted. The same etag
   CAS is the exactly-once checkpoint store for the Event Hubs consumer: one
   checkpoint document per partition holds the highest durably-processed
   sequence number; a concurrent/duplicate delivery loses the CAS and is
   skipped, never double-applied.

## Run

```bash
bash examples/retail-order-pipeline/run.sh
```

Exit contract: 0 pass (green or registered divergence) / 1 probe failure /
2 substrate down / 3 loud skip.

Endpoint overrides (all default to the canonical substrate):

| Env | Default |
|---|---|
| `SMALT_EX2_TLS` | `https://localhost:9444` |
| `SMALT_EX2_AMQP_PORT` | `5672` |
| `SMALT_EX2_EH_PORT` | `5673` |
| `SMALT_SB_SHARED_KEY` | per-host dev key (`scripts/dev_env.sh` formula) |
| `NODE_EXTRA_CA_CERTS` | `.smalt/tls/ca-cert.pem` |

## Standing (as of 2026-10-19)

- GREEN: `eh-partitions-pinion`, `eh-partition-pinned-send`,
  `cosmos-order-etag-cas`, `eh-checkpoint-exactly-once`
  (100/100 applied, 0 duplicates, 50/50 per partition).
- REGISTERED-DIVERGENCE#KD-115: all four Service Bus plain-queue legs —
  the substrate's plain-queue receiver dispatches no deliveries on flow
  credit (attach+flow+CBS+send all succeed), so intake/defer/lock-renewal/
  DLQ are witnessed-not-exercisable over the official SDK. The harness
  reproduces the KD-115 falsifier exactly and records the divergence rather
  than a fake pass. Close condition lives in
  `docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` (KD-115); when it closes these
  legs flip to full assertions with zero harness changes.
