# KD-155 final close witness: SDK deleteQueue on the recycled substrate

- **Date**: 2026-10-21
- **Lane**: KD155SDK (bench-runner), repo `/Users/sac/smalt`
- **Context**: pair
- **Subject**: real `@azure/service-bus` `ServiceBusAdministrationClient`
  7.10.0 (`/Users/sac/smalt/verification/ts/node_modules/@azure/service-bus`)
  against the live recycled substrate (substrate-status: ports 9443/9444/
  5672/5673 UP, pid 8877, lock FREE; never restarted in-lane).
- **Probes**: `/Users/sac/smalt/tmp/kd155-witness.cjs` (SDK leg, unchanged
  from the open-witness run) and `/Users/sac/smalt/tmp/kd155-raw-put-delete.cjs`
  (raw-wire leg, written in-lane to correct the stale POST-create shape in
  `kd155-raw-delete.cjs` — creation on this face is PUT, and the stale
  probe's POST got 405 so its DELETE hit 404 on a nonexistent queue).

## Liveness preflight (loud-SKIP contract; no restart)

First run without the repo CA on NODE_EXTRA_CA_CERTS printed a loud
`[SKIP] substrate down: arm=true tls=false` and exited 3 — probe-env defect
(missing CA), not substrate state: `curl -sk` against the same URL returned
`HTTP/2 401`. Re-run with `NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem`
proceeded. No substrate restart, no eviction.

## SDK leg (node, exit 0)

```
[LIVE] substrate up: arm=true tls=true
[STS] bearer minted (1291 chars)
[AUTH] SharedKey per-host accepted
[CREATE-OK] queue=kd155w-g2sd3w name=queues/kd155w-g2sd3w maxDeliveryCount=10
[DELETE-OK] returned: "[object Object]"
[GET-AFTER-DELETE] gone (status=404 msg=Detailed error message information not available. Look at the 'code' property on error for more information.)
[LIST-AFTER-DELETE-FAIL] Detailed error message information not available. ...
[DONE] target queue was kd155w-g2sd3w
EXIT=0
```

`deleteQueue` succeeded (exit 0, no RestError, no `HPE_INVALID_CONSTANT` —
the open witness's failure is gone) and `getQueue` after delete answers
**404** — the queue is really gone. (`listQueues` paging error is a
pre-existing, unrelated KD row — the SDK paged-list surface, not the
delete face; it failed identically in the open witness.)

## Raw-wire leg (plain TCP, port 5672, verbatim server bytes)

```
CREATE STATUS LINE: HTTP/1.1 201 Created
DELETE STATUS LINE: HTTP/1.1 204 No Content
DELETE RESPONSE (verbatim): "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n"
DELETE BODY BYTES: 0
DELETE HAS CONTENT-LENGTH: false
GET STATUS LINE: HTTP/1.1 404 Not Found
```

Full 201 ATOM entry body returned on PUT create (1110 bytes, QueueDescription
with QueueName/LockDuration/MaxSizeInMegabytes/etc.), then the Azure-truthful
204 framing: no content-type, no content-length, zero body bytes before
close. GET after delete is a well-framed ATOM `ResourceNotFound` 404. The
AMQP `:bad_protocol_header` misclassification from the open witness does not
recur — the method-word sniff fix in
`lib/smalt/messaging/amqp/atom_bridge.ex` (`# KD-COVERS: KD-155`) is live on
this recycled substrate.

## Verdict

KD-155 close condition met on the recycled substrate with the fix live:
real-SDK createQueue → deleteQueue → getQueue 404 end-to-end, raw-wire 204
No Content (no content-length, empty body) on the ATOM face.

## Standing

- **Standing**: ALIVE
- **Context**: pair (real-SDK leg + raw-wire leg, same live recycled
  substrate, same window)
- Honest notes: first probe run SKIPped loudly on a missing-CA probe-env
  defect (not substrate state) before the re-run; the stale raw probe
  (`kd155-raw-delete.cjs`, POST-create) was left as found and superseded by
  `kd155-raw-put-delete.cjs` rather than edited; `listQueues` paging error
  is pre-existing and out of KD-155 scope.
