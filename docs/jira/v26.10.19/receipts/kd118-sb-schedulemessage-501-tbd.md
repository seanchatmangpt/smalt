# Receipt — KD-118 scheduleMessage -> 501 UNSUPPORTED_OPERATION (typed)

Standing: **UNKNOWN** (witnessed, honest-fail; typed UNSUPPORTED, no fix)
Context: solo
Context note: sb-extra probe, substrate solo boot.
Lane: kd-registrar; no lib/ edits.

## Divergence

`ServiceBusClient` scheduleMessage is not implemented by the broker: the
$management op table (lib/smalt/messaging/amqp/management_rpc.ex moduledoc)
has no schedule-message operation; unknown op answers typed
501 UNSUPPORTED_OPERATION, which core-amqp maps to NotImplementedError
(amqp:not-implemented).

## Witnessed evidence (verbatim)

`docs/jira/v26.10.19/receipts/08-servicebus-census.md` (supplement,
verification/ts/sb-extra.probe.cjs, 2026-10-19):

```
FAIL scheduleMessage: NotImplementedError: UNSUPPORTED_OPERATION
PASS receiveAndDelete-delivery
PASS acceptNextSession-no-session
SUMMARY pass=2 fail=1
```

Runner honest-fail: `node verification/ts/sb-extra.probe.cjs` exit 1,
2/3 pass. Typed-UNSUPPORTED family, consistent with the V261014-08 family.

## Close condition

Either (a) implement schedule-message in the $management op table, or
(b) pin it typed-UNSUPPORTED in docs/WIRE_PARITY.md. Falsifier for (a):
SDK scheduleMessage resolves -> message delivers at the scheduled time ->
receive+complete passes.
