# Changelog

All notable changes to smalt are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Calendar Versioning](https://calver.org/) (`YY.0M.MICRO`, e.g. `26.10.14`).

## [26.10.14] - 2026-10-14

First release. Smalt as a local Azure drop-in substrate on the BEAM: an
in-process replacement for the official Azure emulator containers, plus
control-plane and audit-plane surfaces no emulator provides.

### Added

#### ARM control plane (HTTP `:9443`)

- `Smalt.ArmGateway.Router`: STS token minting
  (`POST /oauth2/v2.0/token`, HS256, 1 h expiry), endpoint discovery
  (`/metadata/endpoints`, `/common/discovery/instance`,
  `/.well-known/openid-configuration`, tenant-scoped variants), `/tenants`,
  `/subscriptions[/:id]`, resource groups, provider PUT/GET/LIST/DELETE for 38
  admitted resource types (shapes + api-versions in `Smalt.Registry`),
  child resources (subnets, vault keys, blobServices/default, containers,
  immutabilityPolicies), azapi POST actions (`.../lock`, `.../setLegalHold`).
- ARM control-plane TLS: HTTPS listener on `:9444` (`Smalt.TLS.bandit_opts/2`),
  TLS 1.2, self-signed dev cert auto-generated into `tmp/` by default
  (`config :smalt, :tls, :auto`), explicit certs honored, `:tls, false`
  disables. Pinned by `test/tls_test.exs`.
- Long-running operations: 202 + `Azure-AsyncOperation` polling for
  `Microsoft.Storage/storageAccounts` and
  `Microsoft.Compute/virtualMachines` (`Smalt.ArmGateway.LRO`).
- `api-version` gate: required on typed routes, latest-version-only
  enforcement against `Smalt.Registry.latest_version/1`; missing ->
  400 `MissingApiVersionParameter`, mismatch -> 400
  `InvalidApiVersionParameter`.
- GraphLaw refusal: unadmitted resource type or shape-constraint violation
  -> 400 envelope `InvalidResourceShape`, target `AshGraphLaw.Enforcement`
  (ARM never returns 422); non-vacuity proven by `scripts/mutation_court.py`
  (gate-present / gate-absent / byte-exact restore phases).
- SB/EH messaging child resources under namespaces: Service Bus
  `namespaces/:ns/{queues,topics}`, `topics/:t/subscriptions`, Event Hubs
  `namespaces/:ns/eventhubs[/:hub/consumergroups]` — full PUT/GET/LIST/DELETE
  via `handle_parented_child` in `Smalt.ArmGateway.Router`. Pinned by
  `test/wire/arm_wire_test.exs`.
- BlobService wire wiring in `Smalt.EgressRouter`: container list
  (`?comp=list`), container metadata PUT/GET (`?comp=metadata`), container
  properties GET (`?restype=container`). Pinned by `test/egress_wiring_test.exs`.
- ARM wire parity: `x-ms-request-id` echoed (or minted) on every response,
  error envelopes carry `innererror`, resource bodies carry synthetic fixed
  `systemData`, LIST responses paginate with an absolute `nextLink` past 100
  items. Pinned by `test/compliance/c1_arm.exs`.
- Pinned by `test/wire/arm_wire_test.exs`, `test/smalt_arm_gateway_test.exs`,
  `test/route_negative_test.exs`.

#### Egress data plane (HTTP `:8443`)

- Cosmos DB NoSQL point operations (`/dbs/:db/colls/:coll/docs[/:doc_id]`)
  with `_etag`/`_ts`/`_rid`/`_self` system properties, If-Match 412,
  partition-key enforcement via `Smalt.DataPlane.PartitionKey`. `_rid`
  values follow the real Cosmos grammar (base64url-of-sha256 segments: db
  rid 8 chars, container rid = db rid + 4, doc rid = container rid + 8);
  oversized bodies answer 413 `RequestEntityTooLarge`.
- Key Vault / Managed HSM SKR: key create/get/release gated on
  `x-ms-compliance-status: azure-compliant-cvm` or a real RS256 MAA JWT
  Bearer (403 `UnauthorizedAttestation`, 400 `KeyNotExportable`, 404
  `KeyNotFound`). Released material is real: wrapped RSA-OAEP-256 to the
  token's RSA `skr_recipient_jwk` claim when present
  (`attested-recipient` mode), and single-use — a jti under
  `x-ms-runtime.jti` is consumed once (Store `:smalt_attestation_baseline`);
  replay is refused with 403 `TokenReplay`. Compliance is accepted in both
  the flat claim form and the real nested MAA form (`x-ms-runtime` /
  `x-ms-compliance-status` objects); `skr_recipient_jwk` requires real JWK
  `n`/`e` fields; released material and all Key Vault crypto-action wire
  fields are base64url without padding; release policies accept the Azure
  `anyOf`/`allOf` over `claim`/`equals` grammar (stored verbatim) alongside
  smalt's flat `allowed_operations`.
- MCP read-only tool surface (`Smalt.Mcp.Router`, HTTP `:9545`): generated
  tool descriptor with `readOnlyHint: true`, real Store reads behind every
  tool; actuation-named and unknown tools refused by name — the surface
  carries no write path.
- Durable P-PLAN task store (`Smalt.PPlan.Task` over Store
  `:smalt_pplan_tasks`): court-validated `admitted -> running ->
  succeeded | failed` state machine (terminal states absorb; refused edge
  raises a typed refusal), exclusive claim via `Store.compare_and_swap/4`,
  crash recovery via `recover/0` (kill-mid-transition chaos row pinned).
- OCEL event stack (`lib/smalt/ocel/`): object-centric event registry,
  conformance check (fitness vs `epsilon`, deviations), deviation admission,
  and a rev-ops surface over the substrate's own event stream.
- Semantic projection surface (`lib/smalt/projection/` +
  `lib/smalt/semantic/`): canonical registry projection, projection
  admission matrix, semantic epoch; R2RML/ex4pm-style mappings in
  `lib/smalt/semantic/`. See `docs/SEMANTIC_PROJECTION.md`.
- `smaltctl` CLI (`cli/`): Rust control-plane CLI (blob put/get/list/delete,
  cosmos query, kv create, court/doctor runners) generated from
  `cli/ontology.ttl` via the clap-noun-verb pack; `cargo test` green.
- Cosmos DB account bootstrap (`GET /`) and partition-scoped query POST
  (`application/query+json`, feed `{"_rid","Documents","_count"}`, honest
  100-doc scan limit, never creates documents).
- Blob wire parity: `HEAD` blob/container routes (header-only, content-length
  set) and marker pagination on the container-list wire routes; oversized
  puts answer 413 `RequestBodyTooLarge` and blob PUT answers a metadata-only
  JSON body (raw bytes never reach the JSON encoder).
- TLS twin data-plane dispatch: `:9444` routes egress prefixes (`/keys`,
  `/dbs/`, `/app/`, `/attest/`, `/topics/`, `/atlas/`, `/dataCollectionRules`,
  `/v1/`, `/providers/`) to `Smalt.EgressRouter` (`TlsTwinDispatch`), so the
  Key Vault surface and sibling planes are servable over TLS 1.2 on the twin.
  Pinned by `test/kv_tls_test.exs`.
- Key Vault crypto actions (`Smalt.DataPlane.KeyVaultActions`):
  `POST /keys/:name/{encrypt,decrypt,sign,verify,wrapKey,unwrapKey}`
  (case-insensitive suffix), `GET /keys`, `GET /keys/:name/versions`;
  RSA-OAEP-256 / RS256 / PS256 over a per-key RSA-2048 pair cached in the key
  row, A256GCM for `oct` keys with random 12-byte IV (non-deterministic),
  operations gated on the key's release-policy `allowed_operations` list
  (400 `OperationNotAllowed`). Pinned by
  `test/data_plane/key_vault_actions_test.exs`.
- BlobService module (`Smalt.DataPlane.BlobService`): container listing with
  marker pagination / `maxresults` clamp / `prefix` / lexicographic order,
  EnumerationResults XML, container metadata PUT/GET (`x-ms-meta-*`), container
  properties GET; wire wiring in `Smalt.EgressRouter` (see ARM section).
  Pinned by `test/data_plane/blob_service_test.exs`.
- Confidential Ledger (`Smalt.Security.ConfidentialLedger`): Merkle append
  with receipts; Attestation (`Smalt.Security.Attestation`, JWT);
  receipt signing (`Smalt.Security.ReceiptSigner`).
- Event Grid ingest: CloudEvents 1.0 validation, insertion-order listing.
- Blob Storage (`Smalt.DataPlane.BlobStorage`): ETag/If-Match, WORM refusal
  (409 `ContainerLocked` under legal hold or locked immutability policy),
  XML listing, policy set/lock API; containers default
  `immutable: true`, 1095-day retention.
- Sentinel / Log Analytics: DCR-stream ingest + KQL query engine; queries
  containing `| where` / `| order by` / `| project` route into
  `Smalt.DataPlane.KQL` (deterministic AST: `where` with
  `==`/`!=`/`contains`/`startswith`/`>`/`<`/`>=`/`<=` + `and`/`or`,
  `take` max 1000, `order by`, `project`; caps on query length and AST depth).
  Ingest answers 204 No Content; query envelopes preserve `project` column
  order and carry typed per-column `type` fields. Pinned by
  `test/data_plane/kql_test.exs` and `audit_planes_test.exs`.
- Resource Graph with optional `where`/`order by`/`project` KQL pipeline
  (leading `|` optional) over subscription-filtered rows; `resultTruncated`
  only past the server record cap, `$skipToken` (also under
  `options.$skipToken`), `options.$top`/`$skip` honored. Pinned by
  `audit_planes_test.exs`.
- Purview Atlas v2 (entity/bulk/get/lineage) — lineage walks stored guid
  edges in Store `:smalt_purview_edges` (BFS to depth, unknown guids degrade
  to `typeName: "Unknown"`, never fabricated).
- Event Grid publish answers 200 with an empty body by default (real Event
  Grid wire form).
- Fail-closed routing: uncompiled sibling module answers
  `503 {"error":{"code":"RouteNotReady"}}`, never 200-empty.

#### AMQP 1.0 messaging (TCP `:5672`, Event Hubs lane `:5673`)

- `Smalt.Amqp.FrameCodec` + `Smalt.Amqp.Connection`: protocol-header
  exchange, SASL `ANONYMOUS`, open/begin/attach/flow/transfer/disposition/
  detach/end/close, malformed-frame close with error condition; container
  `smalt-local`, max-frame 1 MiB.
- `sasl-outcome` descriptor fixed to **0x44** (real-SDK census finding; the
  earlier non-conforming descriptor broke real clients). Pinned by
  `test/amqp/frame_codec_test.exs`.
- Service Bus session-lock expiry carries the `.NET filetime` ticks
  (`com.microsoft:locked-until-utc`, 100 ns intervals since 0001-01-01) via
  `Smalt.Messaging.Amqp.DeliveryEncoder.filetime_from_ms/1`, not epoch
  milliseconds. Pinned by `test/amqp/delivery_encoder_test.exs`.
- Boolean-immediate constructors decoded (`0x41` -> `true`, `0x42` -> `false`;
  rhea/real SDKs emit these on attach `role`). Pinned by
  `test/amqp/primitive_codec_test.exs`.
- Service Bus queues: capacity 4096, max body 1 MiB, peek max 100, DLQ with
  `DeadLetterReason` / `DeadLetterErrorDescription` footer properties.
- Message/session locks (`Smalt.Amqp.LockManager`): duration clamp
  100-30000 ms, renew with exact 404/410 status tables.
- `$management` RPC: `com.microsoft:renew-lock`, `renew-session-lock`,
  `peek-message` with exact status tables; 501 `UNSUPPORTED_OPERATION`.
- `$cbs` put-token: `servicebus.windows.net:sastoken`, SAS verified locally
  by `Smalt.Amqp.SasVerifier` (HMAC; reply status
  `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`), claim cache cap 128,
  429 `CLAIM_CAPACITY`.
- x-opt-* message annotations and full disposition->settlement mapping
  (accepted/released/modified/rejected -> complete/release/defer/deadletter).
- Event Hubs: module semantics on ETS `:smalt_eh_partitions` /
  `:smalt_eh_checkpoints` (`Smalt.Messaging.EventHubs`) — strictly monotonic
  per-partition sequences from 1, checkpoint CAS, processing leases,
  `reconcile/2` — **and the wire lane is routed**: `Smalt.Amqp.Connection`
  consults the listener mode flag (`mode == :eh` or address containing
  `/eventhubs/`) and `deliver_eventhubs/2` serves deliveries stamped with
  `x-opt-sequence-number` from EH monotonic sequences. Pinned by
  `test/amqp/event_hubs_test.exs` (module) and `test/sdk-smoke/eventhubs.test.cjs`
  via `eh-run.mjs` (wire, real `@azure/event-hubs`).

#### Security / substrate

- Auth enforcement (`Smalt.Auth.Bearer`): `auth_mode :enforce` (default)
  requires a valid HS256 Bearer on every non-exempt route of `:9443`/`:8443`
  (signature vs the STS secret, `exp`/`aud`/`iss` checked; 401 + ARM error
  envelope + `WWW-Authenticate` otherwise; `iss` is matched against the
  request-authority-derived issuer — cross-seat acceptance exists only for
  authorities the STS registered in its VM-local trusted set
  (`Smalt.Auth.Bearer.register_trusted_authority/1`), so a substrate restart
  wipes it: restart implies re-authentication); `:anonymous` opts out. Cosmos
  plane adds master-key Authorization validation (real string-to-sign
  HMAC-SHA256, `:cosmos_master_key`) and an optional RU fixed-window
  throttle; ARM plane adds a fixed-window 429 throttle with `Retry-After`.
  Pinned by `test/auth_enforce_test.exs`.
- TLS module `Smalt.TLS` (self-signed dev cert generation, cert/key resolution,
  bandit opts) and GraphLaw validation (`Smalt.GraphLaw.Validator`,
  N-Triples serializer); SHACL shapes at `priv/shacl/smalt-shapes.ttl`.
- In-memory store (`Smalt.Store` GenServer + ETS) — restart loses state
  (see `docs/MIGRATION_FROM_EMULATORS.md`, known deltas).
- Loopback-only binds.

#### Verification ladder + tooling

- Justfile gate tiers: `doctor` (diagnostic court), `test-offline` (T1),
  `test-wire` (T2), `test-sdk-smoke` (T3: real `@azure/...` JS SDK clients
  over loopback for arm, amqp, blob, cosmos, plus the 8-probe Service Bus
  census (`census.test.cjs`) and the Event Hubs SDK smoke
  (`eventhubs.test.cjs` via `eh-run.mjs`)), `tf-plan-smoke` (T4: terraform
  fixture plan against the live substrate), `bench-check` (perf CTQ gate:
  doctor <= 3 s, boot p95 <= 5 s, ARM PUT p95 < 50 ms, Cosmos p95 < 20 ms,
  AMQP first-frame < 100 ms, via `scripts/bench.py` + `bench_check.py`);
  `gate` runs all.
- Chaos tier: `test/chaos/` (`crash_isolation_test.exs` — real
  `Process.exit(pid, :kill)` of the Store GenServer with `:gen_tcp` probes;
  `port_collision_test.exs`) runs inside `mix test`, no mocks.
- CI (`.github/workflows/ci.yml`): ubuntu-latest + macos-14 matrix, Elixir
  1.18 / OTP 27, warnings-as-errors compile, unit+wire tests (incl. chaos),
  SDK smoke tier (incl. census), terraform fixture tier.
- Terraform provider shim `scripts/smalt-tf` and fixture under
  `test/terraform_fixture/`; `scripts/doctor.py` diagnostic court;
  `scripts/mutation_court.py` (GraphLaw gate non-vacuity);
  `scripts/bench.py` / `bench_check.py` (bench gate); `scripts/release.sh`.
- Docs: `docs/ARCHITECTURE.md`, `docs/WIRE_PARITY.md` (surface map with
  per-row falsifiers), `docs/MIGRATION_FROM_EMULATORS.md` (port map +
  honest deltas), `docs/CHEAT_SCAN.md`.

### Security

- Compliance courts c1-c7 (`test/compliance/`, receipts in
  `docs/compliance/`): live-wire per-service fences over real HTTP/AMQP
  transport (no doubles). Latest runs (re-run 2026-10-15, docs-corpus-lens3
  cycle 1, this tree): c1 ARM 25/0, c2 Key Vault 16/0, c3 Cosmos 23/0, c4 Blob
  28/0, c5 Service Bus 16/0 (`--include amqp_wire`), c6 OAuth/OIDC 18/0,
  c7 Event planes 16/0 — **142 tests, 0 failures**.
- Pack integrations (receipts in `docs/PACK_INTEGRATION/`): 15 packs
  consumed and receipted (ash-extension, ash-ocel-revops, ash-pplan,
  ashdspy, canonical-projection, clap-noun-verb, ea-projection,
  invariant-gate, mcp-a2a, otel-weaver, runtime-contracts, semantic-epoch,
  shacl-projection, strata-family, trust-plane); remaining candidates
  tracked in `REMAINING_CENSUS.md`.
- Stress suite (`scripts/stress/`, receipts in `docs/STRESS/`): soak,
  spike, TLS churn, AMQP throughput/fanout, ARM scale, blob scale, cosmos
  bulk, LRO storm, YCSB-lite, azurite comparison, telemetry overhead, chaos
  kill, gate cost; `just soak` / `just spike` / `just tls-churn`.
- Dependency audit (`docs/DEP_AUDIT.md`, 2026-10-14): bandit 1.12.5 ships
  with a known HIGH advisory — EEF-CVE-2026-105659 /
  [GHSA-69m6-wcv4-rwcf](https://github.com/advisories/GHSA-69m6-wcv4-rwcf)
  (HTTP/2 WINDOW_UPDATE stream-pin DoS against the HTTP/2 listener). No
  patched hex release exists yet; risk **accepted for this release** with the
  HTTP/2 listener loopback-only. Re-audit and `mix deps.update bandit` when a
  release newer than 1.12.5 lands.

[26.10.14]: https://github.com/placeholder/smalt/releases/tag/26.10.14

## [Unreleased]

Post-26.10.14 substrate laws, each probe/suite-pinned on this tree
(docs-corpus cycle 10, 2026-10-15):

- Auth: `x-forwarded-*` honored only from configured trusted proxies
  (`config :smalt, :trusted_proxies`, exact tuples or IPv4 CIDR), ignored
  fail-closed on direct connections; cross-seat mint authority is a VM-local
  trusted set — substrate restart wipes it (restart => re-authentication).
  Pinned by `test/auth_enforce_test.exs` (71 tests, 0 failures).
- GraphLaw: the shape gate fails closed — an admitted resource type with no
  compiled SHACL shape refuses validation (`{:refused, :no_shape}`) instead
  of validating against an implicit empty shape. Pinned by
  `test/smalt_graphlaw_validator_test.exs` "fail-closed shape resolution"
  (46 tests, 0 failures).
- Key Vault SKR: release-policy validation refuses any policy that is neither
  an Azure `anyOf`/`allOf`/`claim`/`equals` structure nor a flat
  `allowed_operations` list — `POST /keys/:name/create` answers 400
  `InvalidParameter` and the key is not stored (wire-probe verified).
- STS: `client_credentials` token requests require `client_id` AND
  `client_secret`; missing secret answers 400 `invalid_client` (RFC 6749
  §5.2). Pinned by `test/compliance/c6_oauth.exs`.
- Sentinel ingest: a null or scalar record anywhere in the batch is a
  request-level 400 `InvalidData` with no partial insert; the ingest 204
  carries `x-ms-request-id` in the dashed RFC 4122 GUID form real Azure
  emits (unified with the ARM plane). Pinned by
  `test/data_plane/audit_planes_test.exs`.
- Ledger receipts: `Smalt.Security.ReceiptSigner.verify_token/1` enforces an
  optional `nbf` claim (present-but-future -> typed `:token_not_yet_valid`;
  `nbf == now` accepted). Pinned by
  `test/security/security_hardening_test.exs:164`.
- Ledger appends: opt-in `config :smalt, :ledger_enforce_existence: true`
  flips appends to a never-created ledger to the 404-class envelope (real
  Azure form); the fence runs inside the serialized writer (first-writer-
  creates under concurrency). Pinned by
  `test/security/security_hardening_test.exs`.
- Container PUT: 201 create answers a quoted `ETag`, RFC 1123 `Last-Modified`,
  `x-ms-request-id` + `x-ms-version`, and an empty body (real-Azure shape);
  `x-ms-meta-*` headers on Put Container set metadata at create, validated
  BEFORE the create (a refused create leaves no container behind). Pinned by
  `test/compliance/c4_blob.exs` and `test/data_plane/blob_service_test.exs`.
- Blob listings: `include=metadata` (comma-separated token list, exact-token
  match — a hostile token like `metadatabase` does not enable it) emits a
  `<Metadata>` element per blob from the stored `x-ms-meta-*` headers;
  unknown include tokens (`snapshots`/`versions`/`tags`) are typed
  UNSUPPORTED and never emit decoration. Pinned by
  `test/compliance/c4_blob.exs`.
- Ledger crash-class totality: hostile contents (tuple keys, tuple values,
  reference values) refuse typed `400 InvalidBody` inside the serialized
  writer — the writer survives (no death/restart cycle), the refusal fires
  before any counter mint, and the dup counter is not burned; attest
  crash-class: tuple key/value in `measurement_params` refuses typed
  `400 attestationFailedVerdict`. Pinned by
  `test/security/lens5_crash_class_test.exs` (5 tests, 0 failures).
- Store: `compare_and_swap_delete/3` — the conditional-delete twin of
  `compare_and_swap/4`; unknown table raises fail-closed; N racers on one
  key yield exactly one `:ok`, rest conflict (Cosmos If-Match DELETE wired
  through it: one 204, rest 412). Pinned by `test/store_churn_test.exs`.
- Runtime contracts: generated `*.ex` outputs pinned by
  `MANIFEST.sha256` (byte-identity + replay recipe on drift; transient ggen
  workspace output refused). Pinned by `test/runtime_contracts_test.exs`.
- Cosmos: query-feed `x-ms-continuation` — a 100-doc-truncated page emits
  `"1#{lsn}:{last_id}"`; resuming queries the header; forged/foreign-ledger
  tokens are typed 400 `BadRequest`. Pinned by
  `test/data_plane/cosmos_test.exs` (93 tests, 0 failures on the settled
  tree — the two lens-2 "typed GAP" pins that asserted the OLD
  no-continuation behavior have been repaired by the cosmos lane;
  docs-corpus-lens3 cycle 3 probe).
- Blob containers: Azure name grammar enforced (3-63 bytes, `[a-z0-9-]`,
  alphanumeric ends -> 400 `InvalidResourceName`), duplicate Put Container
  -> 409 `ContainerAlreadyExists` (was: silent replace + WORM clock reset),
  non-positive/non-integer `maxresults` -> 400 `InvalidQueryParameter`.
  Pinned by `test/compliance/c4_blob.exs` (28 tests, 0 failures) and
  `test/data_plane/blob_hardening_test.exs`.
- Ledger receipts: `ReceiptSigner.verify_token/1` enforces the JWS `typ`
  header — only exact-byte `"JWT"` admitted; `jwt`/`Jwt`/`application/jwt`/
  parameters/whitespace/non-binary refuse typed `{:bad_typ, ...}`
  (deliberately stricter than RFC 7515 §4.1.9; mutation-proven fence).
  Pinned by `test/security/security_hardening_test.exs` (56 tests,
  0 failures).
- Blob reads: conditional GET honors RFC 7232 precedence — If-Match
  mismatch -> 412 `PreconditionFailed`, If-None-Match match -> 304
  empty-body with the ETag echoed (the wire shape the python SDK's
  routing-map drain terminates on). Pinned by `test/compliance/c4_blob.exs`
  and `test/data_plane/blob_hardening_test.exs`.
- Blob listings: `delimiter` rolls names containing it into `<BlobPrefix>`
  elements (`<Delimiter>` echoed), composing with `prefix` and with
  `maxresults`/`marker` pagination. Pinned by `test/compliance/c4_blob.exs`
  and `test/data_plane/blob_hardening_test.exs`.
- ARM: api-version presence gates on `/subscriptions` and
  `/subscriptions/:sub_id` (missing -> 400 `MissingApiVersionParameter`
  before any 404 path; LRO polling exemption pinned). Pinned by
  `test/smalt_arm_gateway_test.exs` and `test/route_negative_test.exs`.
