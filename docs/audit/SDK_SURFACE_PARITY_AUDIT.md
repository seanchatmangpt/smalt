# SDK Surface Parity Audit

Consolidation of lanes AUD-1..AUD-4 (`docs/audit/sections/aud{1..4}-*.md`),
wire-parity audit v26.10.14. Each section file is the source of record for
its rows; this document merges, dedupes, and assigns sequential gap ids.
All four lanes are adversarial code-level audits citing SDK source + smalt
source file:line.

## 1. Executive Parity Matrix

Parity % = full-support signatures / total signatures per service,
recomputed from the section tables (per-row states re-tallied from
`docs/audit/sections/`, not copied from lane count sections).

| Service | SDK Packages | Implemented (FULL) | Missing / Fall-through | Parity % | Open Gaps |
|---|---|---|---|---|---|
| Blob Storage (wire comp/restype + headers) | @azure/storage-blob (TS), azure-storage-blob (PY 12.31.0) | 13 of 41 audited signatures FULL (9/30 comp/restype rows + 4/11 header rows) | 28: 3 PARTIAL-STUB rows (list XML KD-02, list containers, delete KD-05) + 18 MISSING comp/restype rows (10 mis-routed into the generic Put/Get Blob arms — the KD-52 mis-dispatch class — 8 hard-404) + 4 MISSING header rows + 3 PARTIAL header rows | **32%** (13/41) | GAP-01..03, 06, 09, 10 (new); GAP-07/08 = KD-02/KD-05 cross-marks |
| Cosmos DB | @azure/cosmos (TS), azure-cosmos (PY) | 12 of 22 rows FULL (CRUD, feeds, continuation, session tokens, pk header, auth sig, RU/429) | 5 MISSING (change feed, sprocs/triggers/udfs, PATCH, trigger headers, query-metrics) + 5 PARTIAL (upsert KD-36, query whitelist KD-06, max-item-count KD-08, bulk KD-44, pkrangeid) | **55%** (12/22) | GAP-04..06 (new); GAP-36 cites KD-36/06/08/44/09 |
| Event Hubs / Service Bus — AMQP link layer | @azure/event-hubs, @azure/service-bus, azure-eventhub, azure-servicebus (pyamqp) | 17 of 22 rows FULL (open/attach echo, dispositions, session filter, delivery-id, SASL, CBS-gated auth) | 4 MISSING (selector-filter, epoch, EH delivery_annotations, x-opt-offset/enqueued/pk) + 1 PARTIAL (KD-53 batch inner-message drop — CLOSED-SIMULATED, see
  `docs/jira/v26.10.16/receipts/r185e-eh-batch-dup-kind.md` via
  `2026-10-15-kd53-eh-batch-witness.md`) | **77%** (17/22) | GAP-11..14
  (new); KD-53 CLOSED-SIMULATED (receipt `r185e-eh-batch-dup-kind.md` via
  `2026-10-15-kd53-eh-batch-witness.md`) |
| Service Bus $management | @azure/service-bus, azure-servicebus | 5 of 12 ops FULL (renew-lock, renew-session-lock, peek, update-disposition, EH READ) | 4 MISSING (session-state x2, batch-delete, rules) + 2 PARTIAL (receive-by-seq KD-46, partition READ hardcoded ["0","1"]) + 1 UNSUPPORTED-REGISTERED (schedule KD-47) | **42%** (5/12) | GAP-15..17 (new); KD-46/47/50 open (KD-53 CLOSED-SIMULATED —
  `r185e-eh-batch-dup-kind.md`; KD-46 remains OPEN: no witness receipt for its
  census.test.cjs:259 falsifier) |
| Service Bus $cbs put-token | core-amqp, pyamqp | 6 of 6 FULL | none | **100%** (6/6) | — |
| Service Bus locks / sessions / encoder | @azure/service-bus, azure-servicebus | 6 of 7 FULL | 1 PARTIAL (KD-50 camelCase readback) | **86%** (6/7) | KD-50 open |
| Key Vault | @azure/keyvault-keys, azure-keyvault-keys | 6 of 20 rows FULL (create, list, release, challenge KD-15 closed, base64url) | 7 MISSING (versioned GET, PUT update, deletedkeys, rotation, backup/restore, random bytes, attestation) + 7 PARTIAL (versions pager, versioned crypto KD-16, api-version KD-34, kid KD-33, alg register) | **30%** (6/20) | GAP-18..22 (new); KD-10..17/33/34 open |
| ARM control plane | @azure/arm-resources 8.0.0, azure-mgmt-resource 23.4.0, msal-node | 14 of 28 exercised signatures FULL (RG CRUD, generic resource, by-id, LRO envelope, STS, msal discovery) | 10 MISSING (locations KD-30, list-by-rg KD-31, RG PATCH KD-32, + GAP-24..29) + 3 PARTIAL (providers aggregate, api-version ceiling, KD-26 re-witness) + 1 UNSUPPORTED-REGISTERED (tags-at-scope GraphLaw 400) | **50%** (14/28) | GAP-24..29 (KD-54..59 registered; KD-54 CLOSED-SIMULATED —
  `r119-r123-arm-list-store-reseed.md`); KD-30/31/32/26/35 open |
| Sentinel / Log Analytics | azure-monitor-query (PY; SDK absent — probe-harness diff) | 1 of 2 ops FULL (DCR ingest, exact template match) | 1 PARTIAL (KQL query: project leak KD-22, batch `queries` absent) | **50%** (1/2) | GAP-29 (new); KD-22 open |
| Resource Graph | azure-mgmt-resourcegraph 8.0.1 | 6 of 11 fields MATCH | 4 MISSING sub-features (resultFormat, facets, managementGroups, allowPartialScopes) + 1 DIVERGENCE (resultTruncated bool vs str enum) | **55%** (6/11) | GAP-30..32 (new); KD-23 open |
| APIM Gateway | @azure/apimanagement (SDK absent on disk) | 0 — zero matching route arms in egress_router.ex | entire service-level surface | **0%** (0/1) | GAP-33 |
| Cognitive Search | @azure/search-documents (SDK absent on disk) | 0 — no index/search route arms | entire surface | **0%** (0/1) | GAP-34 |
| Purview / Atlas v2 | @azure/purview-catalog (SDK absent on disk) | 5 mounted routes FULL against moduledoc-pinned shapes (relationship, entity, bulk, guid, lineage) | remainder of the Atlas v2 family (typedefs, classifications, glossary, relationship GET/DELETE, discovery) unmounted → catch-all 404 | **n/a** — family parity UNKNOWN (SDK absent); 5 mounted routes verified | GAP-36 |

Lane-level roll-up (as filed by each lane): AUD-1 FULL 19 / 51 audited;
AUD-2 FULL 40 / 67; AUD-3 FULL 14 / 28 (+1 N/A); AUD-4 FULL 7 / 24 rows.
Recomputed per-service totals above: 91 FULL of 178 audited signatures ≈
**51% wire parity** across the audited surface.

## 2. Actionable Gap Inventory (merged, deduped, sequential)

Status column: **NEW** = no KD row in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`;
**KD-xx** = registered row. Registration state re-read from the ledger at
close of this lane: a concurrent W-8 registration pass landed KD-54..75
(2026-10-15) from the aud1/aud2/aud3 GAP blocks while this consolidation was
in flight — GAP-01..29 are therefore now cross-marked to registered rows;
the **7 NEW gaps are GAP-30..36 (AUD-4)**, whose section landed last and was
not covered by the W-8 pass.

| GAP | Service | Summary | Lane token | Status |
|---|---|---|---|---|
| GAP-01 | Blob | comp mis-dispatch CLASS: unhandled `comp=` values absorbed by generic Put/Get Blob arms → silent overwrite/content-as-200 (appendblock, snapshot, page, pagelist, tags, query, tier, expiry, lease, seal, copy; incl. x-ms-blob-condition-appendpos/-maxsize + x-ms-blob-type). Fix: default-deny comp whitelist + real appendblock arm (412 on appendpos). Falsifier in aud1 §4 | GAP-AUD1-01 (+09) | KD-60 (registered; KD-52 is its closed instance) |
| GAP-02 | Blob | Blob Batch missing — `POST /{a}/{c}?comp=blob` multipart/mixed (BlobBatchClient) → 404 | GAP-AUD1-02 | KD-61 (registered) |
| GAP-03 | Blob | Get User Delegation Key + SAS query auth absent (header-only x-ms-version gate); comp=acl mis-route | GAP-AUD1-03 | KD-62 (registered) |
| GAP-04 | Cosmos | Change Feed (A-IM: Incremental feed) absent — full 200 feed returned to ChangeFeedIterator | GAP-AUD1-04 | KD-63 (registered) |
| GAP-05 | Cosmos | PATCH /dbs/.../docs/:id (RFC 6902) unrouted → 404 | GAP-AUD1-05 | KD-64 (registered) |
| GAP-06 | Cosmos | sprocs / triggers / udfs unrouted → JSON 404 (prefer typed refusal) | GAP-AUD1-06 | KD-65 (registered) |
| GAP-07 | Cosmos | pre/post-trigger headers silently no-op (201 with no execution) | GAP-AUD1-06b | KD-65 (registered; trigger headers no-op filed within KD-65) |
| GAP-08 | Blob | x-ms-range-get-content-md5/crc64 ignored (low; SDK tolerates) | GAP-AUD1-09b | KD-66 (registered, low) |
| GAP-09 | Blob | x-ms-version value never validated (any non-empty passes) (low) | GAP-AUD1-10 | KD-67 (registered, low) |
| GAP-10 | Blob | BlobProperties list XML gaps | GAP-AUD1-07 | KD-02 (OPEN) |
| GAP-11 | Blob | Container DELETE unrouted | GAP-AUD1-08 | KD-05 (OPEN) |
| GAP-12 | Event Hubs | selector-filter (eventPosition) source filter ignored — delivers from cursor 0 | GAP-A2-01 | KD-68 (registered) |
| GAP-13 | Event Hubs | com.microsoft:epoch not enforced — exclusive receivers co-receive | GAP-A2-02 | KD-69 (registered) |
| GAP-14 | Event Hubs | delivery_annotations (last_enqueued_*) absent on deliveries | GAP-A2-03 | KD-70 (registered) |
| GAP-15 | Event Hubs | x-opt-offset / x-opt-enqueued-time / x-opt-partition-key not stamped | GAP-A2-04 | KD-71 (registered) |
| GAP-16 | Service Bus | set/get-session-state → typed 501, unregistered | GAP-A2-05 | KD-72 (registered) |
| GAP-17 | Service Bus | get-message-sessions → typed 501, unregistered | GAP-A2-06 | KD-73 (registered) |
| GAP-18 | Service Bus | batch-delete-messages → typed 501, unregistered (KD-47 covers schedule only) | GAP-A2-07 | KD-74 (registered; KD-47 covers schedule-message only) |
| GAP-19 | Key Vault | versioned KV GET /keys/{name}/{version} 404 (KD-16 covers versioned POST crypto; this is the GET/update route shape) | GAP-A2-08 | KD-16/33 class (W-8 dedupe: KD-16=POST crypto, this is the GET route shape) |
| GAP-20 | Key Vault | updateKey PUT /keys/{name} unrouted | GAP-A2-09 | KD-75 (registered) |
| GAP-21 | Key Vault | versioned crypto URLs + alg register (RS256/PS256 only) | GAP-A2-10 | KD-16 class (dedupe) |
| GAP-22 | Key Vault | deletedkeys / soft-delete / purge / backup-restore surface | GAP-A2-11 | KD-13 class (dedupe) |
| GAP-23 | Key Vault | rotationpolicy / rotate unrouted | GAP-A2-12 | KD-12 class (dedupe) |
| GAP-24 | ARM | GET /subscriptions/{sub}/resources (subscription-level list) → 404; witnessed 1600/2000 storm 404s (c5-arm-storm P1) | GAP-AUD3-54 | KD-54 (registered) |
| GAP-25 | ARM | provider surface holes: /providers/{ns} per-ns + tenant-level + /providers/Microsoft.Resources/operations | GAP-AUD3-55 | KD-55 (registered) |
| GAP-26 | ARM | provider register/unregister + providerPermissions | GAP-AUD3-56 | KD-56 (registered) |
| GAP-27 | ARM | generic PATCH on resources/{resourceId} → diagnosticSettings-only glob → 404 | GAP-AUD3-57 | KD-57 (registered) |
| GAP-28 | ARM | tag operations (tagNames CRUD; resource-scope tags → GraphLaw 400) | GAP-AUD3-58 | KD-58 (registered) |
| GAP-29 | ARM | RG exportTemplate / moveResources / validateMoveResources | GAP-AUD3-59 | KD-59 (registered) |
| GAP-30 | Sentinel | Logs Query batch (`{"queries":[...]}`) unimplemented on registered route | GAP-AUD4-01 | NEW |
| GAP-31 | Resource Graph | resultFormat "table" ignored | GAP-AUD4-02 | NEW |
| GAP-32 | Resource Graph | facets ignored (silently absent from response) | GAP-AUD4-03 | NEW (incl RG-0 api-version) |
| GAP-33 | Resource Graph | managementGroups / allowPartialScopes ignored | GAP-AUD4-07 | NEW |
| GAP-34 | APIM | APIM service surface absent (zero route arms; SDK not vendored — route-level citation UNKNOWN) | GAP-AUD4-04 | NEW |
| GAP-35 | Cognitive Search | index/docs-search surface absent (zero route arms; SDK not vendored) | GAP-AUD4-05 | NEW |
| GAP-36 | Purview/Atlas | Atlas v2 family beyond the 5 mounted routes unmounted → 404 (typedefs, classifications, glossary, relationship GET/DELETE, discovery) | GAP-AUD4-06 | NEW |

Dedup notes:
- GAP-AUD1-09 folded into GAP-01 (same fix arm). GAP-AUD1-06b kept separate
  (distinct mechanism: silent no-op vs route absence).
- GAP-A2-09..12 deduped against the KD ledger (KD-75/16/13/12) rather than
  double-filed; GAP-A2-08 (GAP-19) is covered by the W-8 dedup note
  KD-33/16 class (KD-16 = POST crypto, GAP-19 = GET route shape).
- KD-53 (EH multi-event batch drop) is cited by AUD-2 and already registered
  (commit fd9cfea) — referenced, not re-filed. Update 2026-10-16: KD-53 is
  CLOSED-SIMULATED (shim + witness receipt
  `docs/jira/v26.10.16/receipts/r185e-eh-batch-dup-kind.md` via
  `docs/jira/v26.10.14/receipts/2026-10-15-kd53-eh-batch-witness.md`).
- Net: **36 gap entries; 29 cross-marked to registered KD rows, 7 NEW** —
  GAP-30..36 (AUD-4: Sentinel batch query, Resource Graph resultFormat/
  facets/managementGroups, APIM surface, Cognitive Search surface, Purview
  Atlas v2 family). The 7 NEW gaps are the register's remaining unfilled
  entries from this audit; filing them is the follow-up transition.

## 3. Census verifier

`scripts/audit_surface_census.sh` (+ `docs/audit/census_table.tsv`, 77 SDK wire
templates from the AUD-1/AUD-3 tables) extracts the 111 registered route
macros from `lib/smalt/egress_router.ex` + `lib/smalt/arm_gateway/router.ex`,
matches every SDK template, and prints unmapped SDK wire paths. Scope: the
HTTP-path surfaces (blob/cosmos + ARM); AMQP frame-level signatures (AUD-2)
are table-side, not path-matchable. Exit 1 iff MISSING-UNREGISTERED gaps
without a KD row exist.

Witnessed runs (2026-10-15):
1. Pre-registration baseline (TSV tokens AUD1-xx, pre-KD-54..75 ledger):
   mapped=62 (incl 2 MISROUTE-MAPPED), registered-gaps=3 (KD-31/32,
   tags-at-scope typed refusal), unregistered=16 -> CENSUS FAIL exit 1.
   This run is the anti-vacuity witness: the gate can fail.
2. Post-W-8-registration run (TSV tokens updated to KD-60/62/63/65;
   ledger now spans KD-01..KD-75): mapped=62 (incl 2 MISROUTE-MAPPED:
   blob generic-PUT comp-absorb class KD-60; cosmos change-feed-to-plain-GET
   KD-63), registered-gaps=15 (KD-31/32/55/56/57/58/59/60/62/63/65 x2/
   59 x2, tags-at-scope UNSUPPORTED-REGISTERED), unregistered=0 ->
   **CENSUS PASS, exit 0**. Anti-vacuity negative control: reverting the
   TSV token updates returns the run to FAIL.

Scope note: the TSV covers the AUD-1/AUD-3 HTTP-path surfaces; AUD-2's
AMQP frame-level signatures and AUD-4's surfaces are not path-matchable
and are covered by the GAP inventory (§2) instead.
