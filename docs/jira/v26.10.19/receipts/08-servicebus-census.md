# Receipt — 08-servicebus-census (lane b11, Service Bus SDK census)

- **Subject**: /Users/sac/smalt working tree @ b847c02 (uncommitted lane files:
  verification/ts/census.test.cjs, verification/ts/sb-extra.probe.cjs,
  verification/ts/.logs/.gitkeep; this receipt)
- **Date**: 2026-10-19
- **Status**: ALIVE — census 11/11 green over real SDK on live wire; sb-extra
  supplement 2/3 pass + 1 typed broker divergence (UNSUPPORTED, honest FAIL).

## Census

`node --test verification/ts/census.test.cjs` — the file self-boots a PRIVATE
substrate (block b11, ports 39110-39115, auth :enforce, ts-run.mjs boot-eval
shape; SDK 7.10.0 from verification/ts/node_modules) and sweeps it down at
exit. It registers 11 probes, fail-closed, zero skips:

```
✔ probe: authentication (25.4ms)
✔ probe: bytes (412.6ms)
✔ probe: exclusive-session (51.2ms)
✔ probe: renewal-peek (41.2ms)
✔ probe: abandon-complete (7.1ms)
✔ probe: stale-handle (15187.7ms)
✔ probe: dead-letter (19.0ms)
✔ probe: dlq-properties (9.8ms)
✔ probe: ordered-session (7.6ms)
✔ probe: lock-duration (2167.7ms)
✔ probe: deferred-receive (16.9ms)
✔ service bus census: 11 probes, fail-closed, 0 failures, 12 tests total incl. root
ℹ tests 12  pass 12  fail 0  (duration_ms 22251)
```

Probe set (ported from the v26.10.14 lane-08 census @ 518b31a): queue
create/lock-schedule via ServiceBusAdministrationClient (PT15S / PT2S
lockDuration), send/receive/complete, binary byte-exactness, session
exclusivity + renew, $management peek + renew-session-lock, abandon
redelivery deliveryCount, 15 s stale-handle LockLost, PT2S lock-duration
LockLost, DLQ reason/description + custom app props, ordered session FIFO,
deferred receive-by-sequence-number.

## Supplement (verification/ts/sb-extra.probe.cjs — 3 probes)

```
FAIL scheduleMessage: NotImplementedError: UNSUPPORTED_OPERATION
PASS receiveAndDelete-delivery
PASS acceptNextSession-no-session
SUMMARY pass=2 fail=1
```

`scheduleMessage` is a REAL witnessed divergence, not a probe bug: the broker
$management op table (lib/smalt/messaging/amqp/management_rpc.ex moduledoc)
has no schedule-message operation — unknown op answers 501
UNSUPPORTED_OPERATION, which core-amqp maps to NotImplementedError
(amqp:not-implemented). Typed UNSUPPORTED, consistent with the V261014-08
typed-UNSUPPORTED family. Not fixed in this lane (no lib/ edits allowed);
candidate KD row for the register (schedule-message -> 501
UNSUPPORTED_OPERATION).

## Commands / exits

- `node --check verification/ts/census.test.cjs` — OK.
- `node --check verification/ts/sb-extra.probe.cjs` — OK.
- `node --test verification/ts/census.test.cjs` — tests 12, pass 12, fail 0
  (~22 s incl. 15 s lock-expiry schedule wait; substrate booted healthy <5 s).
- `node verification/ts/sb-extra.probe.cjs` — exit 1 (honest FAIL on
  scheduleMessage), 2/3 pass.
- Teardown verified: `lsof -iTCP:39110-39115 -sTCP:LISTEN` empty after both
  runs (sweep-down on exit; bounded polls only, no coordination sleeps).

## Findings

- `scheduleMessage` unsupported -> typed 501 UNSUPPORTED_OPERATION (witnessed
  over real SDK; register as KD row or pin in WIRE_PARITY UNSUPPORTED family).
