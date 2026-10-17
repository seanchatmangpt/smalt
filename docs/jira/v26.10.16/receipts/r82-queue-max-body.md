# R82: AMQP max_body clamp

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/messaging/amqp/queue_store.ex` (`max_body` — only max_body hit in lib/)

## Claim

Oversized-message handling clamps via `max_body` with a typed AMQP close
(`amqp:link-message-size-exceeded`) instead of a silent socket drop.

## Re-run evidence

```
$ python3 gates/queue_capacity_gate.py; echo exit=$?
PASS queue-capacity/fixture:silent-socket-drop (refused: ['FAIL broker closes with amqp:link-message-size-exceeded (got socket-closed)', "FAIL close description names :capacity (got 'no close frame')"])
queue-capacity: receipt .../queue-capacity-receipt.json verdict=PASS
exit=0
```

## Verdict

PASS. The gate's positive path asserts the typed close; the shown FAIL lines are the
mutation fixture (socket-drop/no-close-frame observation correctly REFUSED), exit 0.
Queue suite green: 69/0 (see r64/r66/r70/r91 receipt).
