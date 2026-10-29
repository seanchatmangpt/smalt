# KD-61 witness — blob batch (POST comp=batch)

- **Standing:** PASS (with a registered pinion carry-over)
- **Context:** solo
- **Date:** 2026-10-21
- **Lane:** K1 (divergence-finish, two faces)
- **Subject:** `lib/smalt/egress_router.ex` `post "/:account/:container"` batch arm (landed pre-lane; witnessed this lane)

## Divergence (registered)

`BlobBatchClient.submitBatch` — no POST container route → catch-all 404.
Close condition: dedicated route; falsifier: submitBatch 2 deletes → 202
batched response.

## Finding

The route has LANDED since registration, at the real-Azure URI
`POST /{account}/{container}?restype=container&comp=batch` (the row's
`comp=blob` was a registration-time wire-shape error; Azure's Submit
Batch is `comp=batch`). `blob_batch_arm/2` parses multipart/mixed,
dispatches each sub-request through the real blob engine, and answers
the batched multipart response.

## Live-wire evidence (substrate :8443, STS bearer)

```
$ # seed: PUT k1b 201, PUT d1 201, PUT d2 201
$ curl -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'x-ms-version: 2023-11-03' -H 'Content-Type: multipart/mixed; boundary=b' \
    --data-binary @batch_body "$U/k1b?restype=container&comp=batch"
202
--batchresponse_a66f16fd-...
Content-ID: 0
HTTP/1.1 409 Conflict
x-ms-error-code: ContainerLocked
...Content-ID: 1
HTTP/1.1 409 Conflict
x-ms-error-code: ContainerLocked
```

The transport close condition is met: POST container batch route → 202
batched multipart response with one sub-response per part, dispatched
through the real engine. The sub-responses are 409 ContainerLocked
because the sub-deletes hit the WORM-by-default container pinion (see
the KD-05 disposition, same face) — a pinion carry-over, not a batch
transport defect. A real-Azure SDK witness (py/ts submitBatch PASS on
per-part 202) remains SDK-successor work (V261019-08).

## Flip-gate refresh (post-marker)

`python3 scripts/kd_flip.py` after adding `# KD-COVERS: KD-61` to the
batch arm: KD-61 tracked, gate now compares against this receipt's
post-shim mtime. Dry-run first reported FLIP-PENDING-WITNESS (receipt
predated the marker); refreshed post-marker.
