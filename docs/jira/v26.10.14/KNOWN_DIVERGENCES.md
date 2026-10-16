# Known Wire Divergences — v26.10.14 SDK Validation Waves

# KNOWN_DIVERGENCES

## Register (2026-10-15)

Named, wire-evidenced divergences filed by the v26.10.14 SDK validation waves
(`docs/jira/v26.10.14/sdk-results/*.md` + `receipts/18-mutation-courts.md`).
This doc REGISTERS; it does not close. Every row is OPEN. Close condition is
either a fix-shape landing (receipt + falsifier re-run) or a typed-UNSUPPORTED
token minted in `docs/WIRE_PARITY.md`. Do not mint new GAP tokens unilaterally.

## Table

| id | surface | divergence | evidence receipt | close condition | status |
|---|---|---|---|---|---|
| KD-01 | blob `?comp=metadata` | Set Blob Metadata answers 201 Created (with JSON debug body per TS-2); Azure/spec: 200 with empty body | `sdk-results/py-storage-blob.md` (probe 04), `sdk-results/ts-storage-blob.md` (D1) | blob route returns 200 empty-body; falsifier: py probe 04 + ts D1 re-run | OPEN |
| KD-02 | blob `comp=list` XML | BlobProperties missing required elements (BlobType, LeaseStatus, Content-Type, ...) and `<Last-Modified>` ISO-8601 not RFC-1123; `<Prefix>` echoes account-prefixed path | `sdk-results/py-storage-blob.md` (probe 05) | full BlobProperties + RFC-1123 dates; falsifier: py probe 05 | OPEN |
| KD-03 | blob Get Container Properties | `last-modified` ISO-8601 instead of RFC-1123 (Create Container is correct) | `sdk-results/py-storage-blob.md` (probe 10) | RFC-1123 on GET/HEAD container props; falsifier: py probe 10 | OPEN |
| KD-04 | blob error envelope | 400 `InvalidQueryParameter` vs Azure `InvalidQueryParameterValue` token | `sdk-results/ts-storage-blob.md` (D2) | rename error code token | OPEN |
| KD-05 | blob container DELETE | container delete answers 404 "specified blob does not exist" — mis-routed to blob-delete clause (stable x3 windows) | `sdk-results/ts-storage-blob.md` (D3) | router dispatch-order fix; falsifier: SDK container delete → 202 | OPEN |
| KD-06 | cosmos query whitelist | `SELECT * FROM root` admitted (alias not pinned in whitelist); other non-`SELECT * FROM c` forms 400 | `sdk-results/py-cosmos.md` (div 1) | pin alias set in whitelist (admit or type UNSUPPORTED) | OPEN |
| KD-07 | cosmos ReadFeed | non-query read feed returns bare JSON array; SDK expects `{"Documents":[...],"_count":n}` envelope | `sdk-results/py-cosmos.md` (div 2) | envelope the ReadFeed response | OPEN |
| KD-08 | cosmos query feed | `x-ms-max-item-count` ignored (requested 10, got server default 100) | `sdk-results/py-cosmos.md` (div 3) | honor header on query feed | OPEN |
| KD-09 | cosmos container list | 151 containers in one page, no continuation token | `sdk-results/py-cosmos.md` (div 4) | paginate container feed, honor maxItemCount | OPEN |
| KD-10 | KV create | `PUT /keys/{name}` unrouted (falls to blob catch-all 400 MissingXMsVersion); substrate has only `POST /keys/:name/create` | `sdk-results/ts-keyvault.md` (d1), `sdk-results/py-auth-keyvault.md` (D3) | add PUT route or typed UNSUPPORTED | OPEN |
| KD-11 | KV update | `PATCH /keys/{name}/{version}` unrouted | `sdk-results/ts-keyvault.md` (d2) | add PATCH route | OPEN |
| KD-12 | KV rotation | `GET/PUT /keys/:name/rotationpolicy` 400-class (blob catch-all) | `sdk-results/ts-keyvault.md` (d3) | route or typed UNSUPPORTED | OPEN |
| KD-13 | KV delete/purge | `DELETE /keys/:name`, `purgeDeletedKey`, soft-delete plane absent | `sdk-results/ts-keyvault.md` (d4), `sdk-results/py-auth-keyvault.md` (D4) | add delete/purge routes or typed UNSUPPORTED | OPEN |
| KD-14 | KV crypto verify | SDK `verify("RS256",...)` = false while the same sig verifies true against the public JWK — verify re-hashes/misaligns; external verifiers broken | `sdk-results/ts-keyvault.md` (d5) | align verify with SDK-submitted digest; falsifier: SDK verify=true | OPEN |
| KD-15 | KV challenge auth | 401 `WWW-Authenticate: Bearer error=...` lacks `authorization`/`authorization_uri` + `resource`/`scope`; ChallengeAuthPolicy refuses → challenge-based TokenCredential flows never attach tokens | `sdk-results/ts-keyvault.md` (d6), `sdk-results/py-auth-keyvault.md` (D1) | add challenge params; falsifier: DefaultAzureCredential flow attaches | OPEN |
| KD-16 | KV versioned crypto | `POST /keys/{name}/{version}/encrypt\|decrypt` unrouted; served kids lack `/{version}` segment so CryptographyClient unconstructible | `sdk-results/py-auth-keyvault.md` (D5) | add versioned routes + versioned kid | OPEN |
| KD-17 | KV release policy | SDK sends `release_policy:{contentType, encodedPolicy}`; substrate validates inline anyOf/allOf/claim/equals map — SDK-shaped create 400s | `sdk-results/py-auth-keyvault.md` (D6) | accept SDK envelope | OPEN |
| KD-18 | EH AMQP delivery | `deliver_eventhubs/2` transfer omits `message_format` — rhea/SDK decode as raw buffer (ev.body etc. undefined); one-line fix | `sdk-results/ts-event-hubs.md` (gap 1) | add `message_format: 0` | OPEN |
| KD-19 | EH $management | EH mgmt ops (getEventHubProperties/getPartitionProperties) 501 UNSUPPORTED_OPERATION — ManagementRpc implements SB ops only; subscribe() bootstrap fails | `sdk-results/ts-event-hubs.md` (gap 2); overlaps `GAP(eventhubs-partition-metadata-absent)` (WIRE_PARITY:148) | route EH-mode $management to an EH dispatcher, or fold under the existing GAP token | OPEN |
| KD-20 | EH credit | `deliver_eventhubs/2` delivers without decrementing link credit (witnessed credit-0 transfers); SB path bumps credit | `sdk-results/ts-event-hubs.md` (gap 3) | `bump_credit(link, -1)` on EH path | OPEN |
| KD-21 | EH AMQP open frame | spec-legal trailing-null trim on `open` crashes pyamqp `_incoming_open` (frame[4] unguarded); Node tolerates; Python SDK unusable against the lane | `sdk-results/py-eventhub-eventgrid.md` | pad open to >=5 fields (attach must stay trimmed — asymmetric); or upstream pyamqp fix | OPEN |
| KD-22 | Sentinel KQL | `project_columns/1` regex `\bproject\s+(.+)$` runs to EOS — stages after `project` leak into PrimaryResult column names | `sdk-results/py-resourcegraph-monitor.md` (finding 1) | parse from KQL AST `{:project, cols}`; falsifier: p20b flips | OPEN |
| KD-23 | ResourceGraph | `normalize_pipeline/1` normalizes bare `where` only when query has no `\|`; mixed form `where ... \| project` 400s BadQuery | `sdk-results/py-resourcegraph-monitor.md` (finding 2) | normalize mixed piped/bare forms | OPEN |
| KD-24 | ARM router | double-slash generic PUT (`providers/Microsoft.Storage//storageAccounts/...`) 404s; real ARM collapses `//` | `sdk-results/py-arm-resources.md` (D3) | collapse `//` in path matching | OPEN |
| KD-25 | ARM shape gate | GraphLaw requires `properties.skuName`; real ARM takes top-level `sku.name` | `sdk-results/py-arm-resources.md` (D4) | resolve shape paths against real-ARM body shape | OPEN |
| KD-26 | ARM LRO terminal | created storageAccount lacks `provisioningState` post-LRO (SDK state=None) | `sdk-results/py-arm-resources.md` (D5) | render provisioningState at LRO terminal | OPEN |
| KD-27 | ARM metadata | `resourceManagerEndpoint` hardcodes `http://localhost:9443/` regardless of actual listener port | `sdk-results/py-arm-resources.md` (D6) | derive from actual listener | OPEN |
| KD-28 | ARM NSG shape | `Microsoft.Network/networkSecurityGroups` NsgShape has no required paths, `sh:closed false` → malformed NSG PUT admitted 201 | `receipts/18-mutation-courts.md` (V261014-18-D1) | tighten shape; falsifier: malformed PUT → 400 | OPEN |
| KD-29 | ARM virtualNetworkLinks | `privateDnsZones/virtualNetworkLinks` admitted Registry type with NO ARM PUT route — 404 before shape gate; type unreachable | `receipts/18-mutation-courts.md` (V261014-18-D2) | `handle_child_put/5` child route (vault-keys pattern) | OPEN |
| KD-30 | ARM locations | `GET /subscriptions/{sub}/locations` 404 RouteNotFound | `sdk-results/ts-arm-resources.md` (D1) | add locations route | OPEN |
| KD-31 | ARM list-by-rg | `GET .../resourcegroups/{rg}/resources` 404 RouteNotFound | `sdk-results/ts-arm-resources.md` (D2) | add list-by-rg route | OPEN |
| KD-32 | ARM RG PATCH | `PATCH .../resourcegroups/{name}` (tags) 404 RouteNotFound | `sdk-results/ts-arm-resources.md` (D3) | add RG PATCH route | OPEN |
| KD-33 | KV kid placement | top-level `kid` undefined (nests under `key.kid` only) — SDK tolerates; surface nit | `sdk-results/ts-keyvault.md` (d9) | hoist top-level kid | OPEN |
| KD-34 | KV api-version encoding | SDK 4.10 sends `api%2Dversion=2025-07-01` (percent-encoded hyphen); substrate ignores it — harmless here, breaks api-version-pinned routing | `sdk-results/ts-keyvault.md` (d8) | decode percent-encoded query keys | OPEN |
| KD-35 | egress TLS | egress planes are http-only; azure-core refuses Bearer over http — real SDK consumers need an external TLS terminator (ARM has a TLS twin) | `sdk-results/py-auth-keyvault.md` (D2), `sdk-results/py-arm-resources.md` (D2) | TLS twin for egress, or typed compat-note | OPEN |

| KD-36 | cosmos TS upsert | upsert-of-existing returns 409 Conflict (x-ms-documentdb-is-upsert flag ignored, create semantics applied); real Cosmos upserts 200 replace — 4/4 runs | `sdk-results/ts-cosmos.md` (probe 9), SDK_MATRIX.md (cosmos TS cell) | honor is-upsert flag → replace semantics; falsifier: probe 9 re-run 200 | OPEN |
| KD-44 | cosmos TS bulk | `items.bulk` always 400 "Partition key provided in the header doesn't match the partition key of the document" — SDK sends pk in header + body; smalt bulk handler rejects the real wire shape (single- and cross-partition, 3/3 runs) | `sdk-results/ts-cosmos.md` (probes 16-17), SDK_MATRIX.md (cosmos TS cell) | accept SDK bulk wire shape; falsifier: probes 16-17 re-run PASS | OPEN |
| KD-37 | sentinel | no probe cell (ts) | SDK_MATRIX.md (sentinel TS cell) | probe authoring (next window) | OPEN |
| KD-38 | resource-graph | no probe cell (ts) | SDK_MATRIX.md (resource-graph TS cell) | probe authoring (next window) | OPEN |
| KD-39 | eventgrid | no probe cell (ts) | SDK_MATRIX.md (eventgrid TS cell) | probe authoring (next window) | OPEN |
| KD-40 | purview-atlas | no probe cell (ts) | SDK_MATRIX.md (purview-atlas TS cell) | probe authoring (next window) | OPEN |
| KD-41 | purview-atlas | no probe cell (py) | SDK_MATRIX.md (purview-atlas PY cell) | probe authoring (next window) | OPEN |
| KD-42 | ledger | no probe cell (ts) | SDK_MATRIX.md (ledger TS cell) | probe authoring (next window) | OPEN |
| KD-43 | ledger | no probe cell (py) | SDK_MATRIX.md (ledger PY cell) | probe authoring (next window) | OPEN |
| KD-45 | SB management ATOM+XML | ATOM+XML queue-create PUT (`ServiceBusAdministrationClient.createQueue`, `PUT /{queue}?api-version=2024-05`, `content-type: application/atom+xml;type=entry`) gets a response Node's HTTP parser rejects — `RestError: Parse Error: Expected HTTP/, RTSP/ or ICE/ (HPE_INVALID_CONSTANT)`; probes blocked before their scenario (stale-handle, lock-duration) | `sdk-results/ts-servicebus-census.md` (stale-handle, lock-duration) | return a well-framed HTTP/1.x ATOM+XML response from the AMQP-port management surface; falsifier: createQueue → 201 and probes proceed | OPEN |
| KD-46 | SB deferred redelivery | deferred message redelivered via receive-by-sequence-number carries no `deliveryCount` (undefined; probe asserts 2) — deliveryCount annotation missing on the deferred-redelivery wire path | `sdk-results/ts-servicebus-census.md` (deferred-receive) | set deliveryCount on deferred redelivery; falsifier: census.test.cjs:259 passes | OPEN |
| KD-47 | SB scheduleMessage | `scheduleMessages` → `NotImplementedError: UNSUPPORTED_OPERATION` — `$management` scheduling operation unimplemented (CBS put-token 200, management op refused) | `sdk-results/ts-servicebus-census.md` (sb-extra.probe.cjs) | implement `$management` schedule op or keep typed UNSUPPORTED; falsifier: scheduleMessage → sequence numbers returned | OPEN. Same `$management` link tier as KD-19 (EH mgmt ops 501) but distinct mechanism: KD-19 is EH-mode dispatch absence; KD-47 is the SB scheduling operation itself. Referenced, not duplicated. |
| KD-48 | census harness | `scripts/sb_census_replay.sh` front door never exports `SMALT_TEST_*_PORT`; config/test.exs binds random ephemeral ports unless exported → unmodified front-door invocation structurally cannot pass (exit 2, cold compile misses the 60s poll window). Harness/recipe class, not substrate | `sdk-results/ts-servicebus-census.md` (harness finding) | export SMALT_TEST_*_PORT (or pin) in sb_census_replay.sh; falsifier: unmodified front-door run passes | OPEN |
| KD-49 | AMQP attach echo | `connection.ex handle_attach/3` (`base_attach`) echoes attach with only name/handle/role/initial_delivery_count — omits `source`/`target`; pyamqp `_incoming_attach` requires both → "Invalid link" → detach → CBS open ERROR → azure-servicebus (pyamqp) 0/7, all probes 90 s timeout. rhea tolerates the missing echo (JS census passes) | `sdk-results/py-servicebus.md` (root cause; pyamqp-attach-trace.log) | echo client's source/target from `perf` on every attach response (base + session case); falsifier: py_servicebus.py probe 1 passes | OPEN. Same pyamqp wire tier as KD-21 (open-frame trailing-null trim crashes pyamqp) but distinct frame + mechanism: KD-21 is `open`, KD-49 is `attach`. |
| KD-50 | SB queue properties readback | queue created via ARM PUT with camelCase `lockDuration` reads back snake_case `lock_duration` (lossy normalization); `QueueStore.arm_queue_properties/1` reads `props["lockDuration"]` — may starve the delivery-claim lock path (clamp to default 30s); wire-lane confirmation on the delivery path pending | `sdk-results/py-servicebus.md` (ARM provisioning receipt) | unify property key casing across store/arm/delivery claim; falsifier: PT2S queue enforces 2 s lock expiry | OPEN |
| KD-51 | SB admin client URL space | Python `ServiceBusAdministrationClient` hardcodes `https://` + ARM URL space (`PUT /{entity}` → 404 RouteNotFound); the ATOM plane the JS admin client uses (`$Resources/Queues` over the AMQP port) is unserved — no Python-viable management surface | `sdk-results/py-servicebus.md` (ARM provisioning receipt) | serve the ARM `/namespaces/{ns}/{entity}` space over https (TLS twin, cf. KD-35) or the ATOM management plane; falsifier: Python admin client createQueue succeeds | OPEN |

## Cross-check vs docs/WIRE_PARITY.md gap tokens

- No filed divergence contradicts an existing GAP token. KD-19 overlaps
  `GAP(eventhubs-partition-metadata-absent)` (WIRE_PARITY:148) — referenced,
  not duplicated; its close condition folds into that token's surface.
- KD-04's `InvalidQueryParameter` is the deliberate post-lane-06 token
  (lane 06 closed `GAP(blob-error-envelope-json)` /
  `GAP(blob-x-ms-error-code-header-absent)` and added the maxresults 400);
  KD-04 registers the remaining token-name delta against Azure's
  `InvalidQueryParameterValue`, not a regression.
- No filed divergence contradicts the lane-13 census
  (5 CLOSED-with-receipt + 2 vacuous deletions + 9 typed-UNSUPPORTED tokens +
  Service Bus UNSUPPORTED). The SDK-wave divergences are net-new registers.
- Doc-truth flag: WIRE_PARITY:149 (Event Hubs AMQP wire lane, "ALIVE", "Pinned
  on the real wire by the @azure/event-hubs SDK smoke") is STALE per
  `sdk-results/ts-event-hubs.md` — the smoke currently exits 1
  (getProperties 501, subscribe fails on bootstrap). KD-18/19/20 are the named
  hops. Truth-sync edit deferred to the row owner; flagged here so the
  register is not read as contradicting that row.

## Census

51 registers (KD-01..KD-51; KD-36/44 cosmos-TS rows and KD-45..51 TS-4-census /
PY-4-servicebus rows appended after their receipts landed), all OPEN; this doc
registers, does not close.
