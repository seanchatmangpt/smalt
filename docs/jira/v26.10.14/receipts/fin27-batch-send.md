# fin27: eh-run `batch-send` probe drift fix — receipt

Lane: fin27 (v26.10.14). Scope: `test/sdk-smoke/eventhubs.test.cjs` only
(probe/test code). No commits, no lib edits.

## Drift (witnessed)

`batch.canAdd is not a function` — the probe called `batch.canAdd()`, which
does not exist on @azure/event-hubs 6.0.4's `EventDataBatch`
(`test/sdk-full/node_modules/@azure/event-hubs/dist/*/eventDataBatch.d.ts`:
surface is `tryAdd` / `count` / `sizeInBytes` / `maxSizeInBytes`; no `canAdd`
in any shipped variant). The probe was written against a non-existent older
API. Same drift class on probe 3: `{ startPosition: { earliest: true } }` is
not a valid 6.0.4 `EventPosition` (TypeError at
`eventPosition.js validateEventPositions` — "Pass an object with either of
offset, sequenceNumber or enqueiepedOn properties set"), witnessed on the
first run.

## Fix (test code only)

1. `batch-send`: replaced the `canAdd` assert with **stronger** capacity
   checks: `assert.ok(batch.sizeInBytes > 0, "BATCH_SIZE_MUST_BE_POSITIVE")`
   plus a negative capacity case — `createBatch({ maxSizeInBytes: 64 })`, then
   `tryAdd` of a 4096-byte body must return `false`
   (`TRYADD_MUST_REJECT_OVERSIZE_EVENT`) and `count` must stay 0
   (`REJECTED_EVENT_MUST_NOT_BE_COUNTED`). Real delivery verification kept:
   count===3, tryAdd x3, `sender.sendBatch(batch)` over the live wire.
2. `subscribe-earliest`: `{ earliest: true }` → `earliestEventPosition`
   (SDK-exported `offset: "-1"`), assertions untouched.

## Run (real execution)

`SMALT_SDK_ROOT=test/sdk-full/node_modules node test/sdk-smoke/eh-run.mjs`
(booted its own substrate on 39172/39173/39444; @azure/event-hubs 6.0.4,
node v26.10.0):

- **AFTER fix**: `get-properties` PASS (partitionIds=["0","1"]);
  **`batch-send` PASS** (`sendBatch ok: 3 events` — real wire delivery);
  `subscribe-earliest` FAIL — but no longer drift: events now **arrive, in
  order, on the expected partition**; bodies land as raw AMQP-described
  section bytes (`00 53 70 45 00 53 72 d1 ... a0 30` envelope + the JSON
  body), i.e. the opaque-Buffer state S-2's own receipt documents as its
  BEFORE witness for KD-18 (`extract_body_section/1` re-emit). The probe's
  `deepEqual` on exact body strings correctly refuses to pass, and was NOT
  weakened. Verdict: substrate-side receive-path divergence, pending — the
  S-2 KD-18 decoded-body re-emit is not effective on the path this probe
  exercises (get-properties passes, so KD-19 mgmt shim is effective).

## Verdict

- `batch-send`: **PASS** (drift fixed, delivery verified on the wire,
  capacity semantics asserted stronger than the drifted `canAdd` line).
- `get-properties`: PASS (post-S-2, as expected).
- `subscribe-earliest`: FAIL/pending — substrate body-encoding divergence on
  the EH receive path (raw encoded section bytes delivered as body). Probe
  assertions intact; blocks on a lib-side fix, outside this lane's boundary.
