# Receipt — KD-118 scheduleMessage -> 501 UNSUPPORTED_OPERATION (typed)

Standing: **ALIVE** (witnessed fix; close condition (a) landed)
Context: solo
Context note: sb-extra probe, substrate solo boot (private block b11).
Lane: ERRC lane c2 (scheduleMessages); lib edits disclosed below.

## Witnessed fix (2026-10-19, this lane)

`com.microsoft:schedule-message` + `com.microsoft:cancel-scheduled-message`
landed in the $management op table (lib/smalt/messaging/amqp/management_rpc.ex,
`# KD-COVERS: KD-118`); the embedded rhea message is decoded via
FrameCodec.decode_message, scheduled time rides the embedded
`x-opt-scheduled-enqueue-time` message annotation, rows persist via
QueueStore's existing `:scheduled` state (claim_candidates delivers when the
time passes; no sweeper change). Entity resolution fallback added in
connection.ex handle_management: when associated-link-name does not resolve
(sender link still attaching — scheduleMessages fired first), the entity is
resolved from the per-entity mgmt node address "<entity>/$management"
(find_mgmt_node_addr/3).

### Verbatim witness (`cd verification/ts && node sb-extra.probe.cjs`)

```
PASS scheduleMessage
PASS receiveAndDelete-delivery
PASS acceptNextSession-no-session
SUMMARY pass=3 fail=0
```

(The probe process then hit the pre-existing post-summary event-loop hang
documented at sb-extra.probe.cjs:188 — the 180s watchdog downs the block and
exits 3; the verdict lines above are the falsifier signal. The honest-fail
echo "FAIL scheduleMessage: NotImplementedError: UNSUPPORTED_OPERATION" no
longer appears.)

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
