# parity report mvslg272-a32c3f

- run: 2026-10-28T20:55:36.850Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/storage-queue 12.32.0, @azure/data-tables 13.3.2, @azure/cosmos 4.10.1

## blob — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| container-create | `201` | `201` | MATCH |
| container-get-properties | `200 {"hasMetadata":true}` | `200 {"hasMetadata":true}` | MATCH |
| container-set-metadata | `200` | `200` | MATCH |
| container-get-metadata | `200 {"parity":"mvslg272-a32c3f"}` | `200 {"parity":"mvslg272-a32c3f"}` | MATCH |
| service-properties-get | `ERR 404 RouteNotFound (No route matches GET /smaltacct/)` | `200 {"corsIsArray":true,"hasLogging":false}` | DIVERGENT |
| list-containers-prefix | `200 {"count":1,"listed":true}` | `200 {"count":1,"listed":true}` | MATCH |
| container-lease-acquire | `ERR 0 (container.acquireLease is not a function)` | `ERR 0 (container.acquireLease is not a function)` | MATCH |
| container-lease-release | `ERR 0 (container.acquireLease is not a function)` | `ERR 0 (container.acquireLease is not a function)` | MATCH |
| block-upload | `201` | `201` | MATCH |
| blob-get-properties | `200 {"contentLength":30}` | `200 {"contentLength":30}` | MATCH |
| blob-set-metadata | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `200` | DIVERGENT |
| blob-get-metadata | `200 {"parity":null}` | `200 {"parity":"mvslg272-a32c3f"}` | DIVERGENT |
| blob-download | `200 {"contentLength":30,"roundTrip":true}` | `200 {"contentLength":30,"roundTrip":true}` | MATCH |
| blob-conditional-read-304 | `ERR 304` | `ERR 304` | MATCH |
| blob-set-http-headers | `ERR 400 InvalidQueryParameterValue (The comp value 'properties' is not supported.)` | `200` | DIVERGENT |
| blob-content-type-after-headers | `200 {"contentType":"application/octet-stream; charset=utf-8"}` | `200 {"contentType":"text/plain"}` | MATCH |
| blob-list-flat | `200 {"count":1,"names":["probe-mvslg272-a32c3f"],"lengths":[30]}` | `200 {"count":1,"names":["probe-mvslg272-a32c3f"],"lengths":[30]}` | MATCH |
| blob-snapshot | `201` | `201` | MATCH |
| snapshot-list-includes | `200 {"snapshotEntries":1}` | `200 {"snapshotEntries":1}` | MATCH |
| blob-lease-acquire | `ERR 0 (blob.acquireLease is not a function)` | `ERR 0 (blob.acquireLease is not a function)` | MATCH |
| blob-lease-release | `ERR 0 (blob.acquireLease is not a function)` | `ERR 0 (blob.acquireLease is not a function)` | MATCH |
| append-create | `201` | `201` | MATCH |
| append-appendBlock | `ERR 400 InvalidQueryParameterValue (The comp value 'appendblock' is not supported.)` | `201` | DIVERGENT |
| append-download | `200 {"roundTrip":false}` | `200 {"roundTrip":true}` | DIVERGENT |
| page-create | `201` | `201` | MATCH |
| page-upload | `ERR 400 InvalidQueryParameterValue (The comp value 'page' is not supported.)` | `201` | DIVERGENT |
| page-download | `200 {"contentLength":0,"allX":false}` | `200 {"contentLength":512,"allX":true}` | DIVERGENT |
| stage-block-uncommitted | `201` | `ERR 400 InvalidQueryParameterValue (Value for one of the query parameters specified in the request URI is invalid.
R)` | DIVERGENT |
| get-blocklist-uncommitted | `200 {"committedCount":0,"uncommittedCount":1}` | `ERR 404 BlobNotFound (The specified blob does not exist.
RequestId:c1294e98-4ef8-4e50-80b2-ce04b30cceb)` | DIVERGENT |
| commit-blocklist | `ERR 0 (Error "blocks.Latest with value "[object Object]" must be of type string." occur)` | `ERR 0 (Error "blocks.Latest with value "[object Object]" must be of type string." occur)` | MATCH |
| get-blocklist-committed | `200 {"committedCount":0,"uncommittedCount":1}` | `ERR 404 BlobNotFound (The specified blob does not exist.
RequestId:39590bb8-5030-4793-b963-0298814a391)` | DIVERGENT |
| legalhold-set | `ERR 0 (container.setLegalHold is not a function)` | `ERR 0 (container.setLegalHold is not a function)` | MATCH |
| blob-delete-under-hold | `ERR 409 ContainerLocked` | `ERR 409 SnapshotsPresent` | DIVERGENT |
| legalhold-clear | `ERR 0 (container.setLegalHold is not a function)` | `ERR 0 (container.setLegalHold is not a function)` | MATCH |
| blob-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:d6d6c063)` | DIVERGENT |
| blob-download-after-delete | `200 {"unexpectedlyPresent":true}` | `200 {"unexpectedlyPresent":true}` | MATCH |
| container-delete | `ERR 409` | `202` | DIVERGENT |
| container-list-gone | `200 {"stillListed":true}` | `200 {"stillListed":false}` | DIVERGENT |

### divergences (15)

- **service-properties-get**: smalt `ERR 404 RouteNotFound (No route matches GET /smaltacct/)` vs azurite `200 {"corsIsArray":true,"hasLogging":false}`
- **blob-set-metadata**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `200`
- **blob-get-metadata**: smalt `200 {"parity":null}` vs azurite `200 {"parity":"mvslg272-a32c3f"}`
- **blob-set-http-headers**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'properties' is not supported.)` vs azurite `200`
- **append-appendBlock**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'appendblock' is not supported.)` vs azurite `201`
- **append-download**: smalt `200 {"roundTrip":false}` vs azurite `200 {"roundTrip":true}`
- **page-upload**: smalt `ERR 400 InvalidQueryParameterValue (The comp value 'page' is not supported.)` vs azurite `201`
- **page-download**: smalt `200 {"contentLength":0,"allX":false}` vs azurite `200 {"contentLength":512,"allX":true}`
- **stage-block-uncommitted**: smalt `201` vs azurite `ERR 400 InvalidQueryParameterValue (Value for one of the query parameters specified in the request URI is invalid.
R)`
- **get-blocklist-uncommitted**: smalt `200 {"committedCount":0,"uncommittedCount":1}` vs azurite `ERR 404 BlobNotFound (The specified blob does not exist.
RequestId:c1294e98-4ef8-4e50-80b2-ce04b30cceb)`
- **get-blocklist-committed**: smalt `200 {"committedCount":0,"uncommittedCount":1}` vs azurite `ERR 404 BlobNotFound (The specified blob does not exist.
RequestId:39590bb8-5030-4793-b963-0298814a391)`
- **blob-delete-under-hold**: smalt `ERR 409 ContainerLocked` vs azurite `ERR 409 SnapshotsPresent`
- **blob-delete**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:d6d6c063)`
- **container-delete**: smalt `ERR 409` vs azurite `202`
- **container-list-gone**: smalt `200 {"stillListed":true}` vs azurite `200 {"stillListed":false}`

## queue — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| queue-create | `ERR 409 ContainerAlreadyExists (The specified container already exists with different metadata.)` | `201` | DIVERGENT |
| queue-get-properties | `200 {"hasMetadata":true}` | `200 {"hasMetadata":false}` | DIVERGENT |
| queue-set-metadata | `ERR 200 (Unexpected status code: 200)` | `204` | DIVERGENT |
| queue-get-metadata | `200 {"parity":"mvslg272-a32c3f"}` | `200 {"parity":"mvslg272-a32c3f"}` | MATCH |
| queue-send-message | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `201 {"hasMessageId":true}` | DIVERGENT |
| queue-receive-messages | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":1,"bodies":["parity-body-mvslg272-a32c3f"],"dequeueCounts":[1]}` | DIVERGENT |
| queue-peek-empty-while-invisible | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":0}` | DIVERGENT |
| queue-receive-empty | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"count":0}` | DIVERGENT |
| queue-clear-messages | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `204` | DIVERGENT |
| queue-send-update-delete | `ERR 404 QueueNotFound (The specified queue does not exist.)` | `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvslg272-a32c3f"}` | DIVERGENT |
| queue-list-contains | `200 {"listed":false}` | `200 {"listed":true}` | DIVERGENT |
| queue-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `204` | DIVERGENT |
| queue-send-after-delete | `ERR 404 QueueNotFound` | `ERR 404 QueueNotFound` | MATCH |

### divergences (11)

- **queue-create**: smalt `ERR 409 ContainerAlreadyExists (The specified container already exists with different metadata.)` vs azurite `201`
- **queue-get-properties**: smalt `200 {"hasMetadata":true}` vs azurite `200 {"hasMetadata":false}`
- **queue-set-metadata**: smalt `ERR 200 (Unexpected status code: 200)` vs azurite `204`
- **queue-send-message**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `201 {"hasMessageId":true}`
- **queue-receive-messages**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":1,"bodies":["parity-body-mvslg272-a32c3f"],"dequeueCounts":[1]}`
- **queue-peek-empty-while-invisible**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":0}`
- **queue-receive-empty**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"count":0}`
- **queue-clear-messages**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `204`
- **queue-send-update-delete**: smalt `ERR 404 QueueNotFound (The specified queue does not exist.)` vs azurite `200 {"updateStatus":204,"deleteStatus":204,"updatedBody":"updated-mvslg272-a32c3f"}`
- **queue-list-contains**: smalt `200 {"listed":false}` vs azurite `200 {"listed":true}`
- **queue-delete**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `204`

## table — smalt vs azurite (MATCH)

| op | smalt | azurite | verdict |
|---|---|---|---|
| service-list-tables-empty | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables while allowInsecureConn)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables while allowInse)` | MATCH |
| table-create | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables while allowInsecureConn)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables while allowInse)` | MATCH |
| entity-insert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f while al)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f )` | MATCH |
| entity-insert-duplicate | `ERR 0` | `ERR 0` | MATCH |
| entity-get | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f(Partitio)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f()` | MATCH |
| entity-upsert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f(Partitio)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f()` | MATCH |
| entity-get-after-upsert | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f(Partitio)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f()` | MATCH |
| entity-query | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f() while )` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f()` | MATCH |
| entity-get-missing | `ERR 0` | `ERR 0` | MATCH |
| entity-delete | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/paritymvslg272-a32c3f(Partitio)` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/paritymvslg272-a32c3f()` | MATCH |
| table-delete | `ERR 0 (Cannot connect to http://127.0.0.1:8443/smaltacct/Tables('paritymvslg272-a32c3f')` | `ERR 0 (Cannot connect to http://127.0.0.1:10002/devstoreaccount1/Tables('paritymvslg272)` | MATCH |

## cosmos — smalt vs emulator (DIVERGENT)

| op | smalt | emulator | verdict |
|---|---|---|---|
| item-upsert-create | `201 {"resource":{"id":"probe-mvslg272-a32c3f","v":0}}` | `TIMEOUT op deadline 30000ms` | DIVERGENT |
| item-read | `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":0}}` | `null` | DIVERGENT |
| item-read-missing | `200 {"unexpectedlyPresent":true}` | `null` | DIVERGENT |
| item-replace-fresh-etag | `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":1}}` | `null` | DIVERGENT |
| item-replace-stale-etag | `ERR 0 412` | `null` | DIVERGENT |
| item2-upsert-create | `201 {"resource":{"id":"probe2-mvslg272-a32c3f","v":100}}` | `null` | DIVERGENT |
| item-upsert-update | `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":2}}` | `null` | DIVERGENT |
| item-patch | `ERR 0 400 (The patch document must be a JSON array of RFC 6902 operations.)` | `null` | DIVERGENT |
| item-delete-2 | `204` | `null` | DIVERGENT |
| item-read-after-delete-2 | `200 {"unexpectedlyPresent":true}` | `null` | DIVERGENT |
| query-point | `200 {"count":1,"resources":[{"id":"probe-mvslg272-a32c3f","v":2}]}` | `null` | DIVERGENT |
| query-cross-partition | `200 {"count":1,"resources":[{"id":"probe-mvslg272-a32c3f","v":2}]}` | `null` | DIVERGENT |
| query-order-by | `200 {"firstId":"probe-mvslg272-a32c3f","order":[2]}` | `null` | DIVERGENT |
| query-count | `ERR 0 400 (Expected FROM <alias>)` | `null` | DIVERGENT |
| item-delete | `204` | `null` | DIVERGENT |
| item-read-after-delete | `200 {"unexpectedlyPresent":true}` | `null` | DIVERGENT |
| db-create | `201` | `null` | DIVERGENT |
| db-read | `200` | `null` | DIVERGENT |
| coll-create-ifnotexists | `201` | `null` | DIVERGENT |
| db-delete | `204` | `null` | DIVERGENT |

### divergences (20)

- **item-upsert-create**: smalt `201 {"resource":{"id":"probe-mvslg272-a32c3f","v":0}}` vs emulator `TIMEOUT op deadline 30000ms`
- **item-read**: smalt `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":0}}` vs emulator `null`
- **item-read-missing**: smalt `200 {"unexpectedlyPresent":true}` vs emulator `null`
- **item-replace-fresh-etag**: smalt `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":1}}` vs emulator `null`
- **item-replace-stale-etag**: smalt `ERR 0 412` vs emulator `null`
- **item2-upsert-create**: smalt `201 {"resource":{"id":"probe2-mvslg272-a32c3f","v":100}}` vs emulator `null`
- **item-upsert-update**: smalt `200 {"resource":{"id":"probe-mvslg272-a32c3f","v":2}}` vs emulator `null`
- **item-patch**: smalt `ERR 0 400 (The patch document must be a JSON array of RFC 6902 operations.)` vs emulator `null`
- **item-delete-2**: smalt `204` vs emulator `null`
- **item-read-after-delete-2**: smalt `200 {"unexpectedlyPresent":true}` vs emulator `null`
- **query-point**: smalt `200 {"count":1,"resources":[{"id":"probe-mvslg272-a32c3f","v":2}]}` vs emulator `null`
- **query-cross-partition**: smalt `200 {"count":1,"resources":[{"id":"probe-mvslg272-a32c3f","v":2}]}` vs emulator `null`
- **query-order-by**: smalt `200 {"firstId":"probe-mvslg272-a32c3f","order":[2]}` vs emulator `null`
- **query-count**: smalt `ERR 0 400 (Expected FROM <alias>)` vs emulator `null`
- **item-delete**: smalt `204` vs emulator `null`
- **item-read-after-delete**: smalt `200 {"unexpectedlyPresent":true}` vs emulator `null`
- **db-create**: smalt `201` vs emulator `null`
- **db-read**: smalt `200` vs emulator `null`
- **coll-create-ifnotexists**: smalt `201` vs emulator `null`
- **db-delete**: smalt `204` vs emulator `null`

## summary

- ops: 82, match: 36, divergent: 46, skipped-legs: 
- verdict: **DIVERGENCES FOUND** — divergences are findings for the KD register, not harness failures.