# WS-9 receipt — pure-Azure data-plane client layer (workspace/lib/azure)

- date: 2026-10-15
- lane: WS-9
- repo: /Users/sac/smalt (branch main, shared working tree, lane-disjoint paths)
- subject: workspace/lib/azure/{blob-export,sb-telemetry,cosmos-manifest,eh-stream}.ts,
  workspace/lib/azure/README.md, workspace/scripts/azure-dataplane-probe.mjs,
  this receipt. (Plus a merged README covering co-located lane WS-8's ARM modules.)
- authority: WS-9 lane work order (v26.10.14 wave)
- falsifier: a probe step failing for a reason OTHER than the documented
  WIRE_PARITY limitations (or a PASS that later fails on a live substrate)
  falsifies the lib's witness claims.

## What ran live (final full pass, own substrate booted under `flock -x /tmp/smalt-substrate.lock`, canonical ports 8443/5672/5673/9443, probe exit 1 = 3 failed steps, all three documented substrate limitations)

```
[ws9] PASS blob/exportReceiptBundle {"containerName":"receipts-ws9-1792108446330","bundleBlobName":"receipt-bundle.json","manifestBlobName":"export-manifest.json","uploadStatus":201,"overwriteRejected":true,"overwriteStatus":409,"etag":"\"b3414300cda48e43593ca4ad668e7616\"","readBack":"equal","bytes":181}
[ws9] PASS cosmos/upsertManifest x2 {"statuses":[201,201]}
[ws9] PASS cosmos/readManifests (SELECT * FROM c) {"query":"SELECT * FROM c","matched":1,"of":2}
[ws9] PASS sb/ensureQueue ws9-plain-1792108446403 {"status":201}
[ws9] PASS sb/ensureQueue(session) ws9-sessions-1792108446403 {"status":201}
[ws9] PASS sb/sendTelemetry {"sent":"telemetry-1792108446422-🌊"}
[ws9] FAIL sb/receiveAndComplete: no delivery on receiver-link flow credit (documented WIRE_PARITY limitation)
[ws9] FAIL sb/session probe: sessionId not preserved: undefined
[ws9] PASS eh/sendMissionEvents {"sent":2}
[ receipts-ws9 container/blob re-download equal (readBack: equal)
```

## Per-plane standing

| plane | standing | witness |
|---|---|---|
| Blob WORM export | ALIVE | upload 201, overwrite 409, read-back byte-equal — real 409 on the wire, on every run (3 runs, 2 substrates) |
| Cosmos manifests | ALIVE | upsert 201/201, `SELECT * FROM c` query 200 with real result set (matched 1 of 2, pk filter client-side) |
| SB queues + send | ALIVE | namespace + queue PUT 201 (session and plain), SDK send resolves with multibyte payload |
| SB plain receive | BLOCKED (substrate) | zero deliveries on receiver-link flow credit — `Smalt.Amqp.Connection` deliver path never dequeues (docs/WIRE_PARITY.md); witnessed identically on 2 substrate builds |
| SB session receive | PARTIAL_ALIVE (substrate) | session link delivers, body "session-payload" round-trips; `sessionId` not preserved (undefined); on the borrowed ts5 substrate the delivery was a raw undecorated rhea message (no `complete()`) |
| EH producer send | ALIVE (link-level) | batch of 2 accepted by SDK send path |
| EH consumer receive | BLOCKED (substrate) | 0 events observed; 5673 lane PARTIAL — `/eventhubs/` addresses route to QueueStore semantics, no `$management` responder (docs/WIRE_PARITY.md) |

## Divergences witnessed (recorded, NOT fixed — substrate lib/ is not this lane's)

1. SB plain-queue receive: send resolves, receiver gets no delivery.
2. SB session receive: delivery happens, body round-trips, `sessionId` lost;
   delivery decoration is substrate-build-dependent (raw rhea message on one
   build, SDK-decorated on another — uncommitted lib/smalt edits across lanes).
3. EH 5673 lane PARTIAL: send works, consumer bootstrap/receive does not.
4. Cosmos: `PUT /dbs/:db` → 400 (db control-plane route refuses), while
   `POST /dbs/:db/colls` → 201 works; docs engine permissive about parent db.
   One earlier substrate build mounted neither control-plane route.
5. SDK-version traps fixed in MY files (witnessed then fixed): `container.item(...).upsert`
   is not a function on @azure/cosmos 4.10.1 (use `container.items.upsert`);
   EH v6 `startPosition: { earliest: true }` rejected (use
   `{ offset: earliestEventPosition }`); SB ARM PUTs must not inherit an
   api-version into mid-path URLs (400 InvalidApiVersionParameter).
6. Fleet-level observation (not lane work): /tmp/smalt-substrate.lock had a
   leaked holder — an orphaned beam.smp (pid 83744, listeners closed ~27 min)
   retained the exclusive lock via an inherited fd while 7 lanes queued.
   Killed after verifying all its listeners were closed. The boot wrapper
   (flock → reuse-live → boot) is left at /tmp/ws9-boot-and-probe.sh.

## Auth shapes (witnessed, from test/sdk-smoke/*.cjs + test/sdk-full/ts-reality.test.mjs)

- Blob: StorageSharedKeyCredential("smaltacct", "smaltacct-key") — real wire
  signing; STS Bearer not injectable on plain-HTTP storage (OAuth needs https).
- Cosmos: master key = any 64-char hex (anonymous substrate).
- SB/EH: emulator connection strings, SharedAccessKey seeded at boot
  (SMALT_WS9_SB_SHARED_KEY); EH requires EntityPath; queues via raw ARM PUT.

## Replay

```sh
cd /Users/sac/smalt
flock -x -w 1200 /tmp/smalt-substrate.lock /tmp/ws9-boot-and-probe.sh
# or against a live substrate:
NEXT_PUBLIC_SMALT_EGRESS=http://127.0.0.1:8443 \
SMALT_WS9_SB_SHARED_KEY=<boot key> node \
  workspace/scripts/azure-dataplane-probe.mjs
```

Standing: PARTIAL_ALIVE — 7 of 10 probe steps pass with real wire witnesses
(blob WORM 409, cosmos query 200, SB send, SB queues, EH send); the 3
non-passing steps are substrate-side BLOCKED/PARTIAL per docs/WIRE_PARITY.md,
witnessed identically across two substrate builds, and owned by substrate
lanes, not WS-9.
