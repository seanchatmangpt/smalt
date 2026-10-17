# Receipt — R150 (DLQ-full parked rows excluded from receive)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/messaging/amqp/queue_store.ex:713` (R150 / SHIM-COURT marker):
  DLQ-full parked rows (`:deferred` + `dlq_full_park`) are excluded from the
  deadletter-retry path when DLQ capacity frees.
- `lib/smalt/messaging/amqp/queue_store.ex:700` area: receive-by-sequence must
  not deliver the parked poison message.
- Tests: `test/amqp/queue_store_test.exs:595-640`
  ("receive_deferred vs DLQ-full parked messages (R150)").

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

The session-cited 42/0 predates the R160b dedup tests landing in the same
suite (describe at queue_store_test.exs:645) — 43 is the current count; the
R150 park-exclusion fence (describe at :595, comment at :612) holds. PASS.
