# Receipt — R160b (duplicate sequence-number dedup in deferred batches)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/messaging/amqp/queue_store.ex:377` (R160b marker): duplicate sequence
  numbers in a deferred batch are deduplicated — one message, one lock, one
  delivery.
- `lib/smalt/messaging/amqp/queue_store.ex:700` (R160b / SHIM-COURT marker).
- Tests: `test/amqp/queue_store_test.exs:645`
  ("receive_deferred duplicate sequence numbers (R160b)").

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/amqp/queue_store_test.exs
43 tests, 0 failures
```

## W10 re-run (2026-10-16, docs lane W10, `_build-lane204`)

```
$ MIX_BUILD_ROOT=_build-lane204 mix test test/amqp/queue_store_test.exs
43 tests, 0 failures
```

R160b describe at queue_store_test.exs:645 holds. Standing: PASS.
