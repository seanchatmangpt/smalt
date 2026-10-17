# Receipt — canonical (Canonical.write riders projection fence)

- **Subject:** `/Users/sac/smalt` @ main, HEAD `650a8ff`
- **Standing:** PASS
- **Date:** 2026-10-17

## Subject files

- `lib/smalt/projection/canonical.ex` (Canonical.write surface)
- `test/canonical_projection_test.exs` (fence)

## Verification (2026-10-17, I2 lane, unedited output)

```
$ mix test test/canonical_projection_test.exs ; echo "exit=$?"
12:40:16.722 [info] [amqp] eh listener bound on port 50173

Finished in 0.4 seconds (0.00s async, 0.4s sync)
20 tests, 0 failures
exit=0
```

## Non-vacuity

The suite boots `Smalt.Application` on a fully pinned free-port set
(`mix test --no-start`) and exercises the canonical PUBLIC projection
surface end to end: writes are idempotent and byte-identical on replay
(a non-idempotent write flips the byte-compare arm), and the projection
asserts on real written state, not call counts. The port-pinning arm
itself can exit 1 — a concurrent lane holding a pinned port fails loudly,
never silently skips.
