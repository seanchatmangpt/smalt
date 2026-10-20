# Migration From Emulators

How to move local-development workloads from the official Azure emulator
containers (Azurite, Cosmos DB Emulator, Service Bus emulator, Event Hubs
emulator) to smalt. Ports and endpoints are read from
`lib/smalt/application.ex`, `lib/smalt/registry.ex`, and
`verification/ts/run-all.mjs` (the pre-reset `test/sdk-smoke/run.mjs` is RETIRED@64f6099).

## Port map

| Emulator container | Default emulator port | Smalt port | Smalt endpoint | Connection equivalent |
|---|---|---|---|---|
| Azurite (Blob) | 10000 | `:8443` | `http://127.0.0.1:8443/{account}/{container}[/{blob}]` | `new BlobServiceClient("http://127.0.0.1:8443/{account}", new StorageSharedKeyCredential(account, anyKey))` — any account/key accepted (see deltas). No `UseDevelopmentEmulator` conn-str form exists for Blob. |
| Cosmos DB Emulator | 8081 | `:8443` | `http://127.0.0.1:8443` | `new CosmosClient({ endpoint: "http://127.0.0.1:8443", key: <any 64-char hex string>, connectionPolicy: { enableEndpointsDiscovery: false } })` — any key accepted (see deltas); form pinned in `verification/ts/wf1` (pre-reset `test/sdk-smoke/cosmos.test.cjs`, RETIRED@64f6099). |
| Service Bus emulator (+ MSSQL) | 5672 | `:5672` | `sb://127.0.0.1:5672` (AMQP 1.0) | `Endpoint=sb://127.0.0.1:5672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=<any base64>;UseDevelopmentEmulator=true` — the exact form pinned in `verification/ts/wf3` (pre-reset `test/sdk-smoke/amqp.test.cjs`, RETIRED@64f6099). |
| Event Hubs emulator (+ MSSQL) | 5671/5672 | `:5673` | `sb://127.0.0.1:5673` (AMQP 1.0, `:eh` lane) | Same conn-str form pointed at 5673: `Endpoint=sb://127.0.0.1:5673;SharedAccessKeyName=...;SharedAccessKey=<any>;UseDevelopmentEmulator=true`. Read the Event Hubs delta before relying on partition semantics. |
| — ARM control plane (no emulator equivalent) | — | `:9443` | `http://127.0.0.1:9443` | Bootstrap via `GET /metadata/endpoints`, token via `POST /oauth2/v2.0/token`, then point azurerm/azapi/ARM SDKs at the endpoint document's resource-manager URL. |
| — Egress data plane (no emulator equivalent) | — | `:8443` | `http://127.0.0.1:8443` | Sentinel DCR ingest + KQL, Resource Graph, Purview Atlas v2, Confidential Ledger, Attestation, Key Vault SKR, Event Grid CloudEvents ingest. |

Port overrides are application env only — `config/config.exs` keys
`:arm_port` (9443), `:egress_port` (8443), `:amqp_port` (5672),
`:event_hubs_port` (5673). No CLI flags.

## Migration steps

1. Stop the emulator containers; note the ports they served.
2. `just up` boots all four smalt surfaces (9443 / 8443 / 5672 / 5673).
3. Rewrite endpoints per the port map.
4. Service Bus: use the `UseDevelopmentEmulator=true` connection-string form
   pointed at `sb://127.0.0.1:5672`. Any shared-access key value is accepted;
   CBS verifies the SAS token's local HMAC signature, not a real Azure
   authority (reply status
   `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`).
5. Blob/Cosmos: point the SDK at the 8443 endpoint with any credential — smalt
   does not validate REST-plane credentials (see deltas).
6. ARM clients: mint a bearer token at
   `POST http://127.0.0.1:9443/oauth2/v2.0/token` (HS256, 1 h expiry, claims
   `oid`/`sub`/`tid`/`azp`), fetch `GET /metadata/endpoints`, and point the
   SDK's resource-manager endpoint at `http://127.0.0.1:9443`. `api-version`
   values must match `Smalt.Registry.api_versions/0` — latest-version-only
   enforcement.
7. Event Hubs: point the SDK at 5673 with the conn-str form above, after
   reading the Event Hubs delta.

## Known deltas (honest)

- **In-memory persistence.** All state lives in ETS (`Smalt.Store` GenServer):
  ARM resources, Cosmos docs, blobs, ledger, queues, EH
  partitions/checkpoints. A substrate restart loses everything. Emulators
  (Azurite on disk, Cosmos/ServiceBus/EH emulators on MSSQL) survive restarts;
  smalt does not. Script your seed data; LRO operation state
  (`Smalt.ArmGateway.LRO`, ETS) also dies with the process.
- **No TLS.** Smalt binds plain HTTP/TCP on 127.0.0.1 only
  (`lib/smalt/application.ex`, `lib/smalt/messaging/amqp/listener.ex` binds
  `ip: {127,0,0,1}`). Emulators offer self-signed HTTPS; SDKs that require
  https are not drop-in.
- **Credentials are not validated** on the REST planes (Blob/Cosmos accept any
  shared key; ARM accepts the locally-minted token). The AMQP lane verifies
  SAS token shape and local HMAC signature via `Smalt.Amqp.SasVerifier` — not
  against a real Azure authority.
- **Event Hubs wire gap.** The 5673 listener carries an `:eh` mode flag, but
  `Smalt.Amqp.Connection` never consults it: every non-`$cbs`/`management`
  address routes to `QueueStore`, `/eventhubs/`-addressed transfers never
  reach `Smalt.Messaging.EventHubs`, and `x-opt-sequence-number` is not
  stamped from EH monotonic sequences on this lane. Module-level EH semantics
  (monotonic sequences, checkpoint CAS, leases) are real and tested
  (`test/amqp/event_hubs_test.exs`, RETIRED@64f6099) but are not reachable over the 5673 wire.
  Do not migrate an `@azure/event-hubs` workload expecting partition-sequence
  parity.
- **.NET filetime ticks are Service Bus-dialect only.** Delivery annotations
  and session-lock attach properties carry
  `com.microsoft:locked-until-utc` as .NET filetime ticks (100ns since
  0001-01-01 UTC) via `Smalt.Amqp.DeliveryEncoder.filetime_from_ms/1`
  (`lib/smalt/messaging/amqp/delivery_encoder.ex`), alongside the
  `x-opt-locked-until` epoch-ms timestamp. All other timestamps stay epoch
  milliseconds (AMQP `{:timestamp, ms}`).
- **api-version enforcement is latest-only.** The ARM gateway accepts only
  `Smalt.Registry.latest_version/1` per type; real ARM and the emulators
  accept older api-versions.
- **Blob defaults are stricter than Azurite.** Containers are created
  `immutable: true` with 1095-day retention by default
  (`lib/smalt/data_plane/blob_storage.ex`); overwrites under legal hold or a
  locked policy return 409 `ContainerLocked`. `immutabilityPeriodSinceCreationInDays`
  is clamped to an integer 0..146000 days (Azure's max), else 400
  `InvalidXmlDocument`. Azurite enforces immutability
  only when policies are configured.
- **Cosmos surface is point operations only** (create/get/list/put/delete
  docs). No SQL query engine — the Cosmos emulator supports
  `SELECT ... FROM c`. Sentinel's KQL engine is a separate 8443 surface.
- **Cosmos partition-key enforcement** requires `x-ms-documentdb-partitionkey`
  as a JSON array with exactly one non-empty string; the emulator tolerates
  broader forms.
- **Event Grid ingest is CloudEvents 1.0 JSON** over
  `POST/GET /topics/:topic/events`. Filter/subscription/delivery-to-handler
  semantics are not implemented; listing is insertion-order via a stored
  `seq`.
- **Egress fail-closed.** If a sibling data-plane module is not compiled, the
  route answers `503 {"error":{"code":"RouteNotReady"}}` rather than 200-empty
  (`lib/smalt/egress_router.ex`).

<details>
<summary>Replay greps</summary>

```sh
# Ports from application env
grep -n "arm_port\|egress_port\|amqp_port\|event_hubs_port" \
  lib/smalt/application.ex lib/smalt/registry.ex

# Connection-string form pinned by the SDK smoke tier
grep -rn "UseDevelopmentEmulator\|Endpoint=sb://" verification/ts/

# Loopback-only, no TLS
grep -n "scheme: :http" lib/smalt/application.ex
grep -n "127, 0, 0, 1" lib/smalt/messaging/amqp/listener.ex

# In-memory store tables
grep -n "@tables" -A30 lib/smalt/store.ex

# Latest-only api-version enforcement
grep -n "latest_version\|InvalidApiVersionParameter" lib/smalt/arm_gateway/router.ex

# EH wire gap: the mode flag is never consulted by the connection
grep -n "mode" lib/smalt/messaging/amqp/connection.ex

# Blob default immutability + retention
grep -n "immutable\|retention_days" lib/smalt/data_plane/blob_storage.ex
```

</details>
