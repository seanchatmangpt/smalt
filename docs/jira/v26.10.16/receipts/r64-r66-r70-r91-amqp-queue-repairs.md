# R64/R66/R70/R91: AMQP queue repairs (sweep max-delivery, disposition errors, scheduled state, sweeper completeness)

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/messaging/amqp/queue_store.ex` (+245), `lib/smalt/messaging/amqp/sweeper.ex` (+9),
`lib/smalt/messaging/amqp/management_rpc.ex`

## Claim

Queue-store repairs: delivery-count clamping on sweep, typed disposition error codes,
scheduled-message state transitions, sweeper completeness.

## Re-run evidence

```
$ mix test test/amqp/queue_store_test.exs test/amqp/management_rpc_test.exs test/amqp/flow_credit_test.exs
Finished in 1.3 seconds (0.3s async, 1.0s sync)
69 tests, 0 failures (10 excluded)
```

Companion gate (queue-capacity, includes the max_body clamp):

```
$ python3 gates/queue_capacity_gate.py; echo exit=$?
PASS queue-capacity/fixture:silent-socket-drop (refused: ['FAIL broker closes with amqp:link-message-size-exceeded (got socket-closed)', ...])
queue-capacity: receipt .../queue-capacity-receipt.json verdict=PASS
exit=0
```

## Verdict

PASS. 69/0 suite + queue-capacity gate exit 0 (mutation detected: socket-drop instead of
typed close is caught). 10 excluded = default-excluded :amqp_wire tier.
