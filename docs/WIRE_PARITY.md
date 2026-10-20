# Wire Parity

Status vocabulary: **ALIVE** = implemented in `lib/` and pinned by a real test
(unit or wire tier; the pin files named in the Evidence column predate the
v26.10.19 clean-room reset — `test/` paths other than `test/internal/` are
RETIRED@64f6099 and preserved as evidence-of-record, with live pinning on the
post-reset tree carried by `test/internal/` + `verification/{ts,py}`); **PARTIAL** = implemented but with a named gap (gap named
inline); **PLANNED** = documented intent only, no code. Rows carrying open gaps
use the `GAP(name)` token convention (machine-greppable, same convention as
`docs/compliance/C1_ARM_REST.md` §Typed-gap-register and `docs/TEST_ISOLATION.md`;
a GAP token names an OPEN gap and disappears when it closes). Every row names the test
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
grep -n "decode_typed(0x41\|decode_typed(0x42" \
  lib/smalt/messaging/amqp/primitive_codec.ex

# LRO-async types
grep -n "storageAccounts\|virtualMachines" lib/smalt/arm_gateway/router.ex | grep -i lro
sed -n '1011,1014p' lib/smalt/arm_gateway/router.ex

# ARM control plane TLS listener (:9444)
grep -n "arm_tls_opts\|arm_tls_port" lib/smalt/application.ex

# Admitted resource types (count = 38)
awk '/@admitted_resource_types \[/,/\]/' lib/smalt/registry.ex | grep -c "\""

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

## Out of parity scope: smalt-cli

smalt-cli is a thin wire wrapper: its error contract IS the wire body passed
through (`require_2xx` in cli/src/custom_handlers.rs), not a second mapping.
`docs/ERROR_CODES.md` is the authoritative code mapping; a Rust-side code table
would duplicate the wire contract in a second language. De-scoped 2026-10-17
(no CLI consumer of a local mapping exists).

## Surface map

| Service | Surface (route / protocol) | Status | Pinned by (falsifier) |
|---|---|---|---|
| ARM control plane (41 admitted resource types, mechanically counted from `@admitted_resource_types` in `lib/smalt/registry.ex`, 2026-10-16 — supersedes the historical "38" prose) | HTTP `:9443` (`Smalt.ArmGateway.Router`): STS `POST /oauth2/v2.0/token` (+ `/oauth2/v2.0/token` under any `/:tenant_id`; client_credentials — requires `client_id` **and** `client_secret`, missing secret -> 400 `invalid_client` per RFC 6749 §5.2 — the wire STS fence (`test/wire/arm_wire_test.exs:51`) now sends the secret (stale "sends secret-less requests" note DELETED 2026-10-15 lens-7: the test body carries `client_secret=wire-secret`), discovery (`/metadata/endpoints`, `/common/discovery/instance`, `/.well-known/openid-configuration`, `/[tenant]/v2.0/.well-known/openid-configuration`), `/tenants`, `/subscriptions[/:id]` (real-ARM api-version **presence gates** on both `/subscriptions` and `/subscriptions/:sub_id` — missing `api-version` -> 400 `MissingApiVersionParameter` before any 404 path, LRO polling exemption kept pinned), resource groups (case-normalized `resourcegroups`/`resourceGroups`), provider PUT/GET/LIST/DELETE, child resources (subnets, vault keys, blobServices/default, containers, immutabilityPolicies), azapi POST actions (`.../lock`, `.../setLegalHold`), LRO (202 + `Azure-AsyncOperation` for `Microsoft.Storage/storageAccounts` and `Microsoft.Compute/virtualMachines`, polled at `/subscriptions/:sub/operations/:op_id`; every terminal status renders 200 — only `InProgress` renders 202, default-terminal so no vocabulary wedge (router.ex:1162); an InProgress record that cannot be evaluated (missing/malformed scheduling fields) flips to a **persisted Failed terminal** with `error.code="OperationRecordIncomplete"` (`lro.ex:128` integer guard clause, `lro.ex:174`; fence `test/lro_test.exs` "hand-seeded InProgress record without scheduling fields flips…", mutation-killed lens-9) — CLOSED 2026-10-15, arm-gateway-lens-9); wire-level response headers/envelope: `x-ms-request-id` echoed (or minted) on every response, error envelopes carry `innererror`, resource PUT/GET bodies carry synthetic fixed `systemData`, LIST responses paginate with an absolute `nextLink` past 100 items | ALIVE | `test/wire/arm_wire_test.exs`, `test/smalt_arm_gateway_test.exs`, `test/route_negative_test.exs` |
| ARM control plane TLS | HTTPS `:9444` via `Smalt.TLS.bandit_opts/2` + `arm_tls_opts/0` in `Smalt.Application`: TLS 1.2, self-signed dev cert auto-generated into `tmp/` by default (`config :smalt, :tls, :auto`), explicit `:tls_certfile`/`:tls_keyfile` honored when both exist, `:tls, false` disables | ALIVE | `test/tls_test.exs` |
| TLS twin data-plane dispatch | HTTPS `:9444` dispatches by path prefix (`TlsTwinDispatch` in `lib/smalt/application.ex`): `/attest/`, `/app/`, `/dbs/`, `/keys`, `/topics/`, `/atlas/`, `/dataCollectionRules`, `/v1/`, `/providers/` route to `Smalt.EgressRouter` — the Key Vault key surface (`/keys...`) and the other egress planes are servable over TLS 1.2 on the twin, not only plain-HTTP `:8443` | ALIVE | `test/kv_tls_test.exs` |
| Auth enforcement | `Smalt.Auth.Bearer` plug mounted on both HTTP planes (`arm_gateway/router.ex`, `egress_router.ex`): `auth_mode :enforce` (default) requires HS256 Bearer signed with the STS secret, `exp`/`aud` checked, and `iss` matched against the request-authority-derived
issuer (`<scheme>://<host:port>/` of the incoming request — the same
derivation the STS uses; cross-seat acceptance: the STS registers its minting
authority in a VM-local `:persistent_term` trusted set
(`Smalt.Auth.Bearer.register_trusted_authority/1`), so a token minted at one
seat (e.g. ARM :9443) is accepted at a sibling seat (Cosmos :8443) whose
authority is in the set — and because the set is VM-local, a substrate
restart wipes it: pre-restart cross-seat tokens are refused, i.e.
**restart => re-authentication**; `x-forwarded-host`/`x-forwarded-proto`
honor `config :smalt, :trusted_proxies` (exact `{a,b,c,d}` tuples or IPv4
CIDR strings) and are IGNORED (fail-closed) on direct connections
(`bearer.ex:441 trusted_proxy?/1`)), 401 + ARM envelope + `WWW-Authenticate` on failure;`:anonymous` opts out; exempt prefixes `/oauth2/`, `/.well-known/`, `/common/discovery/`,`/attest/`, `/metadata/endpoints`, `/tenant(s)`. Cosmos plane additionally validates master-keyAuthorization (real string-to-sign HMAC-SHA256) when `:cosmos_master_key` is set, plus optional RUfixed-window throttle; ARM plane applies a fixed-window 429 throttle with `Retry-After`. KD-15CLOSED-with-receipt (`receipts/s3-kv-challenge.md`): mode-blind `/keys*` challenge guard in`egress_router.ex` + enriched `WWW-Authenticate: Bearer authorization=... resource=...error="invalid_token"` from `bearer.ex` — tokenless `/keys` calls now 401 with the enrichedchallenge in BOTH auth modes; mutation-court handshake witness PASS (real `@azure/keyvault-keys`KeyClient, BEFORE `HANDSHAKE_FAIL` / AFTER `HANDSHAKE_OK`); new ExUnit fences x2 in`test/egress_dispatch_test.exs` | ALIVE | `test/auth_enforce_test.exs`,`test/compliance/c6_oauth.exs`, `test/egress_dispatch_test.exs`, `receipts/s3-kv-challenge.md` |
| ARM throttle | fixed-window (1 s) ARM-wide throttle -> 429 + `Retry-After` past the configured budget (`arm_throttle/2` in `Smalt.ArmGateway.Router`) | ALIVE | `test/compliance/c1_arm.exs` |
| ARM api-version gate | `api-version` query param required on typed routes; validated against`Smalt.Registry.latest_version/1`; missing -> 400 `MissingApiVersionParameter`, mismatch -> 400`InvalidApiVersionParameter` naming the latest supported version | ALIVE |`test/smalt_arm_gateway_test.exs` |
| ARM GraphLaw refusal | unadmitted resource type or shape-constraint violation -> HTTP 400 with envelope code `InvalidResourceShape`, target `AshGraphLaw.Enforcement` (pinned decision: ARM never returns 422); non-vacuity proven by `scripts/mutation_court.py` (gate-present / gate-absent / byte-exact restore phases) | ALIVE | `test/smalt_arm_gateway_test.exs`, `scripts/mutation_court.py` |
| Key Vault crypto actions | HTTP `:8443`: `POST /keys/:name/{encrypt,decrypt,sign,verify,wrapKey,unwrapKey}` (case-insensitive suffix matching in `EgressRouter`, mounted after the literal `/keys/:name/create` route), `GET /keys`, `GET /keys/:name/versions`; RSA-OAEP-256 / RS256 / PS256 over a per-key 2048-bit RSA pair, A256GCM for `oct` keys (random 12-byte IV), ops gated on the key's release policy `allowed_operations` -> 400 `OperationNotAllowed`; module `Smalt.DataPlane.KeyVaultActions` | ALIVE | `test/data_plane/key_vault_actions_test.exs` (encrypt/decrypt round-trip, RSA non-determinism, sign/verify, policy gate) |
| Key Vault / Managed HSM SKR | HTTP `:8443`: `POST /keys/:name/create`, `GET /keys/:name`, `POST /keys/:name/release`; release gated on header `x-ms-compliance-status: azure-compliant-cvm` or a real RS256 MAA JWT Bearer; 403 `UnauthorizedAttestation`, 400 `KeyNotExportable` (no release policy), 404 `KeyNotFound`. **Real material**: released material is wrapped to the attested recipient — when the token carries an RSA `skr_recipient_jwk` claim, the material is encrypted with RSA-OAEP-256 to that key (mode `attested-recipient`); single-use nonce: a jti under `x-ms-runtime.jti` is consumed once (Store `:smalt_attestation_baseline`, `skr-jti:` keys), replay -> 403 `TokenReplay`. Compliance is accepted in both the flat form (`x-ms-compliance-status` top-level claim) and the **nested MAA form** (`x-ms-runtime` / `x-ms-compliance-status` objects); all nested-capable claim reads (compliance status, runtime jti, recipient JWK) route through one canonical accessor `claim_value/2` (`skr.ex:159-167`): top-level precedence with a case-guarded `x-ms-isolation-tee` fallback — the tee-admit path enforces the same replay protection for tee-form tokens (a nested-form token whose runtime jti lives inside the tee is single-use too; replay -> 403 `TokenReplay`; mutation-proven: reverting the jti read to top-level-only is killed by the tee-form replay fence `test/security/lens6_fuzz_test.exs` wave 3, which also pins 7×7 tee×claim hostile shapes never raising); `skr_recipient_jwk` requires real JWK `n`/`e` fields (base64url, unpadded; standard base64 accepted on input); released material and all Key Vault crypto-action wire fields (`value`/`digest`/`signature`/`iv`/`tag`) are **base64url without padding**; release policies accept the Azure grammar — `anyOf`/`allOf` structures over `claim`/`equals` matchers, stored verbatim, in addition to smalt's flat `allowed_operations` list; any other policy shape refuses `POST /keys/:name/create` with 400 `InvalidParameter` ("release_policy must be an Azure anyOf/allOf/claim/equals structure or an allowed_operations list" — wire-probe verified; keys are only stored on an admitted policy) | ALIVE | `test/wire/egress_wire_test.exs`, `test/smalt_egress_router_test.exs`, `test/compliance/c2_keyvault.exs` |
| BlobService (account plane) | Module `Smalt.DataPlane.BlobService` plus wire wiring in `Smalt.EgressRouter`: `GET /{account}?comp=list` (marker pagination + `maxresults` + prefix, EnumerationResults XML), container metadata PUT/GET (`?comp=metadata`), container properties GET (`?restype=container`), **HEAD blob/container** (header-only, content-length set); container-name grammar fence: PUT container outside the Azure grammar (3-63 bytes, `[a-z0-9-]`, starting and ending alphanumeric) answers 400 `InvalidResourceName` and duplicate Put Container answers 409 `ContainerAlreadyExists` (never a silent replace — the old path reset the WORM clock); non-positive or non-integer `maxresults` answers 400 `InvalidQueryParameterValue` (renamed from `InvalidQueryParameter` 2026-10-17 per KD-04; witness `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`), never silently coerced to the default page size | ALIVE | `test/data_plane/blob_service_test.exs`, `test/egress_wiring_test.exs` |
| Confidential Ledger | HTTP `:8443`: `POST /app/transactions`, `GET /app/transactions/:tx_id`, `GET /app/transactions/latest`; Merkle append + receipts via `Smalt.Security.ConfidentialLedger`; ledger receipt JWTs are signed and verified by `Smalt.Security.ReceiptSigner.verify_token/1`, which enforces `exp` (missing/`token_expired`) **and** an optional `nbf`: a present-but-future `nbf` refuses with the typed `:token_not_yet_valid` (`nbf == now` accepted; non-integer `nbf` uninterpretable -> same refusal);
append-side existence fence: real Azure Confidential Ledger 404s an append to
a never-created ledger — smalt's default keeps the lazy-create divergence
(documented, test-pinned), and `config :smalt, :ledger_enforce_existence: true`
flips appends to a never-created ledger to the 404-class envelope, with the
check inside the serialized writer (lens-3 TOCTOU repair: concurrent
cold-start appends resolve first-writer-creates, never fork the chain); receipt JWT `typ` header fence: only the exact-byte header `{"typ": "JWT"}` is admitted — `jwt`/`Jwt` (RFC 7515 case-insensitivity), `application/jwt` (prefix elision), parameters, whitespace, and non-binary values all refuse typed `{:bad_typ, ...}` (pinned divergence from RFC 7515 §4.1.9, mutation-proven: dropping the `check_typ` gate is killed by the typ courts); **crash-class totality** (`test/security/lens5_crash_class_test.exs`, 5 tests): hostile contents (tuple keys, tuple values, reference values) refuse typed `400 InvalidBody` inside the serialized writer — the writer survives (no death/restart cycle, `whereis` stable across refusals), the refusal fires before any counter mint (commit-point law: the ledger is untouched and a later valid append is admitted), and the dup counter is not burned; attest crash-class: tuple key or value in `measurement_params` refuses typed `400 attestationFailedVerdict` with no raise; ledger lens-6 hardening pins: `test/security/lens6_crash_class_test.exs` (2) + `test/security/lens6_fuzz_test.exs` (2) | PARTIAL (wire lane; RESOLVED-MATCHED (2026-10-16 premise audit, WRAP_LEDGER "GAP owner proposals"): real Azure Confidential Ledger has no per-subledger creation step (collection IDs are supplied at write time), so the emulator's lazy-create default matches real-service semantics; `config :smalt, :ledger_enforce_existence: true` remains a deliberate strictness opt-in documenting ARM-resource semantics) | `test/smalt_services_test.exs` (Merkle receipt test), `test/security/security_hardening_test.exs:164` (nbf grammar), `test/security/lens6_*_test.exs`, `test/wire/egress_wire_test.exs` |
| Attestation (MAA) | HTTP `:8443`: `POST /attest/:type` -> `Smalt.Security.Attestation.attest_enclave/1` (JWT) | ALIVE | `test/smalt_services_test.exs` (JWT attestation test) |
| Event Grid ingest | HTTP `:8443`: `POST/GET /topics/:topic/events`; CloudEvents 1.0 validation(`specversion` = `"1.0"`, non-empty `source`/`type`; UUID stamped when `id` absent); publish answers**200 with an empty body** by default (real Event Grid form; legacy list form still available);insertion-order listing via stored `seq`. Typed-UNSUPPORTED (C7, V261014-13):`GAP(eventgrid-eg1-schema-absent)` — **narrowed 2026-10-16 (EventGrid-topics lane)**: native Event Grid schema (EG1) ingest is now admitted **for ARM topics explicitly declared `inputSchema: "EventGrid"`** (`Microsoft.EventGrid/topics` PUT, dedicated `:smalt_eg_topics` table; `eg1_publish/2`; wire tests `test/eventgrid_topics_arm_test.exs`); un-declared / `CloudEvents`-schema topics still refuse the EG1 envelope with 400 `InvalidCloudEvent` — the GAP token stays OPEN for undeclared topics and system-topics-as-source events (system-topic ARM CRUD landed, system-topic-sourced event ingest not). Evidence receipt: `docs/jira/v26.10.16/receipts/cap-eventgrid-topics.md` (PARTIAL_ALIVE: declared-topic EG1 close witnessed; undeclared topics + system-topic-sourced ingest remain open) | ALIVE (partially narrowed) | `test/smalt_services_test.exs`(CloudEvents test), `test/wire/egress_wire_test.exs`, `test/eventgrid_topics_arm_test.exs` |
| Blob Storage | HTTP `:8443`: guarded catch-all `PUT/GET/DELETE /{account}/{container}[/{blob}]` where a slash-carrying blob name (`dir/name`) is bound by the Plug splat (`*blob_name`) and rejoined with `/` (`egress_router.ex` blob routes — Azure virtual directories: the blob lane cycles the tail's slashes through the full PUT/GET/DELETE chain); ETag, If-Match 412, WORM refusal (legal hold or locked immutability policy -> 409 `ContainerLocked`), XML blob listing with **delimiter roll-up** (`list_blobs_xml` delimiter path, `blob_storage.ex:558-718`): names containing the delimiter roll into `<BlobPrefix>` elements with `<Delimiter>` echoed in the EnumerationResults, composes with `prefix` (nested roll-up under the prefix) and with `maxresults`/`marker` pagination across pages, wire-exercisable (`comp=list&delimiter=/` -> `<BlobPrefix>` + `<Delimiter>/</Delimiter>`, pinned `c4_blob.exs:527,681`); delete 202 with `x-ms-request-id`; oversized puts answer 413 `RequestBodyTooLarge` (JSON error envelope; two bounds: 1 MiB per-PUT fence in `BlobStorage` @max_put_bytes, 8,000,000-byte egress request-body cap), conditional reads (`get_blob_conditional/4` in `blob_storage.ex:479`): RFC 7232 precedence — If-Match mismatch -> 412 `PreconditionFailed`, then If-None-Match match (incl. `*` on an existing blob) -> **304 empty-body with the ETag echoed** (the python-SDK routing-map drain terminates only on a literal 304; `egress_router.ex:258-262` and `:1062-1088` wire the shape), 200 otherwise; blob PUT answers a metadata-only JSON body (name/etag/size/content-type projection — raw bytes never reach the JSON encoder); immutability policy `immutabilityPeriodSinceCreationInDays` clamped to integer 0..146000 days, else 400 `InvalidXmlDocument` (`blob_storage.ex @max_retention_days`); policy set/lock API in `Smalt.DataPlane.BlobStorage`; container PUT answers **201 with a quoted `ETag`, RFC 1123 `Last-Modified`, `x-ms-request-id` + `x-ms-version`, and an empty body** (real-Azure shape, lens-5 cycle-33; `egress_router.ex` container PUT path), and `x-ms-meta-*` headers on Put Container SET metadata at create — validated BEFORE the create so a refused create leaves no container behind; XML listing honors `include=metadata` (comma-separated token list, exact-token match — a hostile token like `metadatabase` does not enable it): user metadata rides `x-ms-meta-*` on the stored headers and the listing emits a `<Metadata>` element per blob (`blob_storage.ex:688-718`); unknown include tokens (`snapshots`/`versions`/`tags`) are typed UNSUPPORTED and never emit decoration; Azure-parity gaps per the C4 receipt (`docs/compliance/C4_BLOB.md`): `GAP(blob-x-ms-date-unvalidated)` — `x-ms-date` not required/validated (bounded future fix: presence + RFC 1123 parse + skew window shared with the other `:8443` planes); `GAP(blob-comp-lease-absent)` — full `comp=lease` surface (acquire/renew/change/release/break, `:smalt_blob_leases`, enforcement seam alongside `check_worm`) is feature-scale; until it lands `<LeaseStatus>unlocked</LeaseStatus>` in container/blob listings is the divergence marker; **delete precedence divergence**: `delete_blob/4` evaluates `check_worm` BEFORE `check_if_match`, so a blob both WORM-locked and If-Match-mismatched answers **409 `ContainerLocked`** where real Azure evaluates preconditions first and answers **412 `PreconditionFailed`** (reorder is contract-visible — tests + `@doc` pin 409-on-WORM — and interacts with the future lease seam; revisit with the lease work); **CLOSED (v26.10.14 lane 06; receipt `docs/jira/v26.10.14/receipts/06-blob-x-ms-error-code-header-absent.md`)**: (CLOSED — token retired) — blob `comp=list` routes (container list and blob list) now answer typed errors with the Azure XML `<?xml?><Error><Code/><Message/></Error>` envelope (`Content-Type: application/xml`, `blob_error_xml/4`, scoped to comp=list arms only — every other `blob_error/3` consumer keeps byte-identical JSON); (CLOSED 2026-10-15, receipt `06-blob-x-ms-error-code-header-absent.md` — token retired) — blob error responses now carry the error code in the `x-ms-error-code` header (both renderers; envelope bodies unchanged); also CLOSED: container-list `maxresults` grammar split — junk/zero/negative maxresults on `GET /{account}?comp=list` now answer typed 400 `InvalidQueryParameterValue` (KD-04 rename landed 2026-10-17; witness `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`) via `BlobStorage.check_maxresults/1` (previously silently coerced to the default page), and container/blob listing escape output delegates to the single `BlobStorage.xml_escape/1` including the supplementary-plane (astral) numeric-character-reference transform | PARTIAL (wire lane; 2 UNSUPPORTED gaps above + delete-precedence divergence) | `test/data_plane/blob_hardening_test.exs`, `test/wire/egress_wire_test.exs`, `test/sdk-smoke/blob.test.cjs` |
| Sentinel / Log Analytics | HTTP `:8443`: `POST /dataCollectionRules/:dcr/streams/:stream?api-version=2023-01-01`, `POST /v1/workspaces/:id/query`; queries containing `| where` / `| order by` / `| project` route into the `Smalt.DataPlane.KQL` engine (deterministic AST: `where` with `==`/`!=`/`contains`/`startswith`/`>`/`<`/`>=`/`<=` + `and`/`or`, `take` max 1000, `order by ... asc/desc`, `project`); ingest answers **204 No Content** (real Log Analytics form, empty body) with an
NOTE (blob dot-form DNS): azurerm/go-azure-sdk build blob endpoints as
`<account>.blob.<dnsSuffixes.storage>` from `/metadata/endpoints`
(`router.ex:1210`, currently `smalt.local`); `/etc/hosts` cannot
wildcard, so that dot-form is unreachable — smalt serves the
account-in-path form `http://127.0.0.1:8443/{account}/{container}/{blob}`
(see `MIGRATION_FROM_EMULATORS.md`); control-plane-only terraform
fixtures are unaffected (account keys/props come from ARM, not the
data plane).
| Sentinel / Log Analytics | (same form as the ARM plane; `egress_router.ex generate_request_id/0`);
a **null or scalar record anywhere in the batch is a request-level 400
`InvalidData` with no partial insert** (`sentinel.ex:62` — every record must be
a JSON object); query envelopes preserve `project` column **order** and carry per-column **`type`** (typed columns, stringified values); non-pipeline queries take the legacy path (`take` max 101, five enrichment columns incl. `sha256Hash`). Typed-UNSUPPORTED (C7, V261014-13): `GAP(kql-datetime-dynamic-types-absent)` — datetime/dynamic column-type inference absent (values report `"string"`) | ALIVE | `test/data_plane/kql_test.exs`, `test/data_plane/audit_planes_test.exs` |
| Resource Graph | HTTP `:8443`: `POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`; optional KQL `where`/`order by`/`project` pipeline (leading `|` optional, per Resource Graph convention) applied over the subscription-filtered rows; response carries `resultTruncated: true` only when the filtered set exceeds the server record cap, `$skipToken` (under `options.$skipToken` and top-level) backed by `:smalt_resource_graph_tokens`; `options.$top`/`options.$skip` honored | ALIVE | `test/data_plane/audit_planes_test.exs`, `test/data_plane/kql_test.exs` |
| Purview (Atlas v2) | HTTP `:8443`: `POST /atlas/v2/entity`, `POST /atlas/v2/entity/bulk`, `GET /atlas/v2/entity/guid/:guid`, `GET /atlas/v2/lineage/:direction/:guid?depth=N` — lineage walks **stored** guid edges in Store `:smalt_purview_edges` (BFS to `depth`, entities resolved from `:smalt_purview_entities`; unknown guids degrade to `typeName: "Unknown"`, never fabricated guids) (module `Smalt.DataPlane.Purview`, file `lib/smalt/data_plane/purview_atlas.ex`). Typed-UNSUPPORTED (C7, V261014-13): `GAP(atlas-search-relationship-get-absent)` — `POST /atlas/v2/search/collection` and relationship read/GET beyond the edge-minting POST not implemented | ALIVE | `test/data_plane/audit_planes_test.exs` |
| Cosmos bootstrap + query | HTTP `:8443`: `GET /` account bootstrap (the `@azure/cosmos` SDK's first wire call) and `POST /dbs/:db/colls/:coll/docs` with `content-type: application/query+json` — partition-scoped query feed `{"_rid","Documents","_count"}`, honest 100-doc scan limit, never creates documents. `_rid` values follow the real Cosmos grammar — base64url-of-sha256 segments, db rid 8 chars, container rid = db rid + 4, doc rid = container rid + 8; bodies over the 8 MB-class limit answer 413 `RequestEntityTooLarge`; query-feed continuation: a page truncated at the 100-doc scan limit carries `x-ms-continuation` in the `"1#{lsn}:{last_id}"` form and a subsequent query with that header resumes after the page's last id; a forged or foreign-ledger token (lsn ahead of the container ledger, malformed grammar, unknown last id) is a typed 400 `BadRequest`, never a silent ignore-and-scan-from-start | ALIVE (wire lane; SQL query surface served by the 80/20 AST translator `Smalt.CosmosSql` (`lib/smalt/cosmos_sql.ex`, wired `cosmos.ex:1356,1438` — parse on the query POST path, `eval_docs` before feed render); unsupported grammar classes (join/udf/aggregate/offset/unbound param) still answer a typed 400 `SyntaxError` like real Cosmos, so the emulator never returns an honest-looking 200 for a query it did not evaluate; see Coverage boundaries) | `test/compliance/c3_cosmos.exs`, `test/data_plane/cosmos_test.exs` |
| MCP read-only tool surface | HTTP `:9545` (`Smalt.Mcp.Router`): generated tool descriptor with `readOnlyHint: true`, backed by real Store reads; actuation-named tools refused by name, unknown tools refused; write attempts answered with a typed refusal, not silent success; oversize JSON-RPC body (beyond the 8 MiB Plug read_body cap) -> HTTP 413 + JSON-RPC error -32602 `PAYLOAD_TOO_LARGE`; malformed/missing tool params -> JSON-RPC -32602 `INVALID_PARAMS` typed refusal | ALIVE | `test/mcp_test.exs` |
| pplan durable tasks | `Smalt.PPlan.Task` over Store `:smalt_pplan_tasks`: court-validated `admitted -> running -> succeeded | failed` (terminal states absorb; refused edge raises typed refusal), exclusive claim via `Store.compare_and_swap/4`, `recover/0` re-admits tasks whose claimant died (kill-mid-transition chaos row) | ALIVE (module tier) | `test/pplan_test.exs` |
| Store conditional transitions | `Store.compare_and_swap/4` (replace path) and `Store.compare_and_swap_delete/3` (delete path, `store.ex:199`): both fail closed on an unknown table (raise, never silently no-op), and both are single-ETS-window atomic — N concurrent conditional deletes on one doc yield exactly one `:ok`/204, the rest `{:error, :conflict}`/412 (Cosmos `DELETE` with If-Match is wired through `cosmos.ex:468`; no read-check-delete window exists) | ALIVE (module + cosmos wire tier) | `test/store_churn_test.exs:98` (N-racer), `test/store_churn_test.exs:117` (fail-closed), `test/data_plane/cosmos_test.exs` |
| Generated runtime contracts replay fence | `lib/smalt/runtime_contracts/generated/*.ex` are pinned by `MANIFEST.sha256`: the test asserts every pinned file is present and byte-identical (sha256) to the replay-verified manifest, refuses generated drift with the replay recipe (`cd lib/smalt/runtime_contracts/ggen && ggen sync run`), and fails when the transient ggen workspace (`generated/` under `runtime_contracts/ggen/`) is left in the tree (duplicate-module compile abort trap) | ALIVE | `test/runtime_contracts_test.exs:125-153` |
| OCEL event stack | `Smalt.Ocel.EventRegistry` + `Smalt.Ocel.Conformance` (fitness vs epsilon, deviations) + `Smalt.Ocel.DeviationAdmission` over the substrate event stream; rev-ops surface in `lib/smalt/ocel/revops/` | ALIVE (module tier) | `test/ocel_test.exs`, `test/ocel_conformance_test.exs`, `test/ocel_revops_test.exs` |
| SB/EH ARM children | queues/topics/subscriptions under `Microsoft.ServiceBus/namespaces`, eventhubs/consumergroups under `Microsoft.EventHub/namespaces`: PUT/GET/LIST/DELETE via `handle_parented_child` in `Smalt.ArmGateway.Router`; types admitted in `Smalt.Registry` (38 types) | ALIVE | `test/wire/arm_wire_test.exs`, `test/sb_children_test.exs` |
| AMQP 1.0 framing | TCP `:5672` (`Smalt.Amqp.Connection` + `Smalt.Amqp.FrameCodec` + `Smalt.Amqp.PrimitiveCodec`): protocol-header exchange, SASL `ANONYMOUS`, open (container `smalt-local`, max-frame 1 MiB) / begin / attach / flow / transfer / disposition / detach / end / close; malformed frames -> close with error condition. `sasl-outcome` descriptor is **0x44** (wire-lane fix from the real-SDK census; the earlier non-conforming descriptor broke real clients). Boolean-immediate constructors decoded: `0x41` -> `true`, `0x42` -> `false` (rhea/real SDKs emit these on attach `role`). Described-type descriptor constructors are **spec-pinned to §1.6 on both paths** (`primitive_codec.ex`): decode accepts ulong or symbol ctors only (`check_descriptor` guard; malformed described payloads tag `:invalid_constructor`), and encode accepts an integer in the unsigned-64 domain or `{:symbol, bin}` only — a plain-binary descriptor (silently rewritten to a symbol before the lens-6 fix) or an out-of-domain/ill-shaped descriptor raises the documented `ArgumentError`, never a `FunctionClauseError` leak or a silent shape rewrite. Integer-encode guards: ulong/int64 clauses bound their domains (`n <= 0xFFFF_FFFF_FFFF_FFFF`, signed-64 range) with a catch-all `ArgumentError` clause, so out-of-domain integers are refused instead of silently truncated to 8 bytes (lens-6 encode-path differential: 2**128 decoded back as 0 before the guard). | ALIVE | `test/amqp/frame_codec_test.exs`, `test/amqp/primitive_codec_test.exs`, `test/amqp/connection_test.exs`, `test/wire/amqp_wire_test.exs`, `test/sdk-smoke/amqp.test.cjs` |
| AMQP queue links | attach routing: `$cbs` -> CBS router, address containing `management` -> `$management`, else queue link; sender-side ingest settled `accepted` after store write; receiver delivery on flow credit with `delivery-tag` = lock token; attach without live CBS claim -> detach `amqp:unauthorized-access` / `UNAUTHORIZED_ENTITY` | ALIVE | `test/amqp/connection_test.exs` |
| Service Bus locks | message/session locks in `:smalt_sb_locks` / `:smalt_sb_sessions`; duration clamp 100-30000 ms (default 30000); unknown token -> `{:error, :not_found}` (management 404), expired -> `{:error, :lock_lost}` (410) | ALIVE | `test/amqp/lock_manager_test.exs` |
| Service Bus queues + DLQ | `:smalt_sb_queues` / `:smalt_sb_messages`; capacity 4096, max body 1 MiB, peek max 100; DLQ footer application properties `DeadLetterReason` / `DeadLetterErrorDescription` | ALIVE | `test/amqp/queue_store_test.exs`, `test/amqp/delivery_encoder_test.exs` |
| `$management` RPC | application-property `operation`: `com.microsoft:renew-lock`, `com.microsoft:renew-session-lock`, `com.microsoft:peek-message`, `com.microsoft:update-disposition`, `com.microsoft:receive-by-sequence-number` (symbolic or bare); unknown -> 501 `UNSUPPORTED_OPERATION`; malformed -> 400 `MALFORMED_REQUEST`. Exact status tables below. | ALIVE | `test/amqp/management_rpc_test.exs`, `test/amqp/connection_test.exs` |
| Service Bus UNSUPPORTED (typed, V261014-08) | session reply-to (`reply_to` / `reply_to_session_id`): no code path stores or emits either field — SDKs setting `reply_to_session_id` on a requires-session queue observe the field **dropped, not rejected**; scoped-and-parked fix (store on ingest, emit in build_properties, census probe) for the next window. Subscription rules (add-rule / remove-rule / SQL filter / correlation filter / default rule `$Default`): no subscription concept in route/2, no add-rule/remove-rule ops in normalize_op/1, no filter evaluator — add-rule stays `:unknown-op` (fail-closed 501). | UNSUPPORTED (typed) | `docs/compliance/C5_SERVICEBUS.md` R11, `docs/compliance/C7_EVENT_PLANES.md` |
| `$cbs` put-token | see dialect table below; claim cache cap 128; queue-attach authorization enforced while the CBS process runs, open otherwise | ALIVE | `test/amqp/cbs_router_test.exs`, `test/amqp/sas_verifier_test.exs`, `test/amqp/connection_test.exs` |
| Service Bus over real AMQP wire | send + receive + complete round-trip over `:5672`; additionally an 11-probe real-SDK census (`@azure/service-bus`, fail-closed, zero skips; 8 grew to 11 in V261014-08: `deferred-receive`, `dlq-properties`, `lock-duration` added, stale-handle rewritten onto an explicit PT15S queue) — census additions are written-but-unexecuted this window (no `SMALT_SDK_ROOT` in the lane environment); broker-side code is pinned by `test/amqp/` | ALIVE (wire lane) / census probes written-but-unexecuted | `test/wire/amqp_wire_test.exs`, `test/sdk-smoke/amqp.test.cjs`, `test/sdk-smoke/census.test.cjs` (via `census-run.mjs`) |
| Event Hubs (module semantics) | `Smalt.Messaging.EventHubs` on ETS `:smalt_eh_partitions` / `:smalt_eh_checkpoints`: strictly monotonic per-partition sequence from 1, checkpoint compare-and-swap (`:ok` / `{:error, :conflict}`), processing leases (`reserve_processing/4` + `sweep/0`), `reconcile/2`; ALL checkpoint writes are serialized through the single `EHServer` (no caller-side checkpoint seed on the CAS path, `event_hubs.ex:123`; `sweep/0` runs as one serialized `handle_call` — no caller-side read-modify-write over checkpoints, `event_hubs.ex:192`; the F-3 shape court in `test/amqp/event_hubs_test.exs` bans the FULL caller-side `:ets` write surface — 11 ops incl. `delete_object/2`/`match_delete/2`/`select_delete/2`/`delete/1`, lens-8 hardened after a delete-shaped mutant evaded the two-op trace 19/0). Event Grid id-dedup: by default a republish of a stored `topic/id` is last-write-wins (pinned divergence); with `:event_stream_dedup_ids` set, a duplicate id is refused typed `{:error, :duplicate_id}` (`event_stream.ex:42`). Typed-UNSUPPORTED (C7, V261014-13): CLOSED 2026-10-15, token retired: the `getEventHubProperties`/partition-count surface is served (hub/partition READ payloads + 404 typed refusals; receipt `docs/jira/v26.10.14/receipts/s2-eh-shims.md`, KD-19 closed); (CLOSED 2026-10-16, token retired: hub-scoped consumer-group LIST serves a synthesized `$default` (same `build_resource_record` envelope as a PUT-created group, exactly-once when a client PUTs `$default`; receipt `docs/jira/v26.10.16/receipts/cap-eh-consumergroups.md`) | ALIVE (module tier) | `test/amqp/event_hubs_test.exs` |
| Event Hubs AMQP wire lane | TCP `:5673` listener (`Smalt.Messaging.EventHubs.Listener` -> `Smalt.Amqp.Listener` mode `:eh`) under `Smalt.AmqpBroker`. `Smalt.Amqp.Connection.route/2` now consults the mode flag: `mode == :eh` or an address containing `/eventhubs/` routes the link to `:eventhubs`, and `deliver_eventhubs/2` serves deliveries stamped with `x-opt-sequence-number` from the EH monotonic sequences. Wire-tier claim witnessed at the byte level by the `@azure/event-hubs` SDK probe receipt (`sdk-results/ts-event-hubs.md`: real transfer frames with `x-opt-sequence-number` annotations over the 5673 lane); the SDK smoke is now a green pin post-KD-18/19/20 close (`receipts/s2-eh-shims.md`: getEventHubProperties/getPartitionProperties 200 over the real wire, unknown partition 404 PARTITION_NOT_FOUND, ordered wire delivery with integer sequence numbers; `eh-run.mjs` 4/4 incl. batch-send exact-string deepEqual). One probe premise-drift remains: `wire-delivery-raw-payload-decode` asserts the format!=0 rhea raw-passthrough, which format 0 removes — probe rewrite queued, not a substrate gap. | ALIVE (wire tier, real-SDK witnessed) | `test/amqp/event_hubs_test.exs` (module), `test/sdk-smoke/eventhubs.test.cjs` via `eh-run.mjs` (wire); `test/wire/amqp_wire_test.exs` pins the `:sb` lane |
| Event Hubs SDK smoke | `test/sdk-smoke/eventhubs.test.cjs` + `eh-run.mjs`: real `@azure/event-hubs` 6.0.4 over the 5673 lane, fail-closed, zero skips (exits 3 when `SMALT_SDK_ROOT` is missing rather than silently passing). Wire tier unaffected (see row above); the SDK smoke now **passes 4/4** post-KD-18/19/20 close (`receipts/s2-eh-shims.md`; CLOSED — token retired, surface served: hub/partition READ payloads + 404 typed refusals) | ALIVE (wire lane; SDK smoke green) — machine matrix: SDK_MATRIX eventhubs TS cell still reads REGISTERED-DIVERGENCE (pass=5 fail=4) because `sdk-results/ts-event-hubs.md` is the 2026-10-15 16:53 pre-shim receipt; the post-shim 4/4 green run is witnessed only in `receipts/s2-eh-shims.md` — refresh `sdk-results/ts-event-hubs.md` from a re-probe to flip the cell | `test/sdk-smoke/eventhubs.test.cjs`, `docs/jira/v26.10.14/sdk-results/ts-event-hubs.md` |

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
| `com.microsoft:receive-by-sequence-number` | 200 `{"messages": [...]}` (peek-message envelope; messages re-locked, settle via complete/abandon/renew) | 400 `SEQUENCE_NUMBERS_REQUIRED` (blank/malformed long array) · 410 `MESSAGE_NOT_DEFERRED` (batch-atomic: one non-deferred sequence fails the whole batch, no partial lock) · 404 `NOT_FOUND` (store error) |
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
  (`application/query+json`, honest 100-doc scan limit). The former
  whitelist honesty gate (admit-only `SELECT * FROM <alias>`, all else a
  typed 400 `SyntaxError`) is superseded by the 80/20 AST translator
  `Smalt.CosmosSql` (`lib/smalt/cosmos_sql.ex`, wired `cosmos.ex:1356,1438`);
  unsupported grammar classes (join/udf/aggregate/offset/unbound param) still
  answer typed 400 `SyntaxError` (court `test/data_plane/cosmos_sql_test.exs:88`).
  CLOSED 2026-10-17 — receipt
  `docs/jira/v26.10.16/receipts/r-lane523-cosmos-sql-flip.md`. The list feed
  (`GET /dbs/:db/colls/:coll/docs`) is wrapped in the same auth/RU `gate/5`
  as every sibling doc route (401-without-auth fenced on the wire).
- SDK smoke coverage: arm, amqp, blob, cosmos, **service-bus census**,
  **event-hubs**. No SDK harness for Sentinel, Purview, Ledger, Attestation,
  Key Vault, or Resource Graph.
- The egress router fails closed with
  `503 {"error":{"code":"RouteNotReady"}}` when a sibling data-plane module is
  not compiled, rather than answering 200-empty.

## SDK-wave divergence register cross-reference (2026-10-15)

The v26.10.14 SDK validation waves filed named, wire-evidenced divergences in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (see that table for per-row status —
it is the ground truth). Those are
net-new registers and do not contradict the GAP tokens above: KD-19 folds
under the `eventhubs-partition-metadata-absent` closure (owning row :148,
receipt `receipts/s2-eh-shims.md`), and KD-04's
`InvalidQueryParameter` -> `InvalidQueryParameterValue` token rename landed in `lib/` on 2026-10-17
(`egress_router.ex`, `blob_storage.ex`, `blob_service.ex` + test pins; `docs/ERROR_CODES.md` regenerated, 107 rows;
witness `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`; the row stays OPEN in
`docs/jira/v26.10.16/KNOWN_DIVERGENCES.md` pending the next `kd_flip.py` pass — it is a code rename, no shim, so no `# KD-COVERS`). Doc-truth
flag: the Event Hubs AMQP wire lane row (:149) cites the SDK smoke as its pin,
but per `sdk-results/ts-event-hubs.md` that smoke currently exits 1 (mgmt 501
gap class) — the row's wire-tier claim stands, the smoke-tier citation is
stale until KD-18/19/20 close — CLOSED 2026-10-16 (`receipts/s2-eh-shims.md`): the smoke citation is
now current (4/4 green).

## See Also

- `docs/reference/kd-register.md` (KD register pointer; canonical table
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`)
- `docs/ERROR_CODES.md` (generated wire error-code table)
- `docs/jira/v26.10.16/sdk-results/tf-plan.md` (tf-plan sdk-results receipt)
