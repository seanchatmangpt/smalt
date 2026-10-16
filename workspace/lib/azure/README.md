# workspace/lib/azure — pure-Azure client layer (lanes WS-8 + WS-9)

WS-8 owns the read-only ARM layer; WS-9 owns the data-plane client layer.
This README covers both. Auth shapes are witnessed against the emulator —
copied from `test/sdk-smoke/*.cjs` and `test/sdk-full/ts-reality.test.mjs`,
not invented.

## Modules

- `credential.ts` — `SmaltTokenCredential` (a `@azure/core-auth`
  TokenCredential). Mints ARM bearer tokens via the raw STS client_credentials
  POST (`POST {armBase}/{tenant}/oauth2/v2.0/token`), caches until
  `expires_in` minus a 60s refresh slack, single-flight on concurrent
  `getToken` calls. Raw POST is required because @azure/identity's
  ClientSecretCredential fails against the emulator (msal OIDC instance
  discovery is not served: `endpoints_resolution_error`; witnessed in
  docs/jira/v26.10.14/sdk-results/ts-arm-resources.md, constraint 1). On real
  Azure, swap for `ClientSecretCredential`.
- `arm-client.ts` — builds `ResourceManagementClient` with
  `{ endpoint: NEXT_PUBLIC_SMALT_ARM, apiVersion: "2021-04-01", allowInsecureConnection: true }`.
  api-version is pinned to the emulator's ceiling (the emulator is
  latest-version-only: newer api-versions are rejected 400
  InvalidApiVersionParameter).
- `resource-queries.ts` — typed read wrappers: `listSubscriptions` (GET
  /subscriptions), `listResourceGroups` (SDK list, GET
  /subscriptions/{sub}/resourcegroups), `listResourcesByRG` (subscription-level
  generic resource list filtered client-side, because the per-RG route
  `/resourcegroups/{rg}/resources` is missing on one substrate build —
  divergence D2, 404 RouteNotFound). No mutating export exists in this
  module — the mutation ban is enforced at the export surface (compile-time).

### WS-9 data-plane modules

- `blob-export.ts` — WORM receipt export (the air-gap export simulation).
  `BlobServiceClient` against `NEXT_PUBLIC_SMALT_EGRESS` (default
  `http://127.0.0.1:8443`), account `smaltacct`, with
  `StorageSharedKeyCredential("smaltacct", "smaltacct-key")` — real SharedKey
  request signing on the wire. Egress containers are immutable by default;
  `exportReceiptBundle` creates the container, uploads the bundle + export
  manifest, then re-uploads to prove the 409. Fails closed via
  `ImmutableOverwriteError` if an overwrite ever SUCCEEDS. Auth note
  (witnessed, `test/sdk-smoke/blob.test.cjs`): the JS SDK cannot inject the
  smalt STS Bearer on plain-HTTP storage (OAuth requires https; dual
  SharedKey+Bearer is not a supported SDK mode) — the enforce-mode Bearer
  contract is covered by `test/auth_enforce_test.exs` on the 9444 twin.
- `cosmos-manifest.ts` — mission manifests on the Cosmos NoSQL docs engine
  (`CosmosClient`, master key = any 64-char hex on the anonymous-mode
  substrate; real master-key Authorization header on the wire).
  **`SELECT * FROM c` ONLY** — the emulator's query surface enforces a SQL
  whitelist (full-document projections admitted; WHERE / projections /
  ORDER BY / aggregates are outside the admitted grammar). Manifests are
  small per-session docs read whole, so the whitelisted form covers the
  access pattern and no manifest read can ever be refused at the query
  gate. SDK v4 note: upsert lives on `container.items.upsert`, not the item
  handle (witnessed: `container.item(...).upsert is not a function`).
- `sb-telemetry.ts` — Service Bus telemetry. `ServiceBusClient` with an
  emulator connection string
  (`Endpoint=sb://127.0.0.1:5672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=<boot key>;UseDevelopmentEmulator=true`).
  Queues are provisioned by raw ARM PUT on :9443 — namespace PUT first (the
  smalt GraphLaw shape requires a flat `skuName`), then
  `/queues/:name?api-version=2021-04-01`. API-version must ride only on the
  final URL (witnessed: an api-version inherited into a mid-path PUT is
  parsed as part of the api-version string → 400 InvalidApiVersionParameter).
- `eh-stream.ts` — Event Hubs stream. `EventHubProducerClient` +
  `EventHubConsumerClient` with an emulator connection string carrying
  `EntityPath=<hub>` (mandatory). SDK v6 note: `startPosition` takes an
  EventPosition object (`{ offset: earliestEventPosition }`);
  `{ earliest: true }` is rejected at runtime (witnessed).

## Known wire divergences (witnessed live, not fixed in this lane)

- **SB plain-queue receive**: CBS auth, link attach, queue ensure and SDK
  send all resolve; no delivery ever arrives on receiver-link flow credit
  (`Smalt.Amqp.Connection` deliver path never dequeues) — per
  `docs/WIRE_PARITY.md`. Send-side is the witnessed contract.
- **SB session receive**: the session link DOES deliver and the body
  round-trips, but `sessionId` is not preserved on the delivered message
  (`undefined` on the wire; on one borrowed substrate build the delivered
  entry was a raw undecorated rhea AMQP message with no SDK `complete()`).
- **EH lane (5673) is PARTIAL**: `/eventhubs/` addresses route to
  QueueStore semantics and `$management` has no responder, so consumer
  bootstrap cannot complete (0 events received; on one build
  `getEventHubProperties` times out). Per `docs/WIRE_PARITY.md`.
- **Cosmos**: `PUT /dbs/:db` → 400 on the witnessed substrate, but the
  container route (`POST /dbs/:db/colls`) is mounted and the docs engine is
  permissive about the parent db entity. `createManifestStore` tolerates
  the db-route refusal. (One earlier substrate build mounted neither route;
  docs-first addressing is the portable path.)

## Probe

`workspace/scripts/azure-dataplane-probe.mjs` — plain `node` (Node ≥23
strips the lib TS types natively), runs all four WS-9 modules against a
live substrate with lane-unique names (`ws9-*`, Date.now() suffixes), so it
can reuse a running substrate read-only.

```sh
# boot-if-needed under the substrate lock:
flock -x -w 1200 /tmp/smalt-substrate.lock /tmp/ws9-boot-and-probe.sh

# or against an already-live substrate:
NEXT_PUBLIC_SMALT_EGRESS=http://127.0.0.1:8443 \
SMALT_WS9_SB_SHARED_KEY=<boot key> \
node workspace/scripts/azure-dataplane-probe.mjs
```

## WS-8 ARM client: boot-shape notes (witnessed 2026-10-15, lane WS-8)

- Bearer gate follows `Application.get_env(:smalt, :auth_mode)`:
  `config/config.exs` default `:enforce` (tokenless -> 401 MissingBearerToken),
  but `config/test.exs` sets `:anonymous` — a `MIX_ENV=test` substrate booted
  WITHOUT an explicit `put_env(:smalt, :auth_mode, :enforce)` accepts
  tokenless AND tampered bearer requests. Probes pinning auth rows must pin
  `:enforce` at boot or those rows are vacuous.
- `GET /subscriptions/{sub}/resources` (subscription-level generic resource
  list) is MISSING on the emulator (404 RouteNotFound, raw-GET witnessed) —
  same divergence family as the per-RG route (D2 in
  docs/jira/v26.10.14/sdk-results/ts-arm-resources.md). The witnessed generic
  read is `GET /subscriptions/{sub}/providers` (200 resourceTypes inventory);
  `listResourcesByRG` reads that inventory and documents the substitution.
- The SDK tier must ride the TLS twin (`https://localhost:9444`):
  @azure/core-rest-pipeline refuses Bearer auth over plain HTTP
  ("Bearer token authentication is not permitted for non-TLS protected
  (non-https) URLs", witnessed). :9443 is HTTP in this boot shape; :9444 is
  HTTPS and dispatches to the same ARM plane.
- Raw-fetch reads (STS mint, /subscriptions) work over plain HTTP :9443.
