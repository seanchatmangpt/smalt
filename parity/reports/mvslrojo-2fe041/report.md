# parity report mvslrojo-2fe041

- run: 2026-10-28T21:04:38.983Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/storage-queue 12.32.0, @azure/data-tables 13.3.2, @azure/cosmos 4.10.1

## blob — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| container-create | `201` | `201` | MATCH |
| container-get-properties | `200 {"hasMetadata":true}` | `200 {"hasMetadata":true}` | MATCH |
| container-set-metadata | `200` | `200` | MATCH |
| container-get-metadata | `200 {"parity":"mvslrojo-2fe041"}` | `200 {"parity":"mvslrojo-2fe041"}` | MATCH |
| service-properties-get | `ERR 404 RouteNotFound (No route matches GET /smaltacct/)` | `200 {"corsIsArray":true,"hasLogging":false}` | DIVERGENT |
| list-containers-prefix | `200 {"count":1,"listed":true}` | `200 {"count":1,"listed":true}` | MATCH |
| container-lease-acquire | `201 {"hasLeaseId":true}` | `201 {"hasLeaseId":true}` | MATCH |
| container-lease-release | `ERR 409 LeaseAlreadyPresent (There is already a lease present on the container.)` | `ERR 409 LeaseAlreadyPresent (There is already a lease present.
RequestId:9fe1c179-fece-4a45-b494-6c1a50bf4e64)` | MATCH |
| container-set-access-policy | `ERR 0 ((containerAcl || []) is not iterable)` | `ERR 0 ((containerAcl || []) is not iterable)` | MATCH |
| container-get-access-policy | `200 {"signedIdentifiersCount":0}` | `200 {"signedIdentifiersCount":0}` | MATCH |
| block-upload | `201` | `201` | MATCH |
| blob-get-properties | `200 {"contentLength":30}` | `200 {"contentLength":30}` | MATCH |
| blob-set-metadata | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `200` | DIVERGENT |
| blob-get-metadata | `200 {"parity":null}` | `200 {"parity":"mvslrojo-2fe041"}` | DIVERGENT |
| blob-download | `200 {"contentLength":30,"roundTrip":true}` | `200 {"contentLength":30,"roundTrip":true}` | MATCH |
| blob-conditional-read-304 | `ERR 304` | `ERR 304` | MATCH |
| blob-set-http-headers | `ERR 400 InvalidQueryParameterValue (The comp value 'properties' is not supported.)` | `200` | DIVERGENT |
| blob-content-type-after-headers | `200 {"contentType":"application/octet-stream; charset=utf-8"}` | `200 {"contentType":"text/plain"}` | MATCH |
| blob-list-flat | `200 {"count":1,"names":["probe-mvslrojo-2fe041"],"lengths":[30]}` | `200 {"count":1,"names":["probe-mvslrojo-2fe041"],"lengths":[30]}` | MATCH |
| blob-snapshot | `201` | `201` | MATCH |
| snapshot-list-includes | `200 {"snapshotEntries":1}` | `200 {"snapshotEntries":1}` | MATCH |
| blob-lease-acquire | `ERR 400 InvalidQueryParameterValue (The comp value 'lease' is not supported.)` | `201 {"hasLeaseId":true}` | DIVERGENT |
| blob-lease-release | `ERR 400 InvalidQueryParameterValue (The comp value 'lease' is not supported.)` | `ERR 409 LeaseAlreadyPresent (There is already a lease present.
RequestId:110e38e0-3b7f-499f-989d-e89ba8b6e35e)` | DIVERGENT |
| append-create | `201` | `201` | MATCH |
| append-appendBlock | `ERR 400 InvalidQueryParameterValue (The comp value 'appendblock' is not supported.)` | `201` | DIVERGENT |
| append-download | `200 {"roundTrip":false}` | `200 {"roundTrip":true}` | DIVERGENT |
| page-create | `201` | `201` | MATCH |
| page-upload | `ERR 400 InvalidQueryParameterValue (The comp value 'page' is not supported.)` | `201` | DIVERGENT |
| page-download | `200 {"contentLength":0,"allX":false}` | `200 {"contentLength":512,"allX":true}` | DIVERGENT |
| stage-block-uncommitted | `201` | `201` | MATCH |
| stage-block-invalid-id | `201 {"invalidIdAccepted":true}` | `ERR 400 InvalidQueryParameterValue` | DIVERGENT |
| get-blocklist-uncommitted | `200 {"committedCount":0,"uncommittedCount":2}` | `200 {"committedCount":0,"uncommittedCount":1}` | DIVERGENT |
| commit-blocklist | `ERR 0 (Error "blocks.Latest must be of type Array." occurred in serializing the payload)` | `ERR 0 (Error "blocks.Latest must be of type Array." occurred in serializing the payload)` | MATCH |
| get-blocklist-committed | `200 {"committedCount":0,"uncommittedCount":2}` | `200 {"committedCount":0,"uncommittedCount":1}` | DIVERGENT |
| blob-delete-under-immutable | `ERR 409 ContainerLocked` | `ERR 412 LeaseIdMissing` | DIVERGENT |
| blob-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `ERR 412 LeaseIdMissing (There is currently a lease on the blob and no lease ID was specified in the requ)` | DIVERGENT |
| blob-download-after-delete | `200 {"unexpectedlyPresent":true}` | `200 {"unexpectedlyPresent":true}` | MATCH |
| container-delete | `ERR 409` | `ERR 412` | DIVERGENT |
| container-list-gone | `200 {"stillListed":true}` | `200 {"stillListed":true}` | MATCH |

### divergences (16)

- **service-properties-get**: smalt `ERR 404 RouteNotFound (No route matches GET /smaltacct/)` vs azurite `200 {"corsIsArray":true,"hasLogging":false}`
- **blob-set-metadata**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `200`
- **blob-get-metadata**: smalt `200 {"parity":null}` vs azurite `200 {"parity":"mvslrojo-2fe041"}`
- **blob-set-http-headers**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'properties' is not supported.)` vs azurite `200`
- **blob-lease-acquire**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'lease' is not supported.)` vs azurite `201 {"hasLeaseId":true}`
- **blob-lease-release**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'lease' is not supported.)` vs azurite `ERR 409 LeaseAlreadyPresent (There is already a lease present.
RequestId:110e38e0-3b7f-499f-989d-e89ba8b6e35e)`
- **append-appendBlock**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'appendblock' is not supported.)` vs azurite `201`
- **append-download**: smalt `200 {"roundTrip":false}` vs azurite `200 {"roundTrip":true}`
- **page-upload**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'page' is not supported.)` vs azurite `201`
- **page-download**: smalt `200 {"contentLength":0,"allX":false}` vs azurite `200 {"contentLength":512,"allX":true}`
- **stage-block-invalid-id**: smalt `201 {"invalidIdAccepted":true}` vs azurite `ERR 400 InvalidQueryParameterValue`
- **get-blocklist-uncommitted**: smalt `200 {"committedCount":0,"uncommittedCount":2}` vs azurite `200 {"committedCount":0,"uncommittedCount":1}`
- **get-blocklist-committed**: smalt `200 {"committedCount":0,"uncommittedCount":2}` vs azurite `200 {"committedCount":0,"uncommittedCount":1}`
- **blob-delete-under-immutable**: smalt `ERR 409 ContainerLocked` vs azurite `ERR 412 LeaseIdMissing`
- **blob-delete**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `ERR 412 LeaseIdMissing (There is currently a lease on the blob and no lease ID was specified in the requ)`
- **container-delete**: smalt `ERR 409` vs azurite `ERR 412`

## queue — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| queue-create | `201` | `201` | MATCH |
| queue-get-properties | `200 {"hasMetadata":false}` | `200 {"hasMetadata":false}` | MATCH |
| queue-set-metadata | `ERR 200 (Unexpected status code: 200)` | `204` | DIVERGENT |
| queue-get-metadata | `200 {"parity":"mvslrojo-2fe041"}` | `200 {"parity":"mvslrojo-2fe041"}` | MATCH |
| queue-send-message | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `201 {"hasMessageId":true}` | DIVERGENT |
| queue-receive-messages | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":1,"bodies":["parity-body-mvslrojo-2fe041"],"dequeueCounts":[1]}` | DIVERGENT |
| queue-peek-empty-while-invisible | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":0}` | DIVERGENT |
| queue-receive-empty | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":0}` | DIVERGENT |
| queue-clear-messages | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `204` | DIVERGENT |
| queue-send-update-delete | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvslrojo-2fe041"}` | DIVERGENT |
| queue-list-contains | `200 {"listed":false}` | `200 {"listed":true}` | DIVERGENT |
| queue-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `204` | DIVERGENT |
| queue-send-after-delete | `ERR 404 QueueNotFound` | `ERR 404 QueueNotFound` | MATCH |

### divergences (9)

- **queue-set-metadata**: smalt `ERR 200 (Unexpected status code: 200)` vs azurite `204`
- **queue-send-message**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `201 {"hasMessageId":true}`
- **queue-receive-messages**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":1,"bodies":["parity-body-mvslrojo-2fe041"],"dequeueCounts":[1]}`
- **queue-peek-empty-while-invisible**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":0}`
- **queue-receive-empty**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":0}`
- **queue-clear-messages**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `204`
- **queue-send-update-delete**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvslrojo-2fe041"}`
- **queue-list-contains**: smalt `200 {"listed":false}` vs azurite `200 {"listed":true}`
- **queue-delete**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `204`

## table — smalt vs azurite (MATCH)

| op | smalt | azurite | verdict |
|---|---|---|---|
| service-list-tables-empty | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables while allowInsecureConn)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables while allowInse)` | MATCH |
| table-create | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables while allowInsecureConn)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables while allowInse)` | MATCH |
| entity-insert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041 while a)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| entity-insert-duplicate | `ERR 0` | `ERR 0` | MATCH |
| entity-get | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041(Partiti)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| entity-upsert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041(Partiti)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| entity-get-after-upsert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041(Partiti)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| entity-query | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041() while)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| entity-get-missing | `ERR 0` | `ERR 0` | MATCH |
| entity-delete | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritytmvslrojo-2fe041(Partiti)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritytmvslrojo-2fe041)` | MATCH |
| table-delete | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables('paritytmvslrojo-2fe041)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables('paritytmvslroj)` | MATCH |

## cosmos — smalt vs emulator (SKIP)

| op | smalt | emulator | verdict |
|---|---|---|---|
| item-upsert-create | `201 {"resource":{"id":"probe-mvslrojo-2fe041","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read | `200 {"resource":{"id":"probe-mvslrojo-2fe041","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read-missing | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| item-replace-fresh-etag | `200 {"resource":{"id":"probe-mvslrojo-2fe041","v":1}}` | `SKIPPED (target down)` | SKIP |
| item-replace-stale-etag | `ERR 0 412` | `SKIPPED (target down)` | SKIP |
| item2-upsert-create | `201 {"resource":{"id":"probe2-mvslrojo-2fe041","v":100}}` | `SKIPPED (target down)` | SKIP |
| item-upsert-update | `200 {"resource":{"id":"probe-mvslrojo-2fe041","v":2}}` | `SKIPPED (target down)` | SKIP |
| item-patch | `ERR 0 400 (The patch document must be a JSON array of RFC 6902 operations.)` | `SKIPPED (target down)` | SKIP |
| item-delete-2 | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete-2 | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| query-point | `200 {"count":1,"resources":[{"id":"probe-mvslrojo-2fe041","v":2}]}` | `SKIPPED (target down)` | SKIP |
| query-cross-partition | `200 {"count":1,"resources":[{"id":"probe-mvslrojo-2fe041","v":2}]}` | `SKIPPED (target down)` | SKIP |
| query-order-by | `200 {"firstId":"probe-mvslrojo-2fe041","order":[2]}` | `SKIPPED (target down)` | SKIP |
| query-count | `ERR 0 400 (Expected FROM <alias>)` | `SKIPPED (target down)` | SKIP |
| item-delete | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| db-create | `201` | `SKIPPED (target down)` | SKIP |
| db-read | `200` | `SKIPPED (target down)` | SKIP |
| coll-create-ifnotexists | `201` | `SKIPPED (target down)` | SKIP |
| db-delete | `204` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 83, match: 38, divergent: 25, skipped-legs: cosmos/emulator
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.