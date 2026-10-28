# parity report mvsqg9wd-b55738

- run: 2026-10-28T23:15:44.884Z (node v24.22.1)
- targets: smalt=http://127.0.0.1:9443 + http://127.0.0.1:8443 azurite=http://127.0.0.1:10000 emulator=https://127.0.0.1:8081
- sdks: @azure/storage-blob 12.34.0, @azure/storage-queue 12.32.0, @azure/data-tables 13.3.2, @azure/cosmos 4.10.1

## blob — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| blob-suite | `TIMEOUT op deadline 30000ms` | `201` | DIVERGENT |

### divergences (1)

- **blob-suite**: smalt `TIMEOUT op deadline 30000ms` vs azurite `201`

## queue — smalt vs azurite (DIVERGENT)

| op | smalt | azurite | verdict |
|---|---|---|---|
| queue-suite | `TIMEOUT op deadline 30000ms` | `201` | DIVERGENT |

### divergences (1)

- **queue-suite**: smalt `TIMEOUT op deadline 30000ms` vs azurite `201`

## summary

- ops: 2, match: 0, divergent: 2, skipped-legs: 
- verdict: **DIVERGENCES FOUND** — divergences are findings for the KD register, not harness failures.