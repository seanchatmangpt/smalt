# SB Management Plane Interop Probe — official emulator 5300 vs smalt ARM SB face

- **Lane**: W30-H (bench-runner, interop probe), 2026-10-21
- **Standing**: PARTIAL_ALIVE (all legs executed on real transports; findings below)
- **Machine**: `just bench-machine` → `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Environment

- Docker 29.5.2 available. Official pair booted via compose at `/tmp/w30h-sbemulator/`
  (`mcr.microsoft.com/azure-messaging/servicebus-emulator:latest` + SQL pair), host ports
  **15672→5672 / 15300→5300** (5672/5300 held by smalt substrate — never evicted).
- **Environment correction**: `mssql/server:2022-latest` crashed on this ARM64 Docker
  (`Invalid mapping of address ... below 0x400000000000`, container exit 1 → emulator
  health check "SQL DB Unhealthly" → halt). Swapped to `mcr.microsoft.com/azure-sql-edge:latest`
  — emulator went ready in ~24 s. Anyone replaying this probe on Apple Silicon must use sql-edge.
- smalt substrate: pre-existing, untouched (read/probe only) — 9443 plain HTTP ARM, bearer :enforce.

## Emulator 5300 raw-HTTP characterization (no SDK)

Connection string law holds: `.NET Administration Client` needs
`Endpoint=sb://localhost;...;HttpTransportPort=5300`. Raw HTTP probes:

| Op | Result |
|---|---|
| PUT `/{ns}/queues/{name}` atom+xml entry | **201**, echoes QueueDescription atom entry (defaults hydrated: LockDuration PT1M, MaxSize 100, DefaultTTL PT1H); `author/name=sbemulatorns`; `link rel=self` host faked as `sbemulatorns.servicebus.onebox.windows-int.net:15300` |
| PUT update existing (MaxSize 2048) | **201** but body ignored — re-GET shows MaxSize 100 (PUT is create-or-noop, update not applied) |
| GET existing entity | 200 atom entry |
| GET nonexistent | **200** + generic "Publicly Listed Services" feed — **no 404**, entity-absence indistinguishable from the discovery feed |
| DELETE existing | 200; subsequent GET returns services feed (indistinguishable from 404) |
| PUT `/{ns}/topics/{t}` | **201** TopicDescription atom |
| PUT `/{ns}/topics/{t}/subscriptions/{s}` (both casings) | **500** untyped `<Error><Code>500</Code>` "Something went wrong" — subscription create not reachable over raw HTTP |
| Auth: no header | 201 — no auth enforcement on 5300 |
| Auth: bogus SAS header | 201 — bogus credentials accepted |

Discovery feed (any GET fallback): `<feed xmlns="http://www.w3.org/2005/Atom"><title type="text">Publicly Listed Services</title>...` HTTP 200 for every unmatched GET path (including /swagger, /api).

## smalt ARM SB face characterization (bearer :enforce, HTTP 9443)

- STS: `POST /smalt/oauth2/v2.0/token` → HS256 bearer (any client_id/secret) — 1269-byte token.
- Route: `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ServiceBus/namespaces/{ns}/queues|topics|topics/{t}/subscriptions/{s}`.
- api-version gate live: `2022-01-01-preview` → 400 InvalidApiVersionParameter naming latest
  (queues 2024-01-01, topics/subs 2021-04-01 per `lib/smalt/registry.ex`).
- PUT queue without `location` in body → **400 InvalidResourceShape "A resource payload may
  carry at most one location."** — DefaultShape requires `location` even for child resources;
  message text is misleading for the absent-field case (candidate KD row).
- PUT with `{"location":"eastus","properties":{...}}` → 201 create, **200 update with body
  honored** (maxSizeInMegabytes 1024→2048 persists across GET).
- GET nonexistent → typed **404 ResourceNotFound** with target id. No-auth → 401. DELETE → 200;
  GET after → 404. Namespace PUT with location+sku → 202 long-running-operation envelope.
- Topic 201 (defaults hydrated: TTL P14D, batched ops), subscription 201.
- Cleanup verified: topic/ns DELETE 200; RG list empty afterwards.

## Differential table

| Dimension | Official SB emulator (5300 raw) | smalt ARM SB (9443) |
|---|---|---|
| URL shape | `/{ns}/queues/{name}` flat REST | ARM full id `.../namespaces/{ns}/queues/{name}` |
| Auth | none enforced; bogus SAS accepted | HS256 bearer enforced (401 tokenless) |
| Body format | atom+xml entry (`QueueDescription` ns `.../2010/10/servicebus/connect`) | JSON ARM resource |
| api-version gate | ignored (no effect observed) | enforced, typed 400 naming latest |
| Create | 201, defaults hydrated | 201, defaults hydrated |
| Update | 201, **body silently ignored** | 200, body honored and persisted |
| Get-missing | **200** services feed (no 404) | typed 404 ResourceNotFound |
| Subscription create | **500 untyped** | 201 |
| Error envelope | ad-hoc `<Error><Code>…` | ARM `{"error":{code,message,…}}` |
| Namespace resource | fixed, config.json static model | ARM-managed (202 LRO envelope) |
| 9443-transport note | plain HTTP 5300 | plain HTTP 9443; TLS twin 9444 (SDK legs) |

## Findings / candidate divergences

1. **Emulator GET-missing returns 200 discovery feed** — raw-HTTP clients cannot distinguish
   existence; smalt's typed 404 is closer to live Azure ARM. KD candidate (emulator-side).
2. **Emulator PUT-update silently ignores body** — create-or-noop only.
3. **Emulator subscription create over raw HTTP 5300 = untyped 500** — the documented
   ".NET-only" caveat is real even over HTTP; only queues/topics are manageable raw.
4. **smalt child PUT requires `location`** with a misleading "at most one location" refusal
   message when absent — candidate KD row against `DefaultShape` messaging children.
5. SQL 2022 container image does not run under this ARM64 Docker; sql-edge required (replay note).

## Replay

```bash
# emulator pair
mkdir -p /tmp/w30h-sbemulator && cd /tmp/w30h-sbemulator
# docker-compose.yml + config.json as used in this probe (SQL image: azure-sql-edge)
docker compose up -d
curl -X PUT -H 'Content-Type: application/atom+xml;type=entry;charset=utf-8' \
  --data-binary @putq.xml http://localhost:15300/sbemunsl/queues/probe-q
# smalt face
TOK=$(curl -s -X POST -d 'grant_type=client_credentials&client_id=probe&client_secret=x&scope=api' \
  http://localhost:9443/smalt/oauth2/v2.0/token | python3 -c '...access_token...')
curl -X PUT -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"location":"eastus","properties":{}}' \
  'http://localhost:9443/subscriptions/probe-sub/resourceGroups/probe-rg/providers/Microsoft.ServiceBus/namespaces/sbns/queues/raw-q?api-version=2024-01-01'
```

Teardown: `docker compose down -v` executed; smalt-side entities deleted (RG list empty).
No bench jsonl emitted (probe lane, not a bench lane); no lib edits; no git ops.
