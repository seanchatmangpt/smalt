# Changelog

All notable changes to smalt are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Calendar Versioning](https://calver.org/) (`YY.0M.MICRO`, e.g. `26.10.14`).

## [Unreleased]

Azure-parity + KQL window (v26.10.28 lanes; receipts
`docs/jira/v26.10.28/receipts/`).

### Added

- KQL engine (T-05, `5c30be06`/`33080213`/`688ece4c`): `summarize ... by
  bin(Col, <timespan>|<number>)`, `| join [kind=inner|innerunique|left|
  leftouter] <Table> on <Col>[ == <Col>]` (with `run/3` threading a named-table
  map: pipeline rows are `$left`, `tables[table]` is `$right`),
  `| mv-expand <Col> [, <Col>]*`, and leading cross-workspace sources
  `workspace("<id>")[.Table]` (rows stamped with a `Workspace` column).
- Blob lease surface (parity lane `8a6ce573`): full `comp=lease` on base blobs
  (acquire/renew/change/release/break) and `lease_blob_snapshot`, plus
  `<LeaseStatus>` in container/blob listings — closes
  `GAP(blob-comp-lease-absent)`.
- Wire surface (parity lanes `8a6ce573`/`474518c0`/`7a80c75a`): Append Block,
  Put Page, Set Blob HTTP Headers; DELETE blob answers `409 SnapshotsPresent`
  unless `x-ms-delete-snapshots: include|only`; Get Queue Properties /
  Set Queue Metadata (`restype=queue&comp=properties`, `x-ms-meta-*`);
  Get Account Info (`restype=service&comp=properties`).
- GraphLawEx admission gate (GL28-2, `28f9dcbe`/`a33622d1`):
  `Smalt.GraphlawEx.AdmissionGate` (fail-closed, typed refusal on nil
  engine digest), opt-in via `config :smalt, :graphlaw_ex_gate, enabled: true`
  (enabled in dev/test; default off in prod); ARM router admission seams.
  New path dependency `{:graphlaw_ex, path: "../graphlaw/graphlaw_ex"}` — a
  fresh clone now needs the sibling `graphlaw` checkout.

### Changed

- Blob-face typed errors now render the Azure XML
  `<?xml?><Error><Code/><Message/></Error>` envelope
  (`Content-Type: application/xml`) for the entire blob face, not only
  `comp=list` arms — closes `GAP(blob-error-envelope-json)`; non-blob faces
  keep byte-identical JSON (`7a80c75a`).

## [26.10.25] - 2026-10-25

Azure-fidelity control-plane window; landing commit recorded in
`docs/jira/v26.10.25/FINAL.md`. Receipts:
docs/jira/v26.10.25/RECEIPTS.md. Highlights: 14 new ARM gateway faces
(activity log, cost management, deployments lifecycle/what-if, diagnostic
settings, policy assignments, provider state, resource graph, resource
health, sku/quota, tags/locks), the Graph stub face + sign-in logs,
EventHubs/Service Bus REST data-plane faces, WS→AMQP bridge, partition-key
fences (Cosmos point-read/delete), Key Vault secrets version history
(latest-by-last-write, retained superseded versions — KD-182…186 closed),
tenant law + G5 fences, additive TLS-everywhere gate (default off),
latency/throttle realism plugs (default off), marketplace SaaS fulfillment
face, popcorn actor extraction, sovereign-image recipe, acceptance probe;
court premise repairs (trace-session arming, atom-fence warm-up,
graphlaw-run-eh repoint after the wasmi retirement, hang_reap sleep-free
verify).

## [26.10.19] - 2026-10-19

Verification-architecture reset window; landing commit `cf8b1b8`
(303-file deletion anchor `64f6099`; parity anchor `1aca688`). Receipts:
docs/jira/v26.10.19/RECEIPTS.md.

### Added

- External official-SDK verification suites: TypeScript
  (`bc733fc`, 5 workflows; 33 green / 1 divergent / 6 failing honest
  standing) and Python (`b004669`, 5 workflows, green x3), plus
  workspace official-credential swap.
- Residual internal tier: 5 census-fenced ExUnit files, cluster suite,
  adaptive-health suite (`06dc6d4`).
- RS256 identity: StsKey signing, JWKS discovery envelope (`093b571`).
- Substrate-ctl boot library + control CLI (`3471326`).
- Verification gates: non-duplication, portable-target, envelope gates;
  acceptance machine + F1 revert-the-diff falsifier court (fail-closed,
  BEFORE gate typed-SKIP until TS suite green) (`3471326`).
- ARM policy exemptions + initiatives routes (KD-112), X-ARR mTLS plug,
  crash envelope, ResourceGraph route (`c41e8ae`, `093b571`).
- Blob container lease + ACL surface (KD-108) (`c31afd4`).
- Queue storage peek/clear (WO-06) (`d941fbb`).
- Event Grid DLQ blob spillover (KD-101/G3) (`c31afd4`).
- Adaptive /healthz endpoint and HealthPlug wiring on MCP
  (`093b571`, `c31afd4`, `30970c4`).
- DNS cluster formation; env-first-int limit overrides; control-plane
  Store mount (`093b571`, `30970c4`).
- Hermetic image build (−94.3% size), density compose, k8s
  zero-sidecar blueprint, just modules 32-35 (`2c2b544`).
- SDK coverage active-window gating + 11-probe SB census probes and
  receipt bridge (`bad3b6e`).

### Changed

- Verification architecture reset: 303 legacy test files deleted
  (107,644 lines; `64f6099`); residual internal tier 5 census-fenced
  files; leaf-weighted volume 3,016 → 278 (90.8% reduction; target
  ≥80%). Receipt: `receipts/v261019-vol-census.md`.
- Court ladder restructured to 11 stages (`bad3b6e`, `3471326`).
- KD-99 and KD-100 flipped CLOSED-SIMULATED via official-SDK witness
  (`scripts/kd_flip.py --apply`; KD register v26.10.14).

### Fixed

- ARM throttle silent disarm via `:heir` owner pattern (KD-112; WO-03/
  WO-15) (`c41e8ae`).
- Policy shadow-ETS same `:heir` class (`c41e8ae`).
- Cosmos/blob child-resource location over-validation relaxed to
  DefaultShape (`1aca688`).
- blobServices/default synthesis and synchronous storage DELETE
  (AZB-25a/b azurerm parity) (`1aca688`).
- Bench `mint_token` retries connection-level transients (`5a2e1b0`).
- VM census monitor double-count (ConnSup monitor-pair ±2/socket
  churn); 10x green (`c9b0bf1`).
- sb-extra hard top-level watchdog for AMQP attach hangs on draining
  broker, witnessed x2 (`77a4041`).
- Blob container_key and lease header stragglers (`5a95c2a`).

### Status

- court-x2 NOT-RUN at wrap (`receipts/v261019-12-court-x2-close.md`,
  base pinned `64f6099`); publish-dry NOT RUN; docs-dod-check PASS;
  invariant-gates 6/6 PASS; naming-sweep 0 violations; gen-error-codes
  146 rows idempotent; sdk-matrix exit 0.

## [26.10.18] - 2026-10-19

AZB burn wave over the v26.10.16 surface. Highlights (receipts:
docs/jira/v26.10.18/RECEIPTS.md):

- Sovereign Midnight 18/18: all 18 bodies run untagged (`:sovereign_gap`
  tag retired) — 18 tests, 0 failures.
- G1 queue storage landed (azsim-burn/G1-QUEUE-STORAGE-SCOPING.md).
- AZB-17 parallel plane matrix ALIVE: 8 containers x 4 planes
  (receipts/azb-17-parallel-matrix.md).
- Isolation gates green: tree GREEN 0 offenders
  (commit 4106990; receipts/i29-env-leak-remediation.md).
- KD-98 registered (witness receipts/i29-a22f1-witness.md,
  receipts/i29-checkpoint3.md).
- Budget gate 0/0/0 (regressions/renames/unbudgeted).
- Validator standing fix landed.

Carried to v26.10.19: G2-G4, ring re-run, plane-mounting
(azsim-burn/G1-QUEUE-STORAGE-SCOPING.md).

## [26.10.16] - 2026-10-16

Repair-and-hardening wave over the v26.10.14 release surface; no new
planes. Status: BUILD_BROKEN-class — court-x2 terminal RED after 29
invocations, zero deterministic defects; typed residual
Metadata-indexer-load FLAKE_SOLO (court-environment, r224
classification). Terminal witness:
`docs/jira/v26.10.16/receipts/r229-court-x2-red.md`; standing flips
only on a green two-run receipt (see `docs/jira/v26.10.16/FINAL.md`).

### Fixed

- Event Hubs multi-event batch delivery (KD-53): inner messages 2..N of a
  `createBatch` envelope were dropped by the single-body-section unwrap;
  the decoder now discriminates complete-vs-incomplete on body-section
  presence (`lib/smalt/messaging/event_hubs.ex`). Receipts:
  `docs/jira/v26.10.16/receipts/r141-eh-batch-body-discriminator.md`,
  `r185e-eh-batch-dup-kind.md`. CLOSED-SIMULATED.
- SB management ATOM+XML (KD-45): queue-create PUT answers well-framed
  HTTP/1.x so Node's parser no longer rejects; TS Service Bus census
  replay 12/12 PASS. Receipt: `receipts/r178e-census-replay-repair.md`.
- EH selector-filter / eventPosition (KD-68): `>=` (inclusive) operator
  now parsed and applied in `connection.ex`; real-SDK witness green.
  Receipts: `r200c-kd68-selector-filter.md` (falsifier FIRED),
  `r200d-kd68-selector-impl.md`. CLOSED-SIMULATED.
- EH partition-key routing (KD-76): pk-routed sends now deliverable via
  partition-scoped subscriptions; address classifier no longer
  lowercase-substring. Receipts: `r200e-kd76-pk-routing.md`,
  `r200h-kd76-pk-witness-repair.md`. CLOSED-SIMULATED.
- Blob WORM arms (R188) and settle/lock chain (R194 renew→row mirror,
  R196 token-scoped settle CAS, R197, R201): receipts
  `r188-r196-r197-worm-settle-batch.md`,
  `r144-lock-aba-telemetry-read-guard.md`.
- Egress fences (R193 / R199 / R185 batch): percent-encoded reserved-
  namespace fence over the real wire, comp/envelope/sentinel quote-parse.
  Receipts: `r185-r185d-r185h-wire-fences-batch.md`,
  `r187b-r190-court-hardening-batch.md`.
- ETS hygiene (R178g/R189): on_exit record-and-delete guards so seeded
  `:smalt_resources` rows never leak across tests; non-vacuity court
  `scripts/shim_court/strata_cleanup_court.sh`. Receipt:
  `r178g-ets-hygiene-batch.md`.
- DetsMirror union-growth bounded and witnessed
  (`lib/smalt/store/dets_mirror.ex`; `docs/jira/v26.10.16/WRAP_LEDGER.md`).

### Changed

- KD register churn: 8 rows flipped CLOSED this window (KD-45/46/53/54/
  68/70/71/76 — table in
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` is ground truth, **28 CLOSED of
  KD-01..KD-93 on disk**); KD-49/52 were closed in a prior window (lineage,
  not this window's flips); KD-77/78/88/89/90/91/92/93 minted (OPEN —
  KD-91/92/93 from the c11 typed findings + lane X5 registrar, fixes
  landed, witness-pending).

### Added

- 25 shim courts on disk (22 receipt-witnessed; 16 new this window; 37 files
  under `scripts/shim_court/`),
  including blob WORM arms, renew-mirror, strata-cleanup, cosmos-ETag
  final-body, immutability/CAS parity courts.
- Harness hardening: shim-court witnesses run under `bash -uc`
  (`scripts/shim_court/lib.sh`), per-subject flocks for witness runs,
  multi-window test generators; `fast_test.sh` watch-mode snapshot repair.
  Receipts: `r187b-r190-court-hardening-batch.md`,
  `r207-harness-scripts-batch.md`.
- App Config /kv CRUD + CAS (`lib/smalt/data_plane/kv.ex`): full
  create/read/update/delete with ETag compare-and-swap on the egress
  plane.
- Monitor metrics + azapi emit: metrics list/get route family with
  azapi-shaped emit for the Terraform provider legs.
- Event Hubs consumer-group enumeration with `$default` synthesis:
  GET consumer-groups lists real groups and synthesizes `$default` when
  absent.
- Event Grid topics + systemTopics routes with inputSchema-gated EG1
  (Event Grid schema events only accepted when the input schema declares
  it).
- Blob snapshot / metadata / `sharesnapshot` query-parameter surface:
  point-in-time snapshots, header+query metadata writes.
- Cosmos container throughput: offer read/update routes per container.
- Service Bus / Event Hubs child-resource api-version lattice bumped to
  `2024-01-01` across queues/topics/subscriptions/consumer-groups.
- ex4pm OCEL doctor/court emitters: event-log emission from smalt doctor
  and court runs for downstream process mining.
- SPC drift emitter (`lib/smalt/spc/drift.ex`): turns `scripts/spc_gate.py`
  verdicts into CloudEvents 1.0 rows on topic `spc.drift` in
  `:smalt_event_messages` — registry-gated, fail-closed (a 3σ FAIL never
  launders into telemetry; only 1σ/2σ verdicts emit), matter-isolated
  event data. Receipt: `docs/jira/v26.10.16/sdk-results/spc-gate-receipt.md`.
- Sovereign Console clients: blob, servicebus, eventhubs, keyvault,
  cosmos, identity, appconfig, ledger (`workspace/`, egress via
  `lib/smalt.ts` only).
- Trust shim v2: leaf-exact certificate pinning (fingerprint gate against
  dead-CA keychain rot, replacing CN/CA-anchored v1 matching).
- Diátaxis docs restructure: `docs/how-to/`, `docs/explanation/`,
  `docs/archive/` splits (tutorials/reference/how-to/explanation layout).
- Affidavit WASM integration: wasmex-mounted fail-closed affidavit engine
  (`lib/smalt/affidavit/wasm_engine.ex`, sha256-sidecar authority pin,
  `{:error, :engine_unavailable}` never raise), affidavit seal module
  (`lib/smalt/affidavit/seal.ex`), and trust_profile witness contract with
  the `:PQC_NOT_PROVISIONED` typed refusal retained as fail-closed
  fallback (`lib/smalt/trust_profile/trust_profile.ex`). PQC close
  (KD-89) pending — no post-quantum claims made.
- FinOps avoided-spend calculator: pure deterministic TS original
  (`workspace/lib/finops/calculator.ts`) + 1:1 Elixir port
  (`lib/smalt/fin_ops/calculator.ex`), honest `pqc_status` field,
  Elixir-side region multipliers documented as a port extension.
- Affidavit ingestion functor seal sideband: successful resource PUT and
  RG-delete cascade admit stored-record bytes through the affidavit engine;
  a dead engine never changes the HTTP outcome; witnesses live in an ETS
  sideband (`:smalt_affidavit_witnesses`), never in wire records
  (`lib/smalt/arm_gateway/router.ex`). Receipts:
  `docs/jira/v26.10.16/receipts/cap-ingestion-functor.md`,
  `r215-affidavit-seal-court.md`.
- Policy/RBAC engine (`lib/smalt/policy.ex`): 80/20 Azure Policy + RBAC —
  policy definitions/assignments with `deny` (typed 400 PolicyViolation)
  and `audit` (non-compliance receipt) effects on the generic PUT path,
  scope-prefix enforcement, built-in role definitions served
  deterministically. Receipt: `receipts/r133-policy-row-cas.md`.
- Cosmos NoSQL SQL query engine (`lib/smalt/cosmos_sql.ex`): tokenizer +
  evaluator for query-with-parameters over stored documents
  (`run/3`, `eval_docs/2`), pinned by `test/data_plane/cosmos_sql_test.exs`.
- Key Vault secret rotate (ARM control plane): `POST .../rotate` mints a
  new data-plane version; cross-plane read-back keeps rotated versions
  GET-able from the 8443 egress plane
  (`lib/smalt/arm_gateway/router.ex:1593`, `lib/smalt/egress_router.ex:861`).
- Docker image builds with the ex4pm sibling context: `--build-context
  ex4pm=../ex4pm` injection, `/ctx/ex4pm` symlink staging
  (`docker/Dockerfile`, `docker/compose.smalt.yml`, `docker/README.md`).

### Enclave (in flight)

Approved plan: ARD-PRD-SMALT-26.10.16-V1 — zero-HCL azurerm 4.54.0 enclave
against the local substrate. Items marked LANDED have an on-disk referent
(path given); IN-FLIGHT items have none yet and are claimed only as
approved-plan scope.

- LANDED — Terraform parity fixture: `test/terraform_fixture/`
  (`versions.tf` pins `azurerm = 4.54.0` and `azapi = 2.4.0`; `main.tf`
  plans resource group + key vault + storage account; committed
  `plan.tfplan`). Zero-HCL goal end-to-end is IN-FLIGHT: plan-parse is
  green on all six provider legs, but apply still fails at the
  existence-check GET (`docs/jira/v26.10.16/sdk-results/tf-plan.md`,
  `docs/jira/v26.10.16/WRAP_LEDGER.md` item 6).
- LANDED — provider matrix + register routes: the registry admits
  **41 resource types**, including `Microsoft.KeyVault/vaults` +
  `vaults/keys` + `vaults/secrets`, Cosmos
  `databaseAccounts/sqlDatabases` / `sqlContainers`, and
  `Microsoft.Storage/storageAccounts` (`lib/smalt/registry.ex`);
  generic ARM provider routes at
  `lib/smalt/arm_gateway/router.ex` (generic ARM provider routes section).
- LANDED — KD `details[]` error envelope: ARM error bodies carry a
  non-empty `details` array (`lib/smalt/arm_gateway/router.ex:467,488`);
  pinned by the error-corpus rows in `test/arm_error_corpus_test.exs`.
- LANDED — cascade teardown on resource-group delete: children cascade by
  STORE KEY, not by the record's own `id` member
  (`lib/smalt/arm_gateway/router.ex:611-636`); the data-plane half
  (`BlobStorage.drop_account_data/1`,
  `lib/smalt/data_plane/blob_storage.ex:31`, wired at
  `lib/smalt/arm_gateway/router.ex:674,2469`) and the top-level
  storage-account DELETE route
  (`lib/smalt/arm_gateway/router.ex:2444`) are on disk.
- LANDED — secrets data plane: `?comp=secrets`-style `/secrets` routes on
  the 8443 egress plane backed by the `:smalt_vault_secrets` store
  (`lib/smalt/egress_router.ex:732-810`); pinned by
  `test/egress_secrets_test.exs` (9 tests).
- LANDED — darwin trust flow: `scripts/tf_trust_setup.sh` (status/trust/
  retrust/untrust, fingerprint gate against dead-CA keychain rot) +
  `scripts/tf_trust_check.sh`; env surface via
  `scripts/bootstrap_env.sh`.
- LANDED — pf/hosts reachability: `scripts/pf_redirect.sh`,
  `scripts/hosts_alias.sh`.
- LANDED — offline provider mirror: script
  (`scripts/tf_provider_mirror.sh`) AND material
  (`test/terraform_fixture/provider-mirror/` + `provider-mirror.rc`)
  on disk.
- LANDED — zero-drift defaults: `lib/smalt/arm_gateway/defaults.ex`
  (`Defaults.apply/2` deep-merge, wired into the storefront PUT path at
  `lib/smalt/arm_gateway/router.ex:768-814`, including `maybe_put_sku`
  storage/cosmos sku+kind aliasing); pinned by `test/defaults_test.exs`
  (9 tests) + `test/zero_drift_serialization_test.exs`. Honest caveat:
  3 zero-drift serialization cases were red at check time (mid-wave,
  2026-10-16) — the referent is landed, the fleet's own fence is
  reporting drift.
- LANDED — api-version monotonic admission (KD-78): `check_version/3`
  accepts any version <= latest for the admitted type
  (`version_lte?/2`), refusing only newer/malformed with a typed
  `InvalidApiVersionParameter` naming latest
  (`lib/smalt/arm_gateway/router.ex:1273-1300`); pinned by
  `test/apiversion_matrix_test.exs` (17 tests).
- LANDED — e1 enclave-loop bench lane: `justfile.d/21-enclave.just`
  (`just enclave-loop`) driving `scripts/tf_enclave_loop.sh`
  (lane-private substrate, loud-skip exit 3); result jsonl at
  `docs/jira/v26.10.16/bench/e1-enclave-loop.jsonl`.
- LANDED — NFR gates: `gates/nfr3_rss_gate.py` +
  `scripts/stress/beam_rss.py` (delta-RSS) +
  `test/smalt_ets_baseline_identity_test.exs` (ETS-baseline identity).
- IN-FLIGHT — T5 clean-room lifecycle: no on-disk referent yet
  (`scripts/tf_enclave_loop.sh` is T5-adjacent, not the T5 subject).

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
- ARM LRO background sweeper (`Smalt.ArmGateway.LRO.Sweeper`): at-rest
  terminality without a poll, plus opt-in retention
  (`config :smalt, :lro_retention_ms`, default `:infinity`).
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
- Docs: `docs/explanation/architecture.md` (moved from `docs/ARCHITECTURE.md`), `docs/WIRE_PARITY.md` (surface map with
  per-row falsifiers), `docs/MIGRATION_FROM_EMULATORS.md` (port map +
  honest deltas), `docs/archive/CHEAT_SCAN.md`.

### Security

- Compliance courts c1-c7 (`test/compliance/`, receipts in
  `docs/compliance/`): live-wire per-service fences over real HTTP/AMQP
  transport (no doubles). Latest runs (re-run 2026-10-15, docs-corpus-lens8
  cycle 2): c1 ARM 26/0, c2 Key Vault
  16/0, c3 Cosmos 28/0, c4 Blob
  46/0 (+4 blob-lane fences), c5 Service Bus 16/0 (`--include amqp_wire`), c6 OAuth/OIDC 18/0,
  c7 Event planes 17/0 — **167 tests, 0 failures**.
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

Tooling & workspaces (v26.10.14 fan-out, one line per landed lane family):

- Workspace: air-gapped Next.js sovereign console in `workspace/` (12 WS
  lanes; verb-gated zero-actuation, Web Serial, Bellman solver, e2e court
  via `just ws-court`). Receipt:
  `docs/jira/v26.10.14/receipts/ws-12-e2e.md` (+ `ws-01`..`ws-11`).
- smalt-cli: headless Python CLI companion with the AU-10 zero-actuation
  gate and a four-gate verification runner (`run_gates.py`,
  `smalt-cli/GATES.md`). Receipt:
  `docs/jira/v26.10.14/receipts/cli-08-gates.md`.
- Enclave testbed: composite enclave-grade stress testbed
  (`bash test/enclave-testbed/run.sh`; SKR/WORM/Ledger/Purview/Sentinel/RG/
  Cosmos/LRO/SB/EH + chaos overlay) — 9 phases, 9 PASS (2026-10-15,
  run.sh exit 0). Finding ENCLAVE-1 (put_blob CREATE under WORM) was
  dispositioned RESOLVED-INVALID: real Azure immutable storage permits
  writing NEW blobs into a locked/legal-hold container; only
  overwrite/delete of existing blobs are refused (409 `ContainerLocked`).
  Receipt: `docs/jira/v26.10.14/sdk-results/enclave-testbed.md`.
- SDK courts: real-Azure-SDK probe tiers (`test/sdk-smoke` T3 tier via
  `just test-sdk-smoke`, Service Bus census via `just census`, EH lane,
  `test/sdk-full` / `test/sdk-python` probe suites). Receipts:
  `docs/jira/v26.10.14/receipts/08-servicebus-census.md`,
  `docs/jira/v26.10.14/receipts/12-gate-closure.md`.
- Finish wave (DoD recipes now landed on the Justfile): `court-x2`
  (double-run flake court), `publish-dry` (hex publish dry-run),
  `verify-all` (offline verify ladder), `sdk-matrix` (SDK registration
  matrix, pass-or-registered), `substrate-up` / `substrate-down` /
  `substrate-status` (lock-protected substrate lifecycle), plus
  `gap-sync`, `receipt-index`, `doctor-dod`, `lane-clean`. Receipts:
  `docs/jira/v26.10.14/receipts/dod-07-court-x2.md`,
  `dod-08-publish-dry.md`, `dod-09-verify-all.md`, `dod-14-sdk-matrix.md`,
  `dod-01-substrate-lock.md`, `dod-12-docs.md` (final sync:
  `fin-17-docs-final.md`).

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
- Docs: `docs/WIRE_PARITY.md` adopts the machine-greppable `GAP(name)`
  convention — header documents the token; the Blob Storage row's three
  open Azure-parity gaps are tokenized
  (`GAP(blob-x-ms-date-unvalidated)`, `GAP(blob-comp-lease-absent)`,
  `GAP(blob-error-envelope-json)`) and its status cell corrected to
  PARTIAL per the file's own status vocabulary (implemented with a named
  gap = PARTIAL, not ALIVE).
- Key Vault SKR: the tee-admit path now enforces replay protection for
  nested MAA-form tokens — all nested-capable claim reads (compliance
  status, runtime jti, recipient JWK) route through one canonical accessor
  (`claim_value/2`, top-level precedence + case-guarded
  `x-ms-isolation-tee` fallback); a tee-form token's jti is single-use
  (replay -> 403 `TokenReplay`), and a tee-form recipient JWK is visible
  to the attested-recipient wrap. Pinned by
  `test/security/lens6_fuzz_test.exs` wave 3 (7×7 tee×claim hostile
  shapes; mutation-proven: reverting the jti read to top-level-only is
  killed by the tee-form replay fence).
- ARM LRO: an InProgress operation record that cannot be evaluated
  (missing/malformed `startedAtMs`/`delayMs`) flips to a persisted Failed
  terminal with `error.code="OperationRecordIncomplete"` instead of
  polling forever; the operations poll renders **200 for every terminal
  status** (only `InProgress` renders 202 — default-terminal, no
  vocabulary wedge). `GAP(lro-no-failed-path)` CLOSED 2026-10-15
  (arm-gateway-lens-9); fence `test/lro_test.exs` (13) pins the flip,
  stickiness, and the 200-with-error-member wire shape.
- Blob names: a slash-carrying blob name (`dir/name`) is bound by the Plug
  splat (`*blob_name`) and rejoined with `/` — Azure virtual directories
  cycle the tail's slashes through the full PUT/GET/DELETE chain. Pinned
  by `test/wire/egress_wire_test.exs`.
- Event Hubs: all checkpoint writes are serialized through the single
  `EHServer` — the checkpoint CAS no longer seeds caller-side (lens-4 F-2
  window), and `sweep/0` runs as one serialized `handle_call` instead of a
  caller-side read-modify-write over checkpoints (lens-5 F-3; the F-3 shape
  court bans the full 11-op caller-side `:ets` write surface, hardened
  after a delete-shaped mutant evaded the two-op trace 19/0). Event Grid
  id-dedup is opt-in via `:event_stream_dedup_ids` (duplicate id refused
  typed `{:error, :duplicate_id}`); the default stays last-write-wins
  (pinned divergence). Pinned by `test/amqp/event_hubs_test.exs`.
