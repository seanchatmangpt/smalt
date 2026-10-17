# R34: AMQP flow credit

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/messaging/amqp/` (session flow)

## Claim

Flow-credit accounting repaired (no credit leak / no double-grant).

## Re-run evidence

```
$ mix test test/amqp/queue_store_test.exs test/amqp/management_rpc_test.exs test/amqp/flow_credit_test.exs
.....................................................................
Finished in 1.3 seconds (0.3s async, 1.0s sync)
69 tests, 0 failures (10 excluded)
```

## Verdict

PASS. 69/0 (10 excluded = default-excluded :amqp_wire tier). flow_credit_test green inside
the batch.
