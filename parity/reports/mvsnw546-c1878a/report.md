# parity report mvsnw546-c1878a

- run: 2026-10-28T22:04:06.345Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/storage-queue 12.32.0, @azure/data-tables 13.3.2, @azure/cosmos 4.10.1

## cosmos — smalt vs emulator (SKIP)

| op | smalt | emulator | verdict |
|---|---|---|---|
| item-upsert-create | `201 {"resource":{"id":"probe-mvsnw546-c1878a","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read | `200 {"resource":{"id":"probe-mvsnw546-c1878a","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read-missing | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| item-replace-fresh-etag | `200 {"resource":{"id":"probe-mvsnw546-c1878a","v":1}}` | `SKIPPED (target down)` | SKIP |
| item-replace-stale-etag | `ERR 0 412` | `SKIPPED (target down)` | SKIP |
| item2-upsert-create | `201 {"resource":{"id":"probe2-mvsnw546-c1878a","v":100}}` | `SKIPPED (target down)` | SKIP |
| item-upsert-update | `200 {"resource":{"id":"probe-mvsnw546-c1878a","v":2}}` | `SKIPPED (target down)` | SKIP |
| item-patch | `ERR 0 400 (The patch document must be a JSON array of RFC 6902 operations.)` | `SKIPPED (target down)` | SKIP |
| item-delete-2 | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete-2 | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| query-point | `200 {"count":1,"resources":[{"id":"probe-mvsnw546-c1878a","v":2}]}` | `SKIPPED (target down)` | SKIP |
| query-cross-partition | `200 {"count":1,"resources":[{"id":"probe-mvsnw546-c1878a","v":2}]}` | `SKIPPED (target down)` | SKIP |
| query-order-by | `200 {"firstId":"probe-mvsnw546-c1878a","order":[2]}` | `SKIPPED (target down)` | SKIP |
| query-count | `ERR 0 400 (Expected FROM <alias>)` | `SKIPPED (target down)` | SKIP |
| item-delete | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| db-create | `201` | `SKIPPED (target down)` | SKIP |
| db-read | `200` | `SKIPPED (target down)` | SKIP |
| coll-create-ifnotexists | `201` | `SKIPPED (target down)` | SKIP |
| db-delete | `204` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 20, match: 0, divergent: 0, skipped-legs: cosmos/emulator
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.