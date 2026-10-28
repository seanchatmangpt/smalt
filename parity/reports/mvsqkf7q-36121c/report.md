# parity report mvsqkf7q-36121c

- run: 2026-10-28T23:18:58.449Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/storage-queue 12.32.0, @azure/data-tables 13.3.2, @azure/cosmos 4.10.1

## blob — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| container-create | `201` | `201` | MATCH |
| container-get-properties | `200 {"hasMetadata":true}` | `200 {"hasMetadata":true}` | MATCH |
| container-set-metadata | `200` | `200` | MATCH |
| container-get-metadata | `200 {"parity":"mvsqkf7q-36121c"}` | `200 {"parity":"mvsqkf7q-36121c"}` | MATCH |
| service-properties-get | `200 {"corsIsArray":true,"hasLogging":false}` | `200 {"corsIsArray":true,"hasLogging":false}` | MATCH |
| list-containers-prefix | `200 {"count":1,"listed":true}` | `200 {"count":1,"listed":true}` | MATCH |
| container-lease-acquire-release | `201 {"hasLeaseId":true,"releaseStatus":200}` | `201 {"hasLeaseId":true,"releaseStatus":200}` | MATCH |
| container-set-access-policy | `ERR 0 ((containerAcl || []) is not iterable)` | `ERR 0 ((containerAcl || []) is not iterable)` | MATCH |
| container-get-access-policy | `200 {"signedIdentifiersCount":0}` | `200 {"signedIdentifiersCount":0}` | MATCH |
| block-upload | `201` | `201` | MATCH |
| blob-get-properties | `200 {"contentLength":30}` | `200 {"contentLength":30}` | MATCH |
| blob-set-metadata | `200` | `200` | MATCH |
| blob-get-metadata | `200 {"parity":"mvsqkf7q-36121c"}` | `200 {"parity":"mvsqkf7q-36121c"}` | MATCH |
| blob-download | `200 {"contentLength":30,"roundTrip":true}` | `200 {"contentLength":30,"roundTrip":true}` | MATCH |
| blob-conditional-read-304 | `ERR 304` | `ERR 304` | MATCH |
| blob-set-http-headers | `200` | `200` | MATCH |
| blob-content-type-after-headers | `200 {"contentType":"application/octet-stream; charset=utf-8"}` | `200 {"contentType":"text/plain"}` | MATCH |
| blob-list-flat | `200 {"count":1,"names":["probe-mvsqkf7q-36121c"],"lengths":[30]}` | `200 {"count":1,"names":["probe-mvsqkf7q-36121c"],"lengths":[30]}` | MATCH |
| blob-snapshot | `201` | `201` | MATCH |
| snapshot-list-includes | `200 {"snapshotEntries":1}` | `200 {"snapshotEntries":1}` | MATCH |
| blob-lease-acquire-release | `201 {"hasLeaseId":true,"releaseStatus":200}` | `201 {"hasLeaseId":true,"releaseStatus":200}` | MATCH |
| append-create | `201` | `201` | MATCH |
| append-appendBlock | `201` | `201` | MATCH |
| append-download | `200 {"roundTrip":true}` | `200 {"roundTrip":true}` | MATCH |
| page-create | `201` | `201` | MATCH |
| page-upload | `201` | `201` | MATCH |
| page-download | `200 {"contentLength":512,"allX":true}` | `200 {"contentLength":512,"allX":true}` | MATCH |
| stage-block-uncommitted | `201` | `201` | MATCH |
| stage-block-invalid-id | `ERR 400 InvalidQueryParameterValue` | `ERR 400 InvalidQueryParameterValue` | MATCH |
| get-blocklist-uncommitted | `200 {"committedCount":0,"uncommittedCount":1}` | `200 {"committedCount":0,"uncommittedCount":1}` | MATCH |
| commit-blocklist | `201` | `201` | MATCH |
| get-blocklist-committed | `200 {"committedCount":1,"uncommittedCount":0}` | `200 {"committedCount":1,"uncommittedCount":0}` | MATCH |
| blob-delete-under-immutable | `202 {"unexpectedlyDeleted":true}` | `ERR 409 SnapshotsPresent` | DIVERGENT |
| blob-delete | `ERR 404 BlobNotFound (The specified blob does not exist.)` | `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:54d0cba7)` | DIVERGENT |
| blob-download-after-delete | `ERR 404 BlobNotFound` | `200 {"unexpectedlyPresent":true}` | DIVERGENT |
| container-delete | `202` | `202` | MATCH |
| container-list-gone | `200 {"stillListed":false}` | `200 {"stillListed":false}` | MATCH |

### divergences (3)

- **blob-delete-under-immutable**: smalt `202 {"unexpectedlyDeleted":true}` vs azurite `ERR 409 SnapshotsPresent`
- **blob-delete**: smalt `ERR 404 BlobNotFound (The specified blob does not exist.)` vs azurite `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:54d0cba7)`
- **blob-download-after-delete**: smalt `ERR 404 BlobNotFound` vs azurite `200 {"unexpectedlyPresent":true}`

## queue — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| queue-create | `201` | `201` | MATCH |
| queue-get-properties | `ERR 404 ContainerNotFound (Container not found.)` | `200 {"hasMetadata":false}` | DIVERGENT |
| queue-set-metadata | `204` | `204` | MATCH |
| queue-get-metadata | `ERR 404 ContainerNotFound (Container not found.)` | `200 {"parity":"mvsqkf7q-36121c"}` | DIVERGENT |
| queue-send-message | `201 {"hasMessageId":true}` | `201 {"hasMessageId":true}` | MATCH |
| queue-receive-messages | `200 {"count":1,"bodies":["parity-body-mvsqkf7q-36121c"],"dequeueCounts":[1]}` | `200 {"count":1,"bodies":["parity-body-mvsqkf7q-36121c"],"dequeueCounts":[1]}` | MATCH |
| queue-peek-empty-while-invisible | `200 {"count":0}` | `200 {"count":0}` | MATCH |
| queue-receive-empty | `200 {"count":0}` | `200 {"count":0}` | MATCH |
| queue-clear-messages | `204` | `204` | MATCH |
| queue-send-update-delete | `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvsqkf7q-36121c"}` | `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvsqkf7q-36121c"}` | MATCH |
| queue-list-contains | `200 {"listed":false}` | `200 {"listed":true}` | DIVERGENT |
| queue-delete | `204` | `204` | MATCH |
| queue-send-after-delete | `ERR 404 QueueNotFound` | `ERR 404 QueueNotFound` | MATCH |

### divergences (3)

- **queue-get-properties**: smalt `ERR 404 ContainerNotFound (Container not found.)` vs azurite `200 {"hasMetadata":false}`
- **queue-get-metadata**: smalt `ERR 404 ContainerNotFound (Container not found.)` vs azurite `200 {"parity":"mvsqkf7q-36121c"}`
- **queue-list-contains**: smalt `200 {"listed":false}` vs azurite `200 {"listed":true}`

## summary

- ops: 50, match: 44, divergent: 6, skipped-legs: 
- verdict: **DIVERGENCES FOUND** — divergences are findings for the KD register, not harness failures.