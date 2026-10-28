# parity report mvskrzct-547d4c

- run: 2026-10-28T20:36:53.355Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/cosmos 4.10.1

## blob — smalt vs azurite (SKIP)

| op | smalt | azurite | verdict |
|---|---|---|---|
| container-create | `201` | `SKIPPED (target down)` | SKIP |
| container-get-properties | `200 {"hasMetadata":true}` | `SKIPPED (target down)` | SKIP |
| block-upload | `201` | `SKIPPED (target down)` | SKIP |
| blob-get-properties | `200 {"contentLength":30,"contentType":"application/octet-stream; charset=utf-8"}` | `SKIPPED (target down)` | SKIP |
| blob-set-metadata | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `SKIPPED (target down)` | SKIP |
| blob-get-metadata | `200 {"parity":null}` | `SKIPPED (target down)` | SKIP |
| blob-download | `200 {"contentLength":30,"roundTrip":true}` | `SKIPPED (target down)` | SKIP |
| blob-list-flat | `ERR 0 (container.list(...) is not a function or its return value is not async iterable)` | `SKIPPED (target down)` | SKIP |
| blob-snapshot | `201` | `SKIPPED (target down)` | SKIP |
| blob-delete | `ERR 409 ContainerLocked (Blob modification refused: container policy enforces immutable WORM retention.)` | `SKIPPED (target down)` | SKIP |
| blob-download-after-delete | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| container-delete | `ERR 409` | `SKIPPED (target down)` | SKIP |
| container-list-gone | `200 {"stillListed":true}` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 13, match: 0, divergent: 0, skipped-legs: blob/azurite
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.