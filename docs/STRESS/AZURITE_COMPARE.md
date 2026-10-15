# AZURITE_COMPARE.md

Honest head-to-head benchmark: smalt egress blob plane vs Azurite, identical
client code (vendored `@azure/storage-blob` 12.34.0), same machine, same run.

Runner: `scripts/stress/vs_azurite.py` (self-contained: boots both substrates,
runs the workloads, writes `/tmp/vs_azurite_receipt.json`).

## Measured run (2026-10-14, receipt /tmp/vs_azurite_receipt.json)

Host: macOS (darwin), colima docker 29.5.2, node v26.10.0, Elixir 1.19.5 /
OTP 28.3.1. smalt booted by the script on 8443 (`mix run --no-start` with
`egress_port` override); Azurite `mcr.microsoft.com/azure-storage/azurite:latest`
in docker on 10000 with `--skipApiVersionCheck --blobHost 0.0.0.0`.

Client: vendored `@azure/storage-blob` via `SMALT_SDK_ROOT`
(`<legacy-sdk-root>/playground/node_modules`), `StorageSharedKeyCredential`,
one pinned pipeline policy setting `x-ms-version: 2021-12-02` on every request
(identical on both targets; the vendored SDK's default 2026-10-06 api-version
cannot be canonicalized by current Azurite, causing 403 signature failures).

### Per-op latency (sequential, p50/p95 ms, ok/total)

| op | smalt p50 | smalt p95 | azurite p50 | azurite p95 |
|----|-----------|-----------|-------------|-------------|
| container create x50 | 0.5 | 1.2 | 3.4 | 6.2 |
| 1KB PUT x500 (fresh blob each) | 0.4 | 0.7 | 3.6 | 6.0 |
| GET x500 | 0.7 | 1.0 | 3.0 | 3.9 |
| list x50 | 4.2 | 5.8 | 59.9 | 74.1 |

All ops 100% ok on both targets (50/50, 500/500, 500/500, 50/50).
Zero client errors in the final run.

### Boot to ready

| substrate | boot_to_ready_s |
|-----------|-----------------|
| smalt (`mix run --no-start` -> first List Containers 200) | 3.84 |
| azurite (docker run -> first List Containers 200/403) | 0.98 |

## Method notes (honest limits)

- PUTs are fresh-unique-blob writes, not overwrites: smalt's default container
  policy is WORM-immutable (documented stricter-than-azurite default,
  docs/MIGRATION_FROM_EMULATORS.md), so overwriting one blob 500x is refused on
  smalt but allowed on azurite. Fresh-blob PUTs are identical semantics on both.
- smalt runs `auth_mode :anonymous` (same documented config as the repo's own
  T3 SDK tiers, test/sdk-smoke); enforce-mode default rejects SharedKey with
  MalformedBearerHeader and the JS SDK cannot inject the smalt STS Bearer on
  plain HTTP. Azurite runs its standard SharedKey validation (real signature
  checks; smalt accepts any key in this mode).
- Sequential single-client workloads only; no concurrency in this run
  (scripts/bench_concurrent.py exists for the concurrency lens).
- Docker adds vsock/port-forward overhead for azurite; smalt runs natively.
  This is the honest real-world deployment shape of each, not a controlled
  network comparison.
- Boot numbers include mix compile-check for smalt vs docker container start
  for azurite; both measured "spawn -> first successful List Containers".
- A prior run in this session (8443 held by another lane's substrate) booted a
  private smalt instance on fallback port 38443 and produced consistent
  numbers (create 0.4/0.9, put 0.3/0.4, get 0.4/0.6, list 3.6/5.7 vs azurite
  1.7/4.3, 2.4/3.7, 2.3/3.2, 53.4/70.4) — the runner falls back
  automatically and labels the mode in its receipt.

## Falsifiers / fail-closed

- If docker/azurite is unreachable, the runner prints DOCUMENT-UNAVAILABLE for
  the azurite leg and exits 1; if the smalt leg fails it exits 2. No synthetic
  azurite numbers are ever emitted.
- `docker --context colima` is required; colima must be started (`colima start`)
  and the azurite image pulled (`docker pull
  mcr.microsoft.com/azure-storage/azurite:latest`).
