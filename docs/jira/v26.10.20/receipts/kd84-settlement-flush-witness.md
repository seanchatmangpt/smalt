# KD-84 witness — settlement flush on receiver close

- **KD row**: `KNOWN_DIVERGENCES.md` KD-84 — "SB settlement race on receiver close" (OPEN)
- **Standing**: **PASS** (witness; flip-eligible) — falsifier met 4/4 (3 DLQ rounds + unsettled-close redelivery)
- **Date / lane**: 2026-10-20, lane W13-G (witness-only, no lib edits, no git)
- **Subject**: private substrate block **b13** (ports 39030–39035), enforce auth, private
  `SMALT_SB_SHARED_KEY`, swept down at exit (lock FREE after)
- **Harness**: `/tmp/w13g/kd84-witness.cjs` (pattern: `verification/ts/sb-extra.probe.cjs`
  bootPrivate; real `@azure/service-bus` 7.10.0 from `verification/ts/node_modules`; no mocks —
  real AMQP wire, real broker settlement; 240s watchdog)
- **Court subject note**: the row's evidence cell names
  `workspace/test/servicebus_dataplane.test.ts` test "04: dead-letter routing" as the (allegedly
  deleted) court subject. Correction: that file **still exists on disk** — 64f6099 deleted the
  legacy `test/` suite, not the workspace courts. Test 04 currently keeps the receiver OPEN
  across the DLQ read (KD-84-avoidance comment in-line), so it never exercised the raced
  window; this lane witnesses the raced window directly.

## Falsifier, literally

Row text: "deadLetterMessage → receiver.close() → DLQ peek (subQueueType deadLetter) returns
the message".

Probe legs (queue `lockDuration: PT2S`, peek-lock mode, retryOptions maxRetries=0):

1. **kd84-deadletter-flush-close r1/r2/r3** — send → `receiveMessages(1)` →
   `deadLetterMessage(..., reason kd84-w13g-rN)` → **immediate `receiver.close()`** (the exact
   raced window from the original lane-522 witness) → fresh DLQ receiver
   (`subQueueType: "deadLetter"`, `maxAutoLockRenewalDurationInMs: 0`) → receive 1.
   **3/3 PASS**: message present in DLQ, payload bytes intact, `messageId` intact,
   `deadLetterReason` round-trips.
2. **kd84-unsettled-close-redelivery** — send → receive (peek-lock) → close with **no
   settlement at all** → fresh receiver → message **redelivered** (lock released on link
   detach; `lib/smalt/messaging/amqp/connection.ex:505` releases the held session lock on
   receiver-link detach — the mechanism the row's fix direction names). **PASS**: never
   "neither queue nor DLQ".

## Run output (verbatim)

Run 2 (qualifying run, exit 0):

```
PASS kd84-deadletter-flush-close r1
PASS kd84-deadletter-flush-close r2
PASS kd84-deadletter-flush-close r3
PASS kd84-unsettled-close-redelivery
SUMMARY pass=4 fail=0
```

JSON line emitted by run 2:

```
JSON [{"name":"kd84-deadletter-flush-close r1","verdict":"PASS","detail":""},{"name":"kd84-deadletter-flush-close r2","verdict":"PASS","detail":""},{"name":"kd84-deadletter-flush-close r3","verdict":"PASS","detail":""},{"name":"kd84-unsettled-close-redelivery","verdict":"PASS","detail":""}]
```

### First-run honesty note

Run 1 (same falsifier, same substrate boot) returned `SUMMARY pass=1 fail=3`: all three
failures were `DLQ payload mismatch: {"type":"Buffer",...}` — a **probe-side assertion bug**
(the probe compared the body against a string while the SDK delivered the raw AMQP
value-section buffer), not a broker failure. The payload bytes were present in every DLQ
delivery of run 1 as well; the settlement flush succeeded in all 6 DLQ rounds across both
runs. Reported per lane law (a run with errors says so). Run 2 corrects the assertion
(messageId + deadLetterReason + latin1 body decode) and is the qualifying run.

## Command block

```
node /tmp/w13g/kd84-witness.cjs        # run 1 → exit 1 (probe-side assertion bug, pass=1 fail=3)
node /tmp/w13g/kd84-witness.cjs        # run 2 → exit 0, SUMMARY pass=4 fail=0
# each run internally: scripts/substrate-ctl down --block b13 --mode sweep (exit 0, swept clean)
```

## Observations (not new KD rows — registrar's call)

- Queue/DLQ delivery bodies arrive as the **raw AMQP described value-section buffer**
  (descriptor prefix `0x00 0x53 0x70` …), so `receivedMessage.body` is not a decoded string.
  SDK still delivers and settles; the falsifier keys on messageId + deadLetterReason. Distinct
  from KD-115 (zero delivery) and KD-116 (session settle methods). Named for the registrar.
- `deadLetterReason` round-trips end to end.

## Verdict

KD-84's falsifier is met on the real SDK over real AMQP against a real booted substrate.
**Flip-eligible witness for KD-84**: `scripts/kd_flip.py --apply` may flip the row gated on
this receipt's mtime (the row's fix-direction seam
`lib/smalt/messaging/amqp/connection.ex` currently carries no `# KD-COVERS: KD-84` shim
marker — if the flip requires one, this receipt names the exact missing subject: a
KD-COVERS-marked connection.ex disposition-flush landing; the observed semantics already
satisfy the row's stated close condition).

**Standing: PASS** (witness, flip-eligible). Harness preserved at `/tmp/w13g/kd84-witness.cjs`;
block b13 swept down.