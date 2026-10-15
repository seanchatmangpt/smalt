# Wire Parity

Status vocabulary: **ALIVE** = implemented in `lib/` and pinned by a real test
(unit or wire tier); **PARTIAL** = implemented but with a named gap (gap named
inline); **PLANNED** = documented intent only, no code. Every row names the test
file that pins it. Claims re-derived from the code as of 2026-10-15 (post-gap-fix-wave
refresh); the collapsible sections carry the exact replay commands.

<details>
<summary>Replay: module inventory greps</summary>

```sh
# AMQP stack modules
grep -rn "defmodule Smalt.Amqp\|defmodule Smalt.Messaging" lib/smalt/messaging/

# Key Vault crypto action functions
grep -n "def encrypt\|def decrypt\|def sign\|def verify\|def wrap_key\|def unwrap_key\|def list_keys\|def list_versions" \
  lib/smalt/data_plane/key_vault_actions.ex

# Key Vault crypto action routes (wire tier)
grep -n "KeyVaultActions" lib/smalt/egress_router.ex

# BlobService container surfaces (module tier)
grep -n "def list_containers\|def list_containers_xml\|def set_container_metadata\|def get_container_metadata\|def get_container_properties" \
  lib/smalt/data_plane/blob_service.ex

# BlobService wire wiring — expect matches in EgressRouter (comp=list /
# comp=metadata / restype=container routes)
grep -rn "BlobService\|blob_service" lib/smalt/egress_router.ex | head -5

# KQL engine operators
grep -n "apply_stage\|@comparison_atoms" lib/smalt/data_plane/kql.ex

# Sentinel KQL routing (only when a filtering operator is present)
grep -n "where|order" lib/smalt/data_plane/sentinel.ex
grep -rn '|\\s*(where|order' lib/smalt/data_plane/sentinel.ex

# Resource Graph KQL pipeline
grep -n "where.*order by.*project\|normalize\|project" lib/smalt/data_plane/resource_graph.ex

# ARM child resources (SB/EH queues/topics/hubs) — expect matches
# (handle_parented_child routes)
grep -c "namespaces/:parent/queues\|namespaces/:parent/topics\|eventhubs" lib/smalt/arm_gateway/router.ex

# Event Hubs wire routing in the AMQP connection
grep -n "mode == :eh\|eventhubs\|deliver_eventhubs\|x-opt-sequence-number" \
  lib/smalt/messaging/amqp/connection.ex

# SASL outcome descriptor 0x44
grep -n "sasl_outcome: 0x" lib/smalt/messaging/amqp/frame_codec.ex

# Boolean-immediate decode (0x41 true / 0x42 false)
grep -n "decode_value(<<0x41\|decode_value(<<0x42\|boolean-immediate" \
  lib/smalt/messaging/amqp/primitive_codec.ex

# LRO-async types
grep -n "storageAccounts\|virtualMachines" lib/smalt/arm_gateway/router.ex | grep -i lro
sed -n '483,486p' lib/smalt/arm_gateway/router.ex

# ARM control plane TLS listener (:9444)
grep -n "arm_tls_opts\|arm_tls_port" lib/smalt/application.ex

# Admitted resource types (count = 38)
awk 'NR>=12 && NR<=49' lib/smalt/registry.ex | grep -c Microsoft

# .NET filetime ticks: Service Bus session-lock dialect (expect: matches in
# lib/smalt/messaging/amqp/delivery_encoder.ex and runtime_contracts)
grep -rn "filetime" lib/smalt/messaging lib/smalt/runtime_contracts

# Auth enforcement: bearer plug + throttle + cosmos master-key gate
grep -n "plug(Smalt.Auth.Bearer)" lib/smalt/arm_gateway/router.ex lib/smalt/egress_router.ex
grep -n "arm_throttle\|Retry-After" lib/smalt/arm_gateway/router.ex | head -3
grep -n "master_key\|string-to-sign\|cosmos_ru_limit" lib/smalt/data_plane/cosmos.ex | head -5

# SKR real material + jti replay
grep -n "jti\|TokenReplay\|RSA-OAEP-256\|skr_recipient_jwk" lib/smalt/data_plane/skr.ex | head -8

# Blob wire: HEAD routes + marker pagination
grep -n "HEAD blob\|HEAD container\|\"marker\" => conn.query_params" lib/smalt/egress_router.ex

# Cosmos bootstrap + query POST
grep -n "account bootstrap\|application/query+json\|def query_docs" lib/smalt/data_plane/cosmos.ex
```

</details>

## Surface map

| Service | Surface (route / protocol) | Status | Pinned by (falsifier) |
|---|---|---|---|
| ARM control plane (38 admitted resource types) | HTTP `:9443` (`Smalt.ArmGateway.Router`): STS `POST /oauth2/v2.0/token` (+ `/oauth2/v2.0/token` under any `/:tenant_id`), discovery (`/metadata/endpoints`, `/common/discovery/instance`, `/.well-known/openid-configuration`, `/[tenant]/v2.0/.well-known/openid-configuration`), `/tenants`, `/subscriptions[/:id]`, resource groups (case-normalized `resourcegroups`/`resourceGroups`), provider PUT/GET/LIST/DELETE, child resources (subnets, vault keys, blobServices/default, containers, immutabilityPolicies), azapi POST actions (`.../lock`, `.../setLegalHold`), LRO (202 + `Azure-AsyncOperation` for `Microsoft.Storage/storageAccounts` and `Microsoft.Compute/virtualMachines`, polled at `/subscriptions/:sub/operations/:op_id`); wire-level response headers/envelope: `x-ms-request-id` echoed (or minted) on every response, error envelopes carry `innererror`, resource PUT/GET bodies carry synthetic fixed `systemData`, LIST responses paginate with an absolute `nextLink` past 100 items | ALIVE | `test/wire/arm_wire_test.exs`, `test/smalt_arm_gateway_test.exs`, `test/route_negative_test.exs` |
| ARM control plane TLS | HTTPS `:9444` via `Smalt.TLS.bandit_opts/2` + `arm_tls_opts/0` in `Smalt.Application`: TLS 1.2, self-signed dev cert auto-generated into `tmp/` by default (`config :smalt, :tls, :auto`), explicit `:tls_certfile`/`:tls_keyfile` honored when both exist, `:tls, false` disables | ALIVE | `test/tls_test.exs` |
| TLS twin data-plane dispatch | HTTPS `:9444` dispatches by path prefix (`TlsTwinDispatch` in `lib/smalt/application.ex`): `/attest/`, `/app/`, `/dbs/`, `/keys`, `/topics/`, `/atlas/`, `/dataCollectionRules`, `/v1/`, `/providers/` route to `Smalt.EgressRouter` — the Key Vault key surface (`/keys...`) and the other egress planes are servable over TLS 1.2 on the twin, not only plain-HTTP `:8443` | ALIVE | `test/kv_tls_test.exs` |
| Auth enforcement | `Smalt.Auth.Bearer` plug mounted on both HTTP planes (`arm_gateway/router.ex`, `egress_router.ex`): `auth_mode :enforce` (default) requires HS256 Bearer signed with the STS secret, `exp`/`aud` checked, and `iss` matched against the request-authority-derived
issuer (`<scheme>://<host:port>/` of the incoming request — the same
derivation the STS uses, so tokens minted on one authority do not replay on
another), 401 + ARM envelope + `WWW-Authenticate` on failure; `:anonymous` opts out; exempt prefixes `/oauth2/`, `/.well-known/`, `/common/discovery/`, `/attest/`, `/metadata/endpoints`, `/tenant(s)`. Cosmos plane additionally validates master-key Authorization (real string-to-sign HMAC-SHA256) when `:cosmos_master_key` is set, plus optional RU fixed-window throttle; ARM plane applies a fixed-window 429 throttle with `Retry-After` | ALIVE | `test/auth_enforce_test.exs`, `test/compliance/c6_oauth.exs` |
| ARM throttle | fixed-window (1 s) ARM-wide throttle -> 429 + `Retry-After` past the configured budget (`arm_throttle/2` in `Smalt.ArmGateway.Router`) | ALIVE | `test/compliance/c1_arm.exs` |
| ARM api-version gate | `api-version` query param required on typed routes; validated against `Smalt.Registry.latest_version/1`; missing -> 400 `MissingApiVersionParameter`, mismatch -> 400 `InvalidApiVersionParameter` naming the latest supported version | ALIVE | `test/smalt_arm_gateway_test.exs` |
| ARM GraphLaw refusal | unadmitted resource type or shape-constraint violation -> HTTP 400 with envelope code `InvalidResourceShape`, target `AshGraphLaw.Enforcement` (pinned decision: ARM never returns 422); non-vacuity proven by `scripts/mutation_court.py` (gate-present / gate-absent / byte-exact restore phases) | ALIVE | `test/smalt_arm_gateway_test.exs`, `scripts/mutation_court.py` |
| Key Vault crypto actions | HTTP `:8443`: `POST /keys/:name/{encrypt,decrypt,sign,verify,wrapKey,unwrapKey}` (case-insensitive suffix matching in `EgressRouter`, mounted after the literal `/keys/:name/create` route), `GET /keys`, `GET /keys/:name/versions`; RSA-OAEP-256 / RS256 / PS256 over a per-key 2048-bit RSA pair, A256GCM for `oct` keys (random 12-byte IV), ops gated on the key's release policy `allowed_operations` -> 400 `OperationNotAllowed`; module `Smalt.DataPlane.KeyVaultActions` | ALIVE | `test/data_plane/key_vault_actions_test.exs` (encrypt/decrypt round-trip, RSA non-determinism, sign/verify, policy gate) |
| Key Vault / Managed HSM SKR | HTTP `:8443`: `POST /keys/:name/create`, `GET /keys/:name`, `POST /keys/:name/release`; release gated on header `x-ms-compliance-status: azure-compliant-cvm` or a real RS256 MAA JWT Bearer; 403 `UnauthorizedAttestation`, 400 `KeyNotExportable` (no release policy), 404 `KeyNotFound`. **Real material**: released material is wrapped to the attested recipient — when the token carries an RSA `skr_recipient_jwk` claim, the material is encrypted with RSA-OAEP-256 to that key (mode `attested-recipient`); single-use nonce: a jti under `x-ms-runtime.jti` is consumed once (Store `:smalt_attestation_baseline`, `skr-jti:` keys), replay -> 403 `TokenReplay`. Compliance is accepted in both the flat form (`x-ms-compliance-status` top-level claim) and the **nested MAA form** (`x-ms-runtime` / `x-ms-compliance-status` objects); `skr_recipient_jwk` requires real JWK `n`/`e` fields (base64url, unpadded; standard base64 accepted on input); released material and all Key Vault crypto-action wire fields (`value`/`digest`/`signature`/`iv`/`tag`) are **base64url without padding**; release policies accept the Azure grammar — `anyOf`/`allOf` structures over `claim`/`equals` matchers, stored verbatim, in addition to smalt's flat `allowed_operations` list | ALIVE | `test/wire/egress_wire_test.exs`, `test/smalt_egress_router_test.exs`, `test/compliance/c2_keyvault.exs` |
| BlobService (account plane) | Module `Smalt.DataPlane.BlobService` plus wire wiring in `Smalt.EgressRouter`: `GET /{account}?comp=list` (marker pagination + `maxresults` + prefix, EnumerationResults XML), container metadata PUT/GET (`?comp=metadata`), container properties GET (`?restype=container`), **HEAD blob/container** (header-only, content-length set) | ALIVE | `test/data_plane/blob_service_test.exs`, `test/egress_wiring_test.exs` |
| Confidential Ledger | HTTP `:8443`: `POST /app/transactions`, `GET /app/transactions/:tx_id`, `GET /app/transactions/latest`; Merkle append + receipts via `Smalt.Security.ConfidentialLedger` | ALIVE | `test/smalt_services_test.exs` (Merkle receipt test), `test/wire/egress_wire_test.exs` |
| Attestation (MAA) | HTTP `:8443`: `POST /attest/:type` -> `Smalt.Security.Attestation.attest_enclave/1` (JWT) | ALIVE | `test/smalt_services_test.exs` (JWT attestation test) |
| Event Grid ingest | HTTP `:8443`: `POST/GET /topics/:topic/events`; CloudEvents 1.0 validation (`specversion` = `"1.0"`, non-empty `source`/`type`; UUID stamped when `id` absent); publish answers **200 with an empty body** by default (real Event Grid form; legacy list form still available); insertion-order listing via stored `seq` | ALIVE | `test/smalt_services_test.exs` (CloudEvents test), `test/wire/egress_wire_test.exs` |
| Blob Storage | HTTP `:8443`: guarded catch-all `PUT/GET/DELETE /{account}/{container}[/{blob}]`; ETag, If-Match 412, WORM refusal (legal hold or locked immutability policy -> 409 `ContainerLocked`), XML blob listing, delete 202 with `x-ms-request-id`; oversized puts answer 413 `RequestBodyTooLarge` (JSON error envelope), blob PUT answers a metadata-only JSON body (name/etag/size/content-type projection — raw bytes never reach the JSON encoder); policy set/lock API in `Smalt.DataPlane.BlobStorage` | ALIVE | `test/data_plane/blob_hardening_test.exs`, `test/wire/egress_wire_test.exs`, `test/sdk-smoke/blob.test.cjs` |
| Sentinel / Log Analytics | HTTP `:8443`: `POST /dataCollectionRules/:dcr/streams/:stream?api-version=2023-01-01`, `POST /v1/workspaces/:id/query`; queries containing `| where` / `| order by` / `| project` route into the `Smalt.DataPlane.KQL` engine (deterministic AST: `where` with `==`/`!=`/`contains`/`startswith`/`>`/`<`/`>=`/`<=` + `and`/`or`, `take` max 1000, `order by ... asc/desc`, `project`); ingest answers **204 No Content** (real Log Analytics form, empty body); query envelopes preserve `project` column **order** and carry per-column **`type`** (typed columns, stringified values); non-pipeline queries take the legacy path (`take` max 101, five enrichment columns incl. `sha256Hash`) | ALIVE | `test/data_plane/kql_test.exs`, `test/data_plane/audit_planes_test.exs` |
| Resource Graph | HTTP `:8443`: `POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`; optional KQL `where`/`order by`/`project` pipeline (leading `|` optional, per Resource Graph convention) applied over the subscription-filtered rows; response carries `resultTruncated: true` only when the filtered set exceeds the server record cap, `$skipToken` (under `options.$skipToken` and top-level) backed by `:smalt_resource_graph_tokens`; `options.$top`/`options.$skip` honored | ALIVE | `test/data_plane/audit_planes_test.exs`, `test/data_plane/kql_test.exs` |
| Purview (Atlas v2) | HTTP `:8443`: `POST /atlas/v2/entity`, `POST /atlas/v2/entity/bulk`, `GET /atlas/v2/entity/guid/:guid`, `GET /atlas/v2/lineage/:direction/:guid?depth=N` — lineage walks **stored** guid edges in Store `:smalt_purview_edges` (BFS to `depth`, entities resolved from `:smalt_purview_entities`; unknown guids degrade to `typeName: "Unknown"`, never fabricated guids) (module `Smalt.DataPlane.Purview`, file `lib/smalt/data_plane/purview_atlas.ex`) | ALIVE | `test/data_plane/audit_planes_test.exs` |
| Cosmos bootstrap + query | HTTP `:8443`: `GET /` account bootstrap (the `@azure/cosmos` SDK's first wire call) and `POST /dbs/:db/colls/:coll/docs` with `content-type: application/query+json` — partition-scoped query feed `{"_rid","Documents","_count"}`, honest 100-doc scan limit, never creates documents. `_rid` values follow the real Cosmos grammar — base64url-of-sha256 segments, db rid 8 chars, container rid = db rid + 4, doc rid = container rid + 8; bodies over the 8 MB-class limit answer 413 `RequestEntityTooLarge` | ALIVE | `test/compliance/c3_cosmos.exs`, `test/data_plane/cosmos_test.exs` |
| MCP read-only tool surface | HTTP `:9545` (`Smalt.Mcp.Router`): generated tool descriptor with `readOnlyHint: true`, backed by real Store reads; actuation-named tools refused by name, unknown tools refused; write attempts answered with a typed refusal, not silent success | ALIVE | `test/mcp_test.exs` |
| pplan durable tasks | `Smalt.PPlan.Task` over Store `:smalt_pplan_tasks`: court-validated `admitted -> running -> succeeded | failed` (terminal states absorb; refused edge raises typed refusal), exclusive claim via `Store.compare_and_swap/4`, `recover/0` re-admits tasks whose claimant died (kill-mid-transition chaos row) | ALIVE (module tier) | `test/pplan_test.exs` |
| OCEL event stack | `Smalt.Ocel.EventRegistry` + `Smalt.Ocel.Conformance` (fitness vs epsilon, deviations) + `Smalt.Ocel.DeviationAdmission` over the substrate event stream; rev-ops surface in `lib/smalt/ocel/revops/` | ALIVE (module tier) | `test/ocel_test.exs`, `test/ocel_conformance_test.exs`, `test/ocel_revops_test.exs` |
| SB/EH ARM children | queues/topics/subscriptions under `Microsoft.ServiceBus/namespaces`, eventhubs/consumergroups under `Microsoft.EventHub/namespaces`: PUT/GET/LIST/DELETE via `handle_parented_child` in `Smalt.ArmGateway.Router`; types admitted in `Smalt.Registry` (38 types) | ALIVE | `test/wire/arm_wire_test.exs`, `test/sb_children_test.exs` |
| AMQP 1.0 framing | TCP `:5672` (`Smalt.Amqp.Connection` + `Smalt.Amqp.FrameCodec` + `Smalt.Amqp.PrimitiveCodec`): protocol-header exchange, SASL `ANONYMOUS`, open (container `smalt-local`, max-frame 1 MiB) / begin / attach / flow / transfer / disposition / detach / end / close; malformed frames -> close with error condition. `sasl-outcome` descriptor is **0x44** (wire-lane fix from the real-SDK census; the earlier non-conforming descriptor broke real clients). Boolean-immediate constructors decoded: `0x41` -> `true`, `0x42` -> `false` (rhea/real SDKs emit these on attach `role`). | ALIVE | `test/amqp/frame_codec_test.exs`, `test/amqp/primitive_codec_test.exs`, `test/amqp/connection_test.exs`, `test/wire/amqp_wire_test.exs`, `test/sdk-smoke/amqp.test.cjs` |
| AMQP queue links | attach routing: `$cbs` -> CBS router, address containing `management` -> `$management`, else queue link; sender-side ingest settled `accepted` after store write; receiver delivery on flow credit with `delivery-tag` = lock token; attach without live CBS claim -> detach `amqp:unauthorized-access` / `UNAUTHORIZED_ENTITY` | ALIVE | `test/amqp/connection_test.exs` |
| Service Bus locks | message/session locks in `:smalt_sb_locks` / `:smalt_sb_sessions`; duration clamp 100-30000 ms (default 30000); unknown token -> `{:error, :not_found}` (management 404), expired -> `{:error, :lock_lost}` (410) | ALIVE | `test/amqp/lock_manager_test.exs` |
| Service Bus queues + DLQ | `:smalt_sb_queues` / `:smalt_sb_messages`; capacity 4096, max body 1 MiB, peek max 100; DLQ footer application properties `DeadLetterReason` / `DeadLetterErrorDescription` | ALIVE | `test/amqp/queue_store_test.exs`, `test/amqp/delivery_encoder_test.exs` |
| `$management` RPC | application-property `operation`: `com.microsoft:renew-lock`, `com.microsoft:renew-session-lock`, `com.microsoft:peek-message` (symbolic or bare); unknown -> 501 `UNSUPPORTED_OPERATION`; malformed -> 400 `MALFORMED_REQUEST`. Exact status tables below. | ALIVE | `test/amqp/management_rpc_test.exs`, `test/amqp/connection_test.exs` |
| `$cbs` put-token | see dialect table below; claim cache cap 128; queue-attach authorization enforced while the CBS process runs, open otherwise | ALIVE | `test/amqp/cbs_router_test.exs`, `test/amqp/sas_verifier_test.exs`, `test/amqp/connection_test.exs` |
| Service Bus over real AMQP wire | send + receive + complete round-trip over `:5672`; additionally an 8-probe real-SDK census (`@azure/service-bus`, fail-closed, zero skips) | ALIVE | `test/wire/amqp_wire_test.exs`, `test/sdk-smoke/amqp.test.cjs`, `test/sdk-smoke/census.test.cjs` (via `census-run.mjs`) |
| Event Hubs (module semantics) | `Smalt.Messaging.EventHubs` on ETS `:smalt_eh_partitions` / `:smalt_eh_checkpoints`: strictly monotonic per-partition sequence from 1, checkpoint compare-and-swap (`:ok` / `{:error, :conflict}`), processing leases (`reserve_processing/4` + `sweep/0`), `reconcile/2` | ALIVE (module tier) | `test/amqp/event_hubs_test.exs` |
| Event Hubs AMQP wire lane | TCP `:5673` listener (`Smalt.Messaging.EventHubs.Listener` -> `Smalt.Amqp.Listener` mode `:eh`) under `Smalt.AmqpBroker`. `Smalt.Amqp.Connection.route/2` now consults the mode flag: `mode == :eh` or an address containing `/eventhubs/` routes the link to `:eventhubs`, and `deliver_eventhubs/2` serves deliveries stamped with `x-opt-sequence-number` from the EH monotonic sequences. Pinned on the real wire by the `@azure/event-hubs` SDK smoke (getProperties / sendBatch / subscribe). | ALIVE | `test/amqp/event_hubs_test.exs` (module), `test/sdk-smoke/eventhubs.test.cjs` via `eh-run.mjs` (wire); `test/wire/amqp_wire_test.exs` pins the `:sb` lane |
| Event Hubs SDK smoke | `test/sdk-smoke/eventhubs.test.cjs` + `eh-run.mjs`: real `@azure/event-hubs` 6.0.4 over the 5673 lane, fail-closed, zero skips (exits 3 when `SMALT_SDK_ROOT` is missing rather than silently passing) | ALIVE | `test/sdk-smoke/eventhubs.test.cjs` |

## Pinned dialect details

### CBS (`$cbs`) put-token

Implemented in `Smalt.Amqp.CbsRouter` and `Smalt.Amqp.Connection`.

| Aspect | Pin |
|---|---|
| CBS type | `servicebus.windows.net:sastoken` (exact; anything else -> 400 `UNSUPPORTED_CBS_REQUEST`) |
| Operations | `put-token`, `delete-token` (delete via connection returns 200 `OK` directly; router path returns 200 `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`) |
| Status table | 200 `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY` · 400 `UNSUPPORTED_CBS_REQUEST` · 400 `INVALID_CBS_BODY` · 401 `INVALID_LOCAL_SAS` · 429 `CLAIM_CAPACITY` (cap 128 active claims) |
| Reply-to link name | reply is routed to the link whose **name** equals the request's application-property `reply-to` (`find_reply_link/3` in `lib/smalt/messaging/amqp/connection.ex`); fallback: any `$cbs` sender-role link; reply carries message annotation `x-opt-status-code` and amqp-value body `%{"statusCode" => n, "statusDescription" => s}` |
| Claim cache | key `{owner_ref, audience}`; expiry = min(request `expiration`, token `se`); `gc/0` reaps expired; put-token SAS verified by `Smalt.Amqp.SasVerifier` (HMAC local signature; `skn` must be accepted, `se` must be unexpired, `sr` audience-checked) |

### `$management` status tables (exact)

| Operation | Success | Failure |
|---|---|---|
| `com.microsoft:renew-lock` | 200 `{"expirations": [ts]}` (each ts = `{:timestamp, ms}`) | 400 `LOCK_TOKEN_REQUIRED` · 410 `MESSAGE_LOCK_LOST` |
| `com.microsoft:renew-session-lock` | 200 `{"expiration": ts}` | 400 `SESSION_ID_REQUIRED` · 410 `SESSION_LOCK_LOST` |
| `com.microsoft:peek-message` | 200 `{"messages": [...]}` · 204 `NO_CONTENT` on empty | 400 `PEEK_BOUNDS` (from-sequence-number unparseable, or message-count outside 1..100) · 404 `NOT_FOUND` (store error) |
| unknown operation | — | 501 `UNSUPPORTED_OPERATION` |
| malformed request | — | 400 `MALFORMED_REQUEST` |

Pinned by `test/amqp/management_rpc_test.exs` (tables) and
`test/amqp/connection_test.exs` (wire tier). Timestamps are AMQP
`{:timestamp, milliseconds since epoch}` per `Smalt.Amqp.PrimitiveCodec`.

### x-opt-* message annotations

From `Smalt.Amqp.DeliveryEncoder.build_sections/1`
(pinned by `test/amqp/delivery_encoder_test.exs`):

| Annotation | Wire type | Presence |
|---|---|---|
| `x-opt-sequence-number` | ulong | always on broker queue deliveries; on EH wire deliveries, stamped from the EH monotonic per-partition sequence (`deliver_eventhubs/2`) |
| `x-opt-locked-until` | AMQP timestamp (ms) | when a lock is held |
| `x-opt-enqueued-time-utc` | AMQP timestamp (ms) | always |
| `x-opt-session-id` | binary | only when session is set |
| `x-opt-status-code` | — | `$cbs` / `$management` RPC replies only (connection layer) |

These are AMQP epoch-millisecond timestamps. The **Service Bus session-lock
dialect additionally carries .NET filetime ticks**: `com.microsoft:
locked-until-utc` is emitted as a ulong of 100-ns intervals since
0001-01-01 via `Smalt.Amqp.DeliveryEncoder.filetime_from_ms/1` (pinned by
`test/amqp/delivery_encoder_test.exs` and the runtime-contract check in
`lib/smalt/runtime_contracts/amqp_dialect.ex`), while `x-opt-*` annotations
stay in epoch ms.

### Settlement mapping

From `Smalt.Amqp.Connection.handle_disposition/2`
(pinned by `test/amqp/connection_test.exs`, `test/amqp/queue_store_test.exs`):

| Client disposition state | Store transition |
|---|---|
| `accepted` | `QueueStore.complete/1` |
| `released` | `QueueStore.release/2` |
| `modified` with `undeliverable-here` = true | `QueueStore.defer/3` |
| `modified` otherwise | `QueueStore.release/2` |
| `rejected` | `QueueStore.deadletter` (reason `rejected`) |
| other / absent state | `release` |
| sender-side ingest | settled `accepted` after store write |

### Locks

| Aspect | Pin |
|---|---|
| Duration clamp | 100-30000 ms, default 30000 (`Smalt.Amqp.LockManager.clamp_duration/1`) |
| Renew, unknown token | `{:error, :not_found}` -> management 404 |
| Renew, expired token | `{:error, :lock_lost}` -> management 410 |
| Session lock renew | `Smalt.Amqp.LockManager.renew_session_lock/3` -> 200 `{"expiration": ts}` / 410 `SESSION_LOCK_LOST` |

## Coverage boundaries (honest)

- Cosmos DB: point operations plus partition-scoped query POST
  (`application/query+json`, honest 100-doc scan limit). No full SQL
  translator (`SELECT ... FROM c` is not parsed).
- SDK smoke coverage: arm, amqp, blob, cosmos, **service-bus census**,
  **event-hubs**. No SDK harness for Sentinel, Purview, Ledger, Attestation,
  Key Vault, or Resource Graph.
- The egress router fails closed with
  `503 {"error":{"code":"RouteNotReady"}}` when a sibling data-plane module is
  not compiled, rather than answering 200-empty.
