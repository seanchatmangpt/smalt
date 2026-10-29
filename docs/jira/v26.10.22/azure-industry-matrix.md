# Azure Industry Matrix — 6-Industry examples/ Prep (v26.10.22)

Every API face below is cited from the real emulator surface
(`lib/smalt/egress_router.ex` route families + `lib/smalt/data_plane/` +
`lib/smalt/messaging/`). All paths are repo-root relative to `/Users/sac/smalt`.
Cites are file:line as of branch `main` @ 65cad07 (working tree, uncommitted
lane state). Any industry face the emulator lacks is a typed GAP and is named
`GAP(...)` per the GAP-token convention (docs/WIRE_PARITY.md) — but per lane
charter, new GAP tokens are flagged in prose, not minted unilaterally; the
GAP registrar owns token minting.

## Client-side routing shape (common to all six examples)

Browser console → `smaltFetch` → emulator planes. All examples ride the same
transport:

- `workspace/lib/smalt.ts:22` — `smaltFetch`, wrapping
  `workspace/lib/smalt.ts:11` `assertLocalUrl` (loopback-only; raw fetch is
  banned by ESLint; the only networking seam is this file).
- Endpoints: `workspace/lib/smalt.ts:5` `SMALT_ARM` (control plane 9443),
  `workspace/lib/smalt.ts:7` `SMALT_EGRESS` (data plane 8443).
- AMQP planes are not browser-reachable: Service Bus 5672 and Event Hubs 5673
  are AMQP listeners — `lib/smalt/messaging/amqp_broker.ex:35` (sb 5672) and
  `lib/smalt/messaging/event_hubs/listener.ex:3` (EH 5673). Console-facing
  legs for SB/EH go through the MCP tool surface (9545) or a relay
  (`lib/smalt/messaging/ws_amqp_relay.ex`).

## Per-industry mapping

### 1. Legal / e-discovery

- **Blob = WORM evidence** (container legal hold / immutability policy):
  `lib/smalt/data_plane/blob_storage.ex:273` (`worm_blocked?/3` overwrite
  arm), `:305` (create arm), `:516` (metadata arm);
  `lib/smalt/data_plane/blob_service.ex:105-106` (`HasImmutabilityPolicy` /
  `HasLegalHold` in container list XML), `blob_service.ex:201-222`
  (metadata-PUT WORM guard → 409 `ContainerLocked`).
  Wire routes: `lib/smalt/egress_router.ex:67-68`
  `@container_put_comps`/`@container_get_comps` include `legalhold`,
  `immutabilityPolicy`; `egress_router.ex:1313`, `:1563`,
  `:2282` (DELETE immutabilityPolicy). Blob soft delete =
  `lib/smalt/data_plane/blob_soft_delete.ex:9` (immutable version via
  `include=versions`).
- **Cosmos = case file / review-set documents**: `lib/smalt/egress/CosmosRoutes.ex:61-127`
  (dbs/colls CRUD), queries via `lib/smalt/cosmos_sql.ex`; ETag/CAS via
  `lib/smalt/data_plane/cosmos.ex:133` (quoted etag = sha256 of record).
- **Service Bus = review workflow queues** (assign/escalate): AMQP sb 5672
  (`lib/smalt/messaging/amqp_broker.ex:35`); SQL rule filters
  `lib/smalt/powl2/sb_rules.ex:1-19` (`Smalt.SbRules.parse_sql/1`,
  fail-closed SQL filter parser).
- **AppConfig = preservation-hold policy flags**:
  `lib/smalt/egress/AppConfigRoutes.ex:17` (`GET /kv`), `:50` (`PUT /kv/:key`
  with If-Match/If-None-Match ETag CAS), snapshots `:203-248`.
- **Confidential Ledger = append-only custody chain**:
  `lib/smalt/egress/AttestRoutes.ex:38-58` (`/app/transactions`,
  `/app/transactions/latest`, `/app/transactions/:tx_id`) backed by
  `lib/smalt/security/confidential_ledger.ex:1` + `ledger_writer.ex`.
- **Lithography invariant (lead)**: ethical wall / SHACL. SHACL exists in the
  substrate at `lib/smalt/arm_gateway/router.ex` and
  `lib/smalt/enclave/engine.ex` (shacl hits); the *legal* example binds
  matter-participant SHACL shapes against Cosmos case docs + Blob holds.
- **Routing shape**: browser → smaltFetch → 8443 blob/cosmos/appconfig REST +
  Confidential Ledger face; SB workflow legs via MCP 9545.

### 2. Financial services

- **Cosmos = CAS ledgers** (optimistic concurrency on balances/positions):
  `lib/smalt/egress/CosmosRoutes.ex:18` (`POST /app/transactions` batch),
  `:61-205` dbs/colls CRUD + `pkranges` `:225`; ETag CAS
  `lib/smalt/data_plane/cosmos.ex:133`; consistency controls
  `lib/smalt/data_plane/cosmos_consistency.ex`.
- **KV = keys/sign/release**: `lib/smalt/egress/KvRoutes.ex:28`
  (`POST /keys/:name/create`), `:40` (`kv_key_put`), `:122` (`rotate`),
  `:130` (rotation policy); sign: `lib/smalt/data_plane/kv_pss.ex:1-8`
  (externally verifiable RSA-PSS/PS256, KD-105/KD-119); attestation-bound
  secure key release `lib/smalt/data_plane/skr.ex:1-12`
  (`POST /keys/:name/release`).
- **Confidential Ledger = trade audit trail**:
  `lib/smalt/egress/AttestRoutes.ex:38-58` + `lib/smalt/security/confidential_ledger.ex`.
- **EH = market-data ingest**: AMQP 5673
  `lib/smalt/messaging/event_hubs/listener.ex:3`; consumer groups
  `lib/smalt/messaging/event_hubs.ex:847-917` (`cg_create`/`cg_get`/`cg_list`);
  checkpoint store `lib/smalt/messaging/eh_checkpoint_store.ex`; throttling
  `lib/smalt/messaging/eh_throttle.ex`; capture `lib/smalt/messaging/eh_capture.ex:160-166`.
- **AppConfig = risk-limit policy**: `lib/smalt/egress/AppConfigRoutes.ex:50`
  (ETag-CAS PUT), feature flags `lib/smalt/data_plane/appconfig_features.ex:49-100`
  (put/get/list/evaluate with context).
- **Lithography invariant (lead)**: CAS ledgers (Cosmos ETag CAS + Ledger
  append-only + KV release determinism, `skr.ex` "deterministic (replayable)").
- **Routing shape**: browser → smaltFetch → cosmos/kv/appconfig/ledger REST;
  EH ingest legs via MCP/relay.

### 3. Pharma 21 CFR Part 11

- **Blob = batch-record evidence** under hold:
  `lib/smalt/data_plane/blob_storage.ex:273` etc. (same WORM face as legal),
  soft-delete versioning `blob_soft_delete.ex:9`.
- **Cosmos = LIMS/batch docs** with ETag CAS for second-person verification:
  `CosmosRoutes.ex:61-205`, `cosmos.ex:133`.
- **AppConfig = part-11 policy + e-signature flags**:
  `AppConfigRoutes.ex:50`, `appconfig_features.ex:100` (`evaluate/3`).
- **KV = e-signature keys** (PS256 sign for e-signatures):
  `kv_pss.ex:1-8`; rotation `KvRoutes.ex:122`.
- **SB = QA disposition workflow**: AMQP 5672 + SQL filters
  `powl2/sb_rules.ex`.
- **Confidential Ledger = audit trail** (21 CFR 11.10(e)): the ledger face
  `AttestRoutes.ex:38-58` + `ledger_writer.ex` is the append-only trail.
- **Lithography invariant (lead)**: audit trails — every disposition step
  lands in Confidential Ledger; every doc mutation is ETag-CAS'd.
- **Routing shape**: browser → smaltFetch → blob/cosmos/appconfig/kv/ledger
  REST; SB via MCP/relay.

### 4. Aerospace/defense (air-gapped)

- **Zero-egress console**: `workspace/` is air-gapped by construction — the
  only networking seam is `workspace/lib/smalt.ts` `smaltFetch` +
  `assertLocalUrl` (loopback-only, `smalt.ts:11,22`); ESLint bans raw fetch
  literals and http clients (workspace gates, `just ws-lint`).
- **Attestation = hardware trust root**:
  `lib/smalt/egress/AttestRoutes.ex:17` (`POST /attest/:type` →
  `Smalt.Security.Attestation.attest_enclave/2`, `lib/smalt/security/attestation.ex:1`);
  enclave surface `lib/smalt/enclave/` (hcl.ex, engine.ex).
- **KV = custody signing** (PS256): `lib/smalt/data_plane/kv_pss.ex:1-8`.
  PQC inventory exists in the substrate
  (`lib/smalt/tls.ex`, `lib/smalt/affidavit/wasm_engine.ex`,
  `lib/smalt/trust_profile/trust_profile.ex`, `lib/smalt/hw/frame.ex`) but is
  NOT exposed on the KV wire face — **GAP(kv-pqc-keyface) CLOSED
  (W6, 2026-10-22, typed UNSUPPORTED-BY-CONSTRAINT)**: the MHSM release-POLICY
  half of the defense KV face LANDED (AZ-4: `lib/smalt/data_plane/mhsm.ex`,
  court 4/4, `receipts/az4-mhsm-policies.md`, KD-167). The PQC key-type half
  is typed UNSUPPORTED, not open: the only PQC primitive in the substrate is
  the vendored affidavit wasm artifact, whose JSON surface is VERIFY-ONLY —
  no `sign` op, no keygen (witnessed: `capabilities` op inventory v26.10.16;
  `{"op":"sign"}` / `{"op":"generate_keypair"}` / `{"op":"keygen"}` all answer
  typed `unknown_op`; receipt `receipts/w6-pqc-disposition.md`). A KV `sign`
  face for a `kty: MLDSA65` key requires the SERVER to sign with a held
  private key; with no sign/keygen primitive there is nothing to hold. The
  real Azure KV `kty` grammar (RSA/EC/oct ±HSM) likewise names no ML-DSA kty.
  Falsifier (reopen condition): an affidavit artifact exposing sign/keygen
  (or a provisioned ML-DSA NIF) flips this to implementable — land
  `kty: MLDSA65` on create+sign per the AZ-4 policy shape. FIPS-level
  hardware isolation on the MHSM face is typed UNSUPPORTED (no HSM silicon at
  loopback; falsifier: a real MHSM pool cannot be provisioned here).
- **EH = sensor/telemetry ingest**: 5673 + capture
  `lib/smalt/messaging/eh_capture.ex:166` (`arm/3`), geo-DR
  `lib/smalt/messaging/eh_geo_dr.ex:192` (create_or_update/failover
  `:234`).
- **Blob = certified artifact WORM**: immutabilityPolicy routes
  `egress_router.ex:1313/1563/2282`.
- **Lithography invariant (defense)**: air-gapped + PQC. Air-gap is REAL
  (zero-egress workspace). PQC on the KV wire is typed UNSUPPORTED-BY-CONSTRAINT
  (verify-only artifact primitive; W6 disposition above), not an open gap.
- **Routing shape**: browser console → smaltFetch (loopback only) → all
  planes; nothing leaves loopback.

### 5. Manufacturing (DfLSS / Andon)

- **EH = line telemetry ingest**: `event_hubs/listener.ex:3` (5673), capture
  `eh_capture.ex:166`, consumer groups `event_hubs.ex:847`.
- **Cosmos = unit genealogy docs**: `CosmosRoutes.ex:61-205`.
- **Blob = station evidence (photos/reports)**: standard blob face;
  container holds for quality holds: `blob_storage.ex:273`.
- **SB = station workflow / DLQ**: `powl2/sb_rules.ex:1-19` (in-memory rule
  manager with DLQ `:powl8_sb_rules_dlq`); AMQP 5672
  `amqp_broker.ex:35`.
- **Andon + OCEL lead**: `lib/smalt/powl2/andon.ex:1`
  (`Smalt.Powl2.Andon`), OCEL event export `lib/smalt/powl2/andon.ex:83-85`
  (`ocel:eventTypes`/`ocel:objectTypes`/`ocel:events`); event log substrate
  `lib/smalt/ocel.ex`; andon wire face `lib/smalt/powl2/andon_wire.ex`.
- **AppConfig = SPC/recipe parameters**: `AppConfigRoutes.ex:50` + flags
  `appconfig_features.ex:100`.
- **Lithography invariant (lead)**: OCEL + Andon (Powl2).
- **Routing shape**: browser console → smaltFetch → EH (via MCP/relay for
  AMQP), cosmos/blob/appconfig REST; andon state via Powl2 wire.

### 6. Semantic CAD/BIM (temporal KG)

- **Purview Atlas = KG face**: `lib/smalt/data_plane/purview_atlas.ex` —
  typedef/store/entity/relationship faces for the knowledge graph.
- **Cosmos = temporal graph docs** (valid-time bounded versions):
  `CosmosRoutes.ex:61-205` + ETag CAS `cosmos.ex:133` for bitemporal
  versioning.
- **Blob = model file WORM** (immutable model revisions):
  `blob_storage.ex:273` + immutabilityPolicy routes `egress_router.ex:1313`.
- **KV = design-authority signing** (PS256): `kv_pss.ex:1-8`.
- **EH = sensor/IoT context ingest**: `event_hubs/listener.ex:3`.
- **AppConfig = schema/policy revision pinning** (snapshots):
  `AppConfigRoutes.ex:203-248` (snapshot create/get/kv/archive).
- **Lithography invariant (lead)**: temporal KG (Purview Atlas + bitemporal
  Cosmos docs; SHACL in `lib/smalt/arm_gateway/router.ex` +
  `lib/smalt/enclave/engine.ex` for shape validation).
- **Routing shape**: browser → smaltFetch → atlas/cosmos/blob/kv/appconfig
  REST.

## Typed GAP register (flagged, not minted)

| Flag | Industry | Missing face | Evidence |
|---|---|---|---|
| `GAP(kv-pqc-keyface)` | aerospace/defense | CLOSED (W6, 2026-10-22): typed **UNSUPPORTED-BY-CONSTRAINT** — policy half CLOSED (KD-167, `receipts/az4-mhsm-policies.md`); key-type half cannot be backed on-wire: the vendored affidavit artifact's JSON surface is VERIFY-ONLY (no `sign`/keygen op; `unknown_op` witnessed on `sign`/`generate_keypair`/`keygen`, receipt `w6-pqc-disposition.md`), so a `kty: MLDSA65` server-side sign face has no primitive to route through; real Azure KV kty grammar (RSA/EC/oct ±HSM) names no ML-DSA kty either | `KvRoutes.ex:28,147-207` (RSA/EC/oct-HSM only); primitive inventory: `lib/smalt/affidavit/wasm_engine.ex` (`call_json`), `lib/smalt/trust_profile/trust_profile.ex` (RS256 substrate, engine-witness only); disposition receipt: `receipts/w6-pqc-disposition.md` |

(Single gap found on the six mapped surfaces. Everything else the operator
brief names — Blob WORM, Cosmos CAS, SB SQL filters, EH consumer groups +
capture + geo-DR, KV secrets/keys/sign/release, AppConfig kv+flags+snapshots,
Attestation `/attest/:type` — exists and is cited above.)

## Notes

- `key_vault_actions.ex` (KV data plane core) + `vault_data.ex:3-4`
  (secrets store, "the 8443 `/secrets` surface owned by `Smalt.EgressRouter`")
  + `certificates.ex:1` (certs plane incl. soft delete "deletedcertificates",
  `egress_router.ex` blob_plane_path? exclusion list ~:192) complete the KV
  family (keys/secrets/certs).
- Queue Storage and Table Storage faces also exist
  (`queue_storage_plane` `egress_router.ex:447-485`, Table
  `egress_router.ex:490` → `table_storage_router.ex`) — usable for examples
  needing simple queues/tables without AMQP.
- MCP tool surface 9545 (`lib/smalt/mcp/`) is the browser-reachable proxy for
  SB/EH AMQP legs in examples.

## Examples landed (2026-10-21, records-consolidation)

The 6 industry packs + consumers landed OUTSIDE smalt — packs in
`/Users/sac/ggen-marketplace/packs/industry-*` (ggen-marketplace), consumers in
`/Users/sac/ggen/examples/industry/*` (ggen). This section records the fold so
the milestone cites them. Marketplace commits: `a60c0b864`, `2a75d85bd`,
`2e955c7b3`, `1ecaa7301`, `0b4e701e8`, `edab453a0`(mp), `e87d029fd`,
`2e29ad2f4`, `258f1bdb0`, `14cada6c6`; ggen consumer commits: `edab453a0`,
`e87d029fd`, `2e29ad2f4`, `14cada6c6`, `cc0602c6a`.

| Industry | Pack (ggen-marketplace) | Consumer (ggen) | Qualification consequence | Mutation-court non-vacuity |
|---|---|---|---|---|
| Legal / e-discovery | `packs/industry-legal-ediscovery` | `examples/industry/legal-ediscovery` | 5 files rendered (`2026-Q-0001` evidence shapes, 20 triples) via `ggen sync run` | witness courts ALIVE (010 bates / 020 custodian / 030 wall-breach) |
| Financial | `packs/industry-financial-ledger` | `examples/industry/financial-ledger` | 5 files, consequence sha256 `a795fc8d` → `8bde79c4` (real-ggen qualified ALIVE) | exactly-once gate-fire courts green |
| Pharma 21 CFR | `packs/industry-pharma-21cfr` | `examples/industry/pharma-21cfr` | 91-triple rendered SHACL, `batch-201` chain, byte-identical double sync, BLAKE3 receipt | non-vacuity witness flips (4 gates: signature / audit-trail / CAPA / non-WORM) |
| Aero / defense | `packs/industry-aero-defense` | `examples/industry/aero-defense` | 24 files, consequence sha256 `7320fcb6` (real-ggen qualified ALIVE) | gate non-vacuity witnessed with fresh mutations (3 ASK gates: classification-complete, cross-level flow, non-loopback air-gap) |
| Manufacturing DfLSS | `packs/industry-manufacturing-dflss` | `examples/industry/manufacturing-dflss` | 5 files, consequence sha256 `a795fc8d` (real-ggen qualified ALIVE; graph_hash `d2497d51…`, replay-stable) | exactly-once gate-fire courts green |
| Semantic CAD/BIM | `packs/industry-semantic-cad-bim` | `examples/industry/semantic-cad-bim` | 25-triple rendered SHACL, hospital-tower graph (3 storeys / 5 elements / rev0→rev2) | mutation court REFUSEs injected defects |

Paths outside smalt: docs-dod-check scope is this repo; the external pack/
consumer paths above were verified on disk directly (all 12 exist). Full
fold table: `receipts/bk107b-ind-fold.md`.

## DoD

- docs-dod-check clean: every file:line cite above resolves on disk.
