# parity — smalt vs the real Azure emulators

All-new comparison harness (zero changes to existing code): runs the **same
official-SDK operation lists** against the smalt substrate and against the
real-Azure emulators on this machine, normalizes the wire responses to
stable semantic fields, and diffs them. A divergence is a *finding* for the
KD register (`docs/reference/kd-register.md`), not a harness failure.

Distinct from `verification/` (the wire contract of record, smalt-only):
`parity/` exists to answer "what does real Azure do differently?" by
diffing two live stacks.

## targets

| target | stack | endpoint default | auth |
|---|---|---|---|
| `smalt` | this repo's substrate | `http://127.0.0.1:8443` (egress) | anonymous test mode (MIX_ENV=test) |
| `azurite` | Azurite Blob/Queue/Table (npm) | `http://127.0.0.1:10000` / `:10001` / `:10002` | SharedKey `devstoreaccount1` |
| `emulator` | Azure Cosmos DB Emulator | `https://127.0.0.1:8081` | master key `C2y6yDjf5/...==` |

## coverage map (what CAN run locally, and what cannot)

| Azure surface | smalt plane | reference | suite | ops |
|---|---|---|---|---|
| Blob (containers, block/append/page, leases, blocks, conditional reads, legal hold, service props) | `lib/smalt/data_plane/blob_storage.ex` | Azurite 10000 | `blob` | 33 |
| Queue Storage (lifecycle, send/receive/peek/update/delete/clear, metadata) | `lib/smalt/data_plane/queue_storage.ex` | Azurite 10001 | `queue` | 13 |
| Table Storage | **not implemented** (no data_plane module; egress router arms no table namespace) | Azurite 10002 | `table` | 11 (documents the gap) |
| Cosmos SQL (docs CRUD, etag 412, patch, point/cross-partition/ORDER BY/COUNT queries, db/coll control plane) | `lib/smalt/data_plane/cosmos.ex` | Cosmos emulator 8081 | `cosmos` | 21 |
| ARM control plane | `lib/smalt/arm_gateway/router.ex` | **no local reference exists** (no ARM emulator) | — | none possible |
| Key Vault / KQL / Purview / Resource Graph / Sentinel / SKR | mounted in smalt | **no local reference exists** | — | none possible |
| Service Bus (AMQP 5672) | mounted in smalt | SB emulator — **Docker-only, blocked** | — | none possible |
| Event Hubs (5673) | mounted in smalt | EH emulator — **Docker-only, blocked** | — | none possible |

Service Bus / Event Hubs legs are blocked on this machine (Docker-only
emulator images; no Docker/WSL) — see
`docs/how-to/how-to-run-on-windows.md` step 6.

## environment contract

smalt side (`SMALT_PARITY_*`), reference side (`PARITY_*`):

```
SMALT_PARITY_ARM=http://127.0.0.1:9443        # ownership-gate probe (metadata/endpoints)
SMALT_PARITY_EGRESS=http://127.0.0.1:8443     # blob/queue/table + cosmos docs surface
SMALT_PARITY_BLOB_ACCOUNT=smaltacct
SMALT_PARITY_BLOB_KEY=smaltacct-key
SMALT_PARITY_COSMOS_KEY=parity-dev-key        # ignored by anonymous mode; the client still signs
PARITY_AZURITE_BLOB=http://127.0.0.1:10000
PARITY_AZURITE_QUEUE=http://127.0.0.1:10001
PARITY_AZURITE_TABLE=http://127.0.0.1:10002
PARITY_COSMOS_ENDPOINT=https://127.0.0.1:8081
SMALT_PARITY_REPORT_DIR=parity/reports        # where reports land
```

## run

```bat
node parity\run.mjs                 # all suites (blob + queue + table + cosmos)
node parity\run.mjs blob queue      # storage family only (needs Azurite)
node parity\run.mjs cosmos          # cosmos only (needs the emulator)
```

Prereqs: the substrate up on canonical ports (`just up`, or the
`SMALT_TEST_*_PORT`-pinned `mix run --no-halt`), Azurite running, and —
for the cosmos leg — the Cosmos DB Emulator started from the Start Menu
(a service-context headless launch does not survive; witnessed 2026-10-28).

Official SDKs only (`@azure/storage-blob`, `@azure/storage-queue`,
`@azure/data-tables`, `@azure/cosmos`), versions pinned to match
`verification/ts/package.json`. The dependency tree lives
OUTSIDE this repo at `%USERPROFILE%\dev\tools\azsdk\node_modules` (repo law:
no `npm install` in-repo) and is exposed to the suites through the
`parity/node_modules` junction. Re-create the junction after cloning:

```bat
mklink /J parity\node_modules %USERPROFILE%\dev\tools\azsdk\node_modules
```

## exit-code contract (mirrors verification/README.md)

| exit | meaning |
|---|---|
| `0` | run completed, report written (divergences are findings, listed in the report) |
| `1` | unexpected harness error |
| `2` | smalt substrate never answered (nothing to compare) |
| `3` | one or more reference legs loud-skipped (emulator down); remaining legs still ran and the report was written |
| `124` | watchdog (300s) |

## normalization law

Only stable semantic fields are compared: HTTP status codes, typed error
codes, listing names/counts, content lengths, payload round-trips, and
cosmos item bodies reduced to user fields (`id`, `v`). Volatile or
stack-specific values — dates, etags, request ids, hosts/ports, cosmos
system properties (`_rid`, `_ts`, `_self`, `_lsn`, `_altLink`,
`_attachments`), session tokens — are stripped before diffing.

Adapter asymmetry is confined to `prepare()` (the emulator needs explicit
db/container creation; smalt auto-ensures on first docs write and needs its
partition-key-definition cache seeded because its colls GET answers 404 —
the known-good pattern lifted from `verification/ts/wf2/index.ts:32`).
Scored ops are byte-identical code paths for both targets.

## layout

- `run.mjs` — orchestrator: reachability gates, suite execution, diff, report
- `targets.mjs` — target registry: endpoints, credentials, client factories, adapters
- `suites/blob.mjs` — blob op list (container/blob lifecycle, metadata, listing, snapshot, typed 404)
- `suites/cosmos.mjs` — cosmos docs op list (upsert/read/replace, etag 412, query, delete, typed 404)
- `reports/<runid>/` — report.json (machine) + report.md (human); never hand-edited
