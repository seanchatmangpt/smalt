# T-08 — Service Bus: native dead-letter queue, scheduled messages, deferral

- window: v26.10.28 · maps-to: Topaz v1.12 "Service Bus — DLQ · scheduled messages · message deferral" · verdict-at-open: **PARTIAL**
- size: **L** · depends-on: — · parity-leg: sb suite (unblocks T-16)
- unblocks: T-16 (chained DLQ forwarding)

## current state (evidence)

No native SB dead-lettering — `lib/smalt/sb_rules.ex:104`: "any filter
matches -> admit; otherwise skip (never DLQ here)". The only DLQ lives in
the EventGrid→SB ingestion bridge (dead-letters to a blob container,
`lib/smalt/messaging/event_grid.ex`). No scheduled-enqueue or
sequence-number deferral surface in the broker
(`lib/smalt/messaging/amqp_broker.ex`, `sb_rules.ex`).

## scope

1. **DLQ**: every queue gets `<queue>$deadletterqueue` and every
   subscription `<topic>/Subscriptions/<sub>/$deadletterqueue` as real
   AMQP-receivable subqueues; `deadLetterMessage` (settlement outcome)
   moves the message with `DeadLetterReason`/`DeadLetterErrorDescription`;
   filter-no-match optionally dead-letters (config key, default match real
   Azure: no-match does NOT dead-letter by default).
2. **Scheduled**: `x-ms-scheduled-enqueue-time` (SDK
   `createMessage`+`scheduleMessage` / `sendScheduledMessages`) — message
   becomes receivable only at/after the timestamp; cancellation by
   sequence number.
3. **Deferral**: `deferMessage` sets the deferral flag; receive requires
   `receiveDeferredMessages(sequenceNumbers)`; `ReceiveSequenceNumber`
   surfaces on messages.

## non-goals

- Forwarding rules between DLQs (that is T-16, deliberately sequenced
  after this lands).

## Definition of Done — the Azure developer's view

With `@azure/service-bus` against smalt, your existing error path just
works: `receiver.deadLetterMessage(msg, { deadLetterReason: "poison" })`
moves the message, and your ops receiver on
`myqueue/$deadletterqueue` (or the subscription DLQ) receives it with the
reason and original application properties intact. You schedule with
`sendScheduledMessages([{body}], Date.now()+60_000)` — receivers see
nothing for a minute, then receive exactly on time, and
`cancelScheduledMessage` kills one before it fires. You defer a message
and pull it later with `receiveDeferredMessages([seq])` using the sequence
number you logged at receive time — identical control flow to your
production Azure code.

## receipts required

AMQP transcript courts: DLQ round-trip (queue + subscription), scheduled
receive-timing fence (poll-observable, zero-sleep compliant), deferral
round-trip, no-match default behavior receipt.
