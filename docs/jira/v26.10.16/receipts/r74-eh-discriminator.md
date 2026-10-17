# R74: Event Hubs discriminator

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/messaging/event_hubs.ex` (+185 diff)

## Claim

EH discriminator/endpoint disambiguation repairs landed.

## Re-run evidence

```
$ mix test test/amqp/event_hubs_test.exs
Finished in 0.4 seconds (0.00s async, 0.4s sync)
22 tests, 0 failures (2 excluded)
```

## Verdict

PASS. 22/0 — also clean this run (the W2-era flaky failures noted in r13 did not
reproduce).
