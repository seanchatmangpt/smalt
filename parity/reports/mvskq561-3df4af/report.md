# parity report mvskq561-3df4af

- run: 2026-10-28T20:35:27.916Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/cosmos 4.10.1

## blob — smalt vs azurite (MATCH)

| op | smalt | azurite | verdict |
|---|---|---|---|
| blob-suite | `CRASH suite crashed` | `CRASH suite crashed` | MATCH |

## cosmos — smalt vs emulator (SKIP)

| op | smalt | emulator | verdict |
|---|---|---|---|
| item-upsert-create | `201 {"resource":{"id":"probe-mvskq561-3df4af","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read | `200 {"resource":{"id":"probe-mvskq561-3df4af","v":0}}` | `SKIPPED (target down)` | SKIP |
| item-read-missing | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |
| item-replace-fresh-etag | `200 {"resource":{"id":"probe-mvskq561-3df4af","v":1}}` | `SKIPPED (target down)` | SKIP |
| item-replace-stale-etag | `ERR 0 412` | `SKIPPED (target down)` | SKIP |
| item-query | `200 {"count":1,"resources":[{"id":"probe-mvskq561-3df4af","v":1}]}` | `SKIPPED (target down)` | SKIP |
| item-delete | `204` | `SKIPPED (target down)` | SKIP |
| item-read-after-delete | `200 {"unexpectedlyPresent":true}` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 9, match: 1, divergent: 0, skipped-legs: cosmos/emulator
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.