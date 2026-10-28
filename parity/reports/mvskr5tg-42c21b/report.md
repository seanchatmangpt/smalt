# parity report mvskr5tg-42c21b

- run: 2026-10-28T20:36:15.099Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/cosmos 4.10.1

## blob — smalt vs azurite (SKIP)

| op | smalt | azurite | verdict |
|---|---|---|---|
| blob-suite | `CRASH Blob modification refused: container policy enforces immutable WORM retention.` | `SKIPPED (target down)` | SKIP |

## summary

- ops: 1, match: 0, divergent: 0, skipped-legs: blob/azurite
- verdict: **PARTIAL** — divergences are findings for the KD register, not harness failures.