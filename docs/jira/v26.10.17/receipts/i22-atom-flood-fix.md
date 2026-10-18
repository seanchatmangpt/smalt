# i22 — amqp-atom `:closed` log flood fix

Standing: PASS (offline + wire amqp tiers green; red→green witnessed)

## Defect

`Smalt.Amqp.AtomBridge.serve/2` logged a debug line for every failed request
read, including `:closed`. `:closed` is terminal for the socket — the caller
(`lib/smalt/messaging/amqp/connection.ex:217-219`) closes and stops the
connection — so the line carried zero bits and, during court teardown socket
storms, flooded the logger: `tmp/court-x2-v17-run1.log` holds **35,547**
`[amqp-atom] request read failed: :closed` lines (14:49-14:50, bursts of
~390 lines in a single millisecond, e.g. 439 at 14:49:24.656), driving the
Logger `:drop`/`:sync` flips in the co-location report.

## Fix

`lib/smalt/messaging/amqp/atom_bridge.ex` `serve/2`: `:closed` now exits
silently (terminal); the typed debug line is retained for non-terminal read
errors (`:too_large`, `:bad_content_length`, recv `:timeout`).

## Red→green witness

Pre-fix repro (peer closes mid-request; MIX_BUILD_ROOT=_build-ft-r13,
MIX_ENV=test `mix run --no-start /tmp/i22_flood_repro.exs`):

```
REPRO_LOG_LINES=1

12:13:04.660 [debug] [amqp-atom] request read failed: :closed
```

Post-fix (same harness + `:too_large` retention check,
`/tmp/i22_green.exs`):

```
CLOSED_LOG_LINES=0
TOO_LARGE_LOGGED=true
```

## Verification

Offline tier:

```
$ MIX_BUILD_ROOT=_build-ft-r13 mix test test/amqp/
Finished in 29.8 seconds (12.1s async, 17.7s sync)
331 tests, 0 failures (45 excluded)
```

Wire tier (exercises the reader over real handshakes; atom_bridge tests are
in the offline tier, wire tier adds :amqp_wire):

```
$ MIX_BUILD_ROOT=_build-ft-r13 mix test test/amqp --include amqp_wire   # run 2
Finished in 47.7 seconds (12.1s async, 35.5s sync)
376 tests, 0 failures

$ MIX_BUILD_ROOT=_build-ft-r13 mix test test/amqp --include amqp_wire   # run 3
Finished in 46.3 seconds (12.6s async, 33.6s sync)
376 tests, 0 failures
```

Wire run 1 exited with 2 failures whose names were not captured (tail-only
capture); runs 2 and 3 are both clean, so the pair did not reproduce —
recorded as an unattributed single-run flake, not a session regression.
Post-fix wire run 3 contains 3 `[amqp-atom] request read failed: :timeout`
lines (typed, bounded) vs 35,547 `:closed` lines in the pre-fix court log.

No git (per work order).
