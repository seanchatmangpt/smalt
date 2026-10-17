# Receipt — R142 (scheduled-enqueue-time type guard + scheduled DLQ fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject files

- `lib/smalt/messaging/amqp/queue_store.ex:261` (R142 marker): a non-integer or
  negative `:scheduled_enqueue_time` falls back to immediate availability
  instead of poisoning the row.
- `lib/smalt/messaging/amqp/queue_store.ex:797` (R142 marker): a still-`:scheduled`
  row is refused for deadlettering (typed fence, not silent DLQ).
- Tests: `test/amqp/queue_store_test.exs:104` and `:329` (R142 cases:
  "malformed scheduled_enqueue_time falls back to immediate availability (R142)",
  "deadlettering a still-scheduled message is refused (R142)").

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ MIX_BUILD_ROOT=_build-w7docs mix test test/amqp/queue_store_test.exs
43 tests, 0 failures
```

(The session-claimed count for R142 alone was 41/0; the suite has since gained
R150/R160b cases and now carries 43 tests — current disk truth is 43/0.)
