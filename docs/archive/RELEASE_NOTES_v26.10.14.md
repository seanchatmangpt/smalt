# Release Notes — smalt 26.10.14

First release of smalt: a local Azure drop-in substrate on the BEAM, replacing
the official Azure emulator containers (Azurite, Cosmos DB Emulator, Service
Bus emulator, Event Hubs emulator) and adding control-plane and audit-plane
surfaces no emulator provides. All surfaces bind loopback only; state is
in-memory (ETS).

## What ships

- **ARM control plane (`:9443`, HTTPS `:9444`)** — STS token minting, endpoint
  discovery, `/tenants`, `/subscriptions`, resource groups, provider CRUD for
  38 admitted resource types (`Smalt.Registry` shapes + api-versions), child
  resources (subnets, vault keys, blobServices/default, containers,
  immutabilityPolicies, and Service Bus / Event Hubs messaging children:
  queues, topics, subscriptions, eventhubs, consumergroups), azapi actions,
  LRO (202 + `Azure-AsyncOperation` for storageAccounts and
  virtualMachines), strict `api-version` gate, GraphLaw 400
  `InvalidResourceShape` refusals (non-vacuity proven by
  `scripts/mutation_court.py`). A TLS 1.2 listener mirrors the control plane
  on `:9444` with an auto-generated self-signed dev cert (`Smalt.TLS`,
  `config :smalt, :tls, :auto`) and dispatches egress prefixes
  (`/keys`, `/dbs/`, `/app/`, `/attest/`, `/topics/`, `/atlas/`,
  `/dataCollectionRules`, `/v1/`, `/providers/`) to the data plane
  (`TlsTwinDispatch`), so Key Vault and sibling egress surfaces answer over
  TLS too.
- **ARM LRO background sweeper** — `Smalt.ArmGateway.LRO.Sweeper`: operations
  reach terminal state at rest (no poll required); opt-in retention via
  `config :smalt, :lro_retention_ms` (default `:infinity`).
- **Authentication + throttles** — `Smalt.Auth.Bearer` on both HTTP planes:
  `auth_mode :enforce` (default) verifies HS256 Bearer tokens (same STS
  secret, exp/aud checked, iss matched against the request-authority-derived
  issuer; 401 + ARM envelope + `WWW-Authenticate`
  otherwise), `:anonymous` is an explicit opt-out; Cosmos plane validates
  master-key Authorization headers (real string-to-sign HMAC) with an
  optional RU throttle; ARM plane applies a fixed-window 429 throttle with
  `Retry-After`.
- **Egress data plane (`:8443`)** — Cosmos DB point operations with ETag/
  partition-key enforcement; Key Vault SKR release gated on CVM attestation
  **plus full crypto actions** (`POST /keys/:name/{encrypt,decrypt,sign,
  verify,wrapKey,unwrapKey}` — RSA-OAEP-256/RS256/PS256, A256GCM for `oct`
  keys, release-policy operation gating); **released key material is real**:
  wrapped RSA-OAEP-256 to the token's RSA `skr_recipient_jwk` claim and
  single-use — jti replay refused with 403 `TokenReplay`; Confidential
  Ledger (Merkle receipts); MAA-style Attestation (JWT); Event Grid
  CloudEvents ingest; Blob Storage with WORM refusal (409 `ContainerLocked`)
  plus `HEAD` blob/container and marker-paginated container listing on the
  wire; Cosmos DB point operations **plus** account bootstrap (`GET /`) and
  partition-scoped query POST (`application/query+json`); Sentinel DCR
  ingest + KQL queries (`Smalt.DataPlane.KQL` engine: `where`/`order by`/
  `project`/`take` with a deterministic, injection-free AST); Resource Graph
  with an optional KQL pipeline and `$skipToken`; Purview Atlas v2. Routes
  fail closed with `503 RouteNotReady` when a sibling module is uncompiled,
  and the GraphLaw shape gate itself fails closed: an admitted resource type
  with no compiled SHACL shape refuses validation (`{:refused, :no_shape}`)
  instead of falling through to an implicit empty, permissive shape
  (`lib/smalt/graphlaw/validator.ex`; pinned by
  `test/smalt_graphlaw_validator_test.exs` "fail-closed shape resolution", 46/0).
- **AMQP 1.0 messaging (`:5672`, Event Hubs lane `:5673`)** — full frame
  codec and connection lifecycle, SASL ANONYMOUS, Service Bus queues + DLQ,
  message/session locks, `$management` RPC with exact status tables, `$cbs`
  put-token with local SAS HMAC verification, x-opt-* annotations,
  disposition->settlement mapping, and Event Hubs end to end: module
  semantics (monotonic sequences, checkpoint CAS, leases) **and wire routing**
  — the `:5673` listener's mode flag is consulted by `Smalt.Amqp.Connection`,
  `/eventhubs/`-addressed links serve real EH semantics with
  `x-opt-sequence-number` stamped from the monotonic sequences. The pinned
  AMQP dialect details (SASL descriptor, boolean-immediate constructors,
  lock-duration clamp, `.NET filetime` session-lock ticks) live in
  `docs/WIRE_PARITY.md` — authoritative; not restated here.
- **Read-only MCP tool surface (`:9545`)** — `Smalt.Mcp.Router` serves a
  generated tool descriptor (`readOnlyHint: true`) backed by real Store
  reads; actuation and unknown tools are refused by name.
- **Durable P-PLAN tasks** — `Smalt.PPlan.Task`: court-validated
  `admitted -> running -> succeeded | failed` machine, exclusive CAS claim,
  crash recovery (`recover/0`).
- **OCEL event stack** — `Smalt.Ocel.EventRegistry` / `Conformance`
  (fitness + deviations) / `DeviationAdmission` plus a rev-ops surface over
  the substrate's own event stream.
- **OCEL RevOps Ash surface** — `Smalt.Ocel.RevOps` domain: `OcelTrace` /
  `FitnessVerdict` / `OcelDeviation` read-only Ash resources over the real
  NDJSON sink and deviation ledger (receipt:
  `docs/PACK_INTEGRATION/ash-ocel-revops.md`).
- **Semantic projection** — canonical registry projection, projection
  admission matrix, semantic epoch, R2RML/ex4pm-style mappings
  (`lib/smalt/projection/`, `lib/smalt/semantic/`,
  `docs/SEMANTIC_PROJECTION.md`).
- **`smaltctl` CLI (`cli/`)** — Rust control-plane CLI generated from
  `cli/ontology.ttl` (blob, cosmos query, kv, court/doctor runners).
- **Verification ladder** — `just gate`: doctor court, offline unit (T1,
  includes the chaos tier in `test/chaos/`), wire tier (T2), SDK smoke with
  real `@azure/...` JS clients (T3: arm, amqp, blob, cosmos, the Service Bus
  census (probe set defined in `test/sdk-smoke/census.test.cjs`), and the
  Event Hubs smoke), terraform fixture plan smoke
  (T4), and the bench gate (bench thresholds are stated once, in
  `README.md` — Benchmarks). CI runs the ladder on ubuntu-latest +
  macos-14 (Elixir 1.18 / OTP 27, Node 20).

## Verification ladder summary

The authoritative ladder table lives in `README.md` (Verification
ladder): tier, command, and what each tier proves are not restated
here. Unique to this release, the latest court runs (re-run 2026-10-15,
docs-corpus-lens8 cycle 2): compliance courts c1..c7 — c1 26/0, c2 16/0,
c3 28/0, c4 46/0 (+4 blob-lane fences), c5 16/0
(`--include amqp_wire`), c6 18/0, c7 17/0
(**167 tests, 0 failures**; receipts in `docs/compliance/`); CLI court `cd cli && cargo test` 1/0;
mutation
court non-vacuous. Stress harnesses and receipts: `docs/STRESS/`. Full
gate: `just gate` (doctor + T1 + T2 + T3 + T4 + bench-check); CI
(`.github/workflows/ci.yml`, actionlint-clean) runs compile
(warnings-as-errors), T1+T2 (incl. chaos), T3 (incl. census), and T4
per OS in the matrix.

## Known deltas

See the "Known deltas (honest)" section of
`docs/MIGRATION_FROM_EMULATORS.md` — authoritative list. Highlights:
in-memory persistence (restart loses state), REST-plane credentials are
validated only under `auth_mode :enforce` (`:anonymous` is an explicit
opt-out used by the test suite), latest-only api-version enforcement, Blob
immutability defaults stricter than Azurite, Cosmos has no full SQL
translator (point ops + partition-scoped query POST only).

Resolved since the draft notes: the Event Hubs wire-tier routing gap on
`:5673` is closed (EH semantics served on the wire, SDK-smoke pinned); the
ARM control plane has a TLS listener on `:9444` that also serves the egress
planes; BlobService container surfaces are wired on the wire
(`?comp=list`/`?comp=metadata`/`?restype=container`, `HEAD`, pagination);
SB/EH ARM child resources (queues/topics/subscriptions/eventhubs/
consumergroups) are landed; Service Bus session-lock filetime ticks are
implemented; REST-plane auth enforcement (Bearer, Cosmos master-key,
throttles) is landed. Since the v2 refresh of these notes, a wire-parity
gap-fix wave landed: the Bearer issuer contract is request-authority-derived
(tokens minted on one authority do not replay on another); Cosmos `_rid`
values follow the real grammar (db 8 + container +4 + doc +8 base64url
segments) with 413 `RequestEntityTooLarge`; Key Vault accepts base64url wire
forms, requires real JWK `n`/`e` on `skr_recipient_jwk`, parses the Azure
`anyOf`/`allOf` over `claim`/`equals` release-policy grammar, and admits the nested MAA
compliance form; blob oversized puts answer 413 `RequestBodyTooLarge` and
PUT answers metadata-only JSON; Sentinel ingest answers 204 and query
envelopes carry project-ordered typed columns; Resource Graph emits
`resultTruncated` and `options.$skipToken`; Purview lineage walks stored
guids; Event Grid publish answers 200-empty; ARM responses carry
`x-ms-request-id`, `innererror`, `systemData`, and `nextLink` pagination.
In the latest wave: an ARM LRO InProgress record that cannot be evaluated
(missing/malformed scheduling fields) flips to a persisted Failed terminal
with `error.code="OperationRecordIncomplete"` instead of polling forever
(`GAP(lro-no-failed-path)` CLOSED); blob virtual directories
(slash-carrying blob names) cycle through the full PUT/GET/DELETE chain;
Event Hubs checkpoint writes are fully serialized through the broker
process and Event Grid id-dedup is opt-in via `:event_stream_dedup_ids`.

### Wire-parity honesty statement

v26.10.14 ships **parity for the documented surface; named gaps for the
rest.** At release, every `GAP(name)` token in the machine-greppable register
(`docs/WIRE_PARITY.md` + `docs/compliance/C1..C7` + `docs/TEST_ISOLATION.md`)
is one of: **CLOSED-with-receipt** (four bounded closures —
`GAP(lro-lazy-terminality)` and `GAP(lro-retention-unbounded)` via the
`Smalt.ArmGateway.LRO.Sweeper`, receipts `05-lro-lazy-terminality.md` /
`05-lro-retention-unbounded.md`; `GAP(blob-x-ms-error-code-header-absent)` and
`GAP(blob-error-envelope-json)` via the blob lane-06 error-envelope/header
work, receipts `06-blob-x-ms-error-code-header-absent.md` /
`06-blob-x-ms-date-unvalidated.md` — plus two vacuous tag deletions,
`GAP(vacuous-tag-arm-seam)` and `GAP(vacuous-tag-dp-seam)`), or
**typed-UNSUPPORTED with an inline close condition** (the surviving open
tokens: `GAP(cosmos-sql-translator-absent)`,
`GAP(ledger-lazy-create-default)` (config-flippable via
`ledger_enforce_existence`), `GAP(blob-x-ms-date-unvalidated)`,
`GAP(blob-comp-lease-absent)`, `GAP(eventgrid-eg1-schema-absent)`,
`GAP(eventhubs-partition-metadata-absent)`,
`GAP(eventhubs-consumer-group-enumeration-absent)`,
`GAP(atlas-search-relationship-get-absent)`,
`GAP(kql-datetime-dynamic-types-absent)`, plus the Service Bus
reply-to/subscription-rules UNSUPPORTED typed in V261014-08). No token was
deleted without a receipt; no open gap is claimed as closed.

## Upgrade notes

None — this is the first release. Migration from emulator containers is
covered in `docs/MIGRATION_FROM_EMULATORS.md` (port map, connection-string
forms, migration steps).
