# parity report mvskt405-db0af1

- run: 2026-10-28T20:37:46.054Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/cosmos 4.10.1

## blob — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| container-create | `201` | `201` | MATCH |
| container-get-properties | `200 {"hasMetadata":true}` | `200 {"hasMetadata":true}` | MATCH |
| block-upload | `201` | `201` | MATCH |
| blob-get-properties | `200 {"contentLength":30,"contentType":"application/octet-stream; charset=utf-8"}` | `200 {"contentLength":30,"contentType":"application/octet-stream"}` | MATCH |
| blob-set-metadata | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `200` | DIVERGENT |
| blob-get-metadata | `200 {"parity":null}` | `200 {"parity":"mvskt405-db0af1"}` | DIVERGENT |
| blob-download | `200 {"contentLength":30,"roundTrip":true}` | `200 {"contentLength":30,"roundTrip":true}` | MATCH |
| blob-list-flat | `200 {"count":1,"names":["probe-mvskt405-db0af1"],"lengths":[30]}` | `200 {"count":1,"names":["probe-mvskt405-db0af1"],"lengths":[30]}` | MATCH |
| blob-snapshot | `201` | `201` | MATCH |
| blob-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:47fcfc5d)` | DIVERGENT |
| blob-download-after-delete | `200 {"unexpectedlyPresent":true}` | `200 {"unexpectedlyPresent":true}` | MATCH |
| container-delete | `ERR 409` | `202` | DIVERGENT |
| container-list-gone | `200 {"stillListed":true}` | `200 {"stillListed":false}` | DIVERGENT |

### divergences (5)

- **blob-set-metadata**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `200`
- **blob-get-metadata**: smalt `200 {"parity":null}` vs azurite `200 {"parity":"mvskt405-db0af1"}`
- **blob-delete**: smalt `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` vs azurite `ERR 409 SnapshotsPresent (This operation is not permitted while the blob has snapshots.
RequestId:47fcfc5d)`
- **container-delete**: smalt `ERR 409` vs azurite `202`
- **container-list-gone**: smalt `200 {"stillListed":true}` vs azurite `200 {"stillListed":false}`

## cosmos — smalt vs emulator (SKIP)

| op | smalt | emulator | verdict |
|---|---|---|---|
| item-upsert-create | `201 {"resource":{"id":"probe-mvskt405-db0af1","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read | `200 {"resource":{"id":"probe-mvskt405-db0af1","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read-missing | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| item-replace-fresh-etag | `200 {"resource":{"id":"probe-mvskt405-db0af1","v":1}}` | `SKIPPED (target down)` | SKIP |
| item-replace-stale-etag | `ERR 0 412` | `SKIPPED (target down)` | SKIP |
| item-query | `200 {"count":1,"resources":[{"id":"probe-mvskt405-db0af1","v":1}]}` | `SKIPPED (target down)` | SKIP |
| item-delete | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 21, match: 8, divergent: 5, skipped-legs: cosmos/emulator
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.