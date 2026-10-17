# Receipt — R128 + R129 + R132 (DLQ-full parking, session-gate bypasses, sweeper boot validation)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W6 wave-5 docs lane)

## Subject files (shared-suite bundle)

- `lib/smalt/messaging/amqp/queue_store.ex:733`/`:878` — R128: a DLQ-full
  condition parks the maxed message as `:deferred` (`dlq_full_park`),
  unclaimable, never a silent drop
- `lib/smalt/messaging/amqp/connection.ex:636`/`:2179`/`:2200` — R129: two
  session-gate bypasses closed (trailing-slash shadow queue key; unfiltered
  receiver on a requiresSession queue); dedicated court
  `test/amqp/r129_session_gate_test.exs`
- `lib/smalt/messaging/amqp/sweeper.ex:53` — R132: `tick_ms` validated
  fail-closed at boot (non-positive → refused, not a zero-interval spin)

## Verification (2026-10-16, W6 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/queue_store_test.exs test/amqp/r129_session_gate_test.exs test/amqp/event_hubs_test.exs test/amqp/broker_facade_test.exs
67 tests, 0 failures (5 excluded)

$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/queue_store_test.exs
41 tests, 0 failures

$ MIX_BUILD_ROOT=_build-w6docs mix test test/amqp/r129_session_gate_test.exs --include amqp_wire
2 tests, 0 failures
```

(The r129 court is tagged `:amqp_wire`; bare invocation reports
"All tests have been excluded. 0 tests, 0 failures (2 excluded)" — a bare
green would have been vacuous, so the receipt embeds the `--include amqp_wire`
run. Per-file counts: queue_store 41/0, event_hubs 22/0, broker_facade 4/0.)
