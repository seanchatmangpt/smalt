# Receipt: Cosmos DB vNext Linux emulator interop probe (W30-C)

- **Date**: 2026-10-21
- **Lane**: W30-C (bench-runner, interop probe)
- **Subject**: `mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview`
  (digest `sha256:db53613dae19d0a3d5ad50688d14aa6e957af082dafea56b52e1bd3a6b3f1406`, image arch `arm64`, emulator version string `EN20261019`, gateway `x-ms-gatewayversion: 2.0.0-unknown`)
- **Standing**: ALIVE (all four witness legs executed on the exact subject; no lib edits; shared substrate untouched)
- **Machine**: Apple M3 Max, macOS 26.2, Docker 28.0.4 via colima 4 CPU / 8 GiB (aarch64, virtiofs)

## 1. Environment

Docker (colima) was up but the daemon socket was transiently unroutable;
`docker ps` succeeded on retry. No colima restart needed.

## 2. Container boot (leg 1)

```
docker run -d -t --name w30c-cosmos-vnext \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8081:8080
  mcr.microsoft.com/cosmosdb/linux/azure-cosmos-boot: ...
```

- First boot reached `/alive` HTTP 200 in ~5 s.
- **Finding (operational)**: without a TTY the emulator shuts down gracefully
  (`exit=0`, "Shutting down...", PG stop) roughly 2.5 min after start. Re-run
  with `-t` and it stays up indefinitely (witnessed up >5 min across legs 2-4).
  Anyone scripting this image detached must pass `-t` (or keep stdin open).
- Second finding: `/proc/net/tcp` shows three in-container listeners:
  `0x1F90`=8080 (probes), `0x1F91`=8081 (NoSQL gateway), `0x25F0`=9712
  (internal). Port 8080 alone serves ONLY the three probes; the NoSQL gateway
  is a separate listener on 8081. Docs that say "port 8080" describe the probe
  surface, not the data surface.

## 3. Health probes (leg 2)

All three documented probes witnessed on 8080, tokenless HTTP 200 with a JSON
health envelope (explorer/gateway/postgres sub-checks), e.g. `/status`:

```json
{
  "alive": true, "ready": true, "overall": true,
  "status": "healthy",
  "checks": {"explorer": "healthy", "gateway": "healthy", "postgres": "healthy"},
  "protocol": "http",
  "version": "EN20261019",
  "timestamp": "2026-10-21T16:39:02.445204634+00:00"
}
```

- `/alive`, `/ready`, `/status` return the identical envelope; the three are
  aliases of one health state, not three distinct checks.
- Unknown paths on 8080 return typed 404 with `available_endpoints` hints.

## 4. NoSQL gateway ops, tokenless (leg 3)

Auth-enforcement probe (per docs: no auth enforcement on Linux emulator):

| op | result |
|---|---|
| `GET /dbs` tokenless | 200, `x-ms-request-charge: 1` |
| `POST /dbs` tokenless | **201 Created** (`w30cdb`) |
| `POST .../colls` without partitionKey | 400 `"partitionKey is required in the request body"` |
| `POST .../colls` with `{"paths":["/pk"],"kind":"Hash"}` | 201, `_rid MDAwMQ==` |
| `POST .../docs` (doc with `pk`) | 201, etag returned |
| point read `GET .../docs/d1` without PK header | 400 "Partition key is required" |
| point read with `x-ms-documentdb-partitionkey: ["p0"]` | 200 full document |
| query `POST docs` with `application/query+json` | 200, `_count: 1` |

Auth model confirmed: **zero auth enforcement tokenless; every op admitted**.

## 5. Differential vs smalt's cosmos face (leg 4)

| dimension | smalt (v26.10.20 tree) | Cosmos vNext emulator | verdict |
|---|---|---| KD ref |
| probe endpoints | none — `grep -rn '"/alive"\|"/ready"\|"/status"' lib/smalt` returns nothing | `/alive` `/ready` `/status` on 8080 | candidate feature, NOT minted | KD candidate |
| auth model | `:enforce` (default) REQUIRES bearer on `/dbs`; tokenless → typed 401 (`cosmos_authz.ex`: "typed 401") | no auth enforcement; tokenless 201 on create | intentional divergence (smalt is the auth-testing twin; emulator is a dev convenience) | registered divergence, intentional |
| gateway port | NoSQL face rides data plane :8443 (single listener) | probes 8080, gateway 8081, internal 9712 | divergence, 2 listeners vs 1 | — |
| partition-key law | smalt has `lib/smalt/data_plane/partition_key.ex` | point read without PK header → 400 (matches real Cosmos semantics) | parity | — |
| health envelope shape | — | `alive/ready/overall/checks/version/timestamp` + sub-checks (explorer/gateway/postgres) | candidate schema if probes are adopted | — |

## 6. Candidate feature (report only, not minted)

smalt has no `/alive`, `/ready`, `/status` probe endpoints. If adopted, the
vNext envelope above (identical JSON on all three paths, sub-checks map,
`version` + `timestamp`, typed 404 with `available_endpoints` on unknown probe
paths) is the reference shape to mirror. Not minted per lane contract.

## 7. Replay

```bash
docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
docker run -d -t --name w30c-cosmos-vnext \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8081:8081 \
  mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
# poll http://127.0.0.1:8080/{alive,ready,status} until 200 (~10 s)
# gateway ops on http://127.0.0.1:8081 (tokenless, NoSQL REST)
docker rm -f w30c-cosmos-vnext   # teardown
```

Teardown executed: container removed, no volumes, no substrate contact.
