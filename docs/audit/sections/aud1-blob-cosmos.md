# AUD-1 Wire-Parity Audit — Blob Storage + Cosmos DB

Lane AUD-1, adversarial mechanical code-level audit, SDK source vs smalt
implementation, read-only. Every claim cites SDK source + smalt source.

SDK sources used:

- TS: `test/sdk-full/node_modules/@azure/storage-blob/dist/esm/generated/src/models/parameters.js`
  (x-ms-version wire default `2026-10-06`), `.../generated/src/operations/{appendBlob,blockBlob,pageBlob,container,service}.js`
- TS: `test/sdk-full/node_modules/@azure/cosmos/dist/esm/common/constants.js`,
  `dist/esm/request/request.js`
- PY: `test/sdk-python/.venv-blob/lib/python3.14/site-packages/azure/storage/blob/_shared/base_client.py:360`
  (`x-ms-version` header), `_generated/models` (x-ms-blob-condition-appendpos/maxsize);
  `.venv-cosmos/.../azure/cosmos/http_constants.py` (x-ms-documentdb-* set, identical to TS)

## 1. Blob `comp`/`restype` wire surface vs smalt route arms

SDK comp/restype inventory (parameters.js, extracted verbatim): `service
properties`, `stats`, `list` (service + container), `userdelegationkey`,
`account` (restype=account), `batch`, `blobs` (Find Blobs by Tags),
`container`, `metadata`, `acl`, `undelete`, `rename`, `lease`, `expiry`,
`immutabilityPolicies`, `legalhold`, `snapshot`, `copy`, `tier`, `query`,
`tags`, `page`, `pagelist`, `incrementalcopy`, `appendblock`, `seal`,
`block`, `blocklist`; restype: `service`, `account`, `container`.

| # | SDK operation (wire) | State | smalt site | gap / KD |
|---|---|---|---|---|
| 1 | Put Blob `PUT /{a}/{c}/{b}` | FULL-WIRE-SUPPORT | egress_router.ex:1067-1098 → blob_storage.ex:126 put_blob/6 | preconditions + WORM + 1 MiB fence |
| 2 | Put Block `PUT ?comp=block&blockid=` | FULL-WIRE-SUPPORT (KD-52 fix verified) | egress_router.ex:1048 → blob_storage.ex:275 stage_block | blockid grammar fenced, per-block 1 MiB |
| 3 | Put Block List `PUT ?comp=blocklist` | FULL-WIRE-SUPPORT (KD-52 fix verified) | egress_router.ex:1048 → blob_storage.ex:330 commit_block_list | court receipt x1-blocklist-fix.md |
| 4 | Get Block List `GET ?comp=blocklist` | FULL-WIRE-SUPPORT | egress_router.ex:1142 → blob_storage.ex:447 | application/xml (KD-52 div 2 fixed) |
| 5 | Set/Get Blob Metadata `?comp=metadata` | FULL-WIRE-SUPPORT | egress_router.ex:1054 → blob_storage.ex:714 | KD-01 verified: 200 empty, replace semantics |
| 6 | Set/Get Container Metadata `?comp=metadata` | FULL-WIRE-SUPPORT | egress_router.ex:863 / 961 → blob_service.ex:157 / 188 | |
| 7 | Get Container Properties `?restype=container` | FULL-WIRE-SUPPORT | egress_router.ex:1003 → blob_service.ex:212 | KD-03 verified: rfc1123/1 (blob_service.ex:245) |
| 8 | HEAD container / HEAD blob | FULL-WIRE-SUPPORT | egress_router.ex:1228 / 1255 | HEAD blob ignores comp=metadata (minor) |
| 9 | List Blobs `GET ?comp=list` | PARTIAL-WIRE-STUB | egress_router.ex:977 → blob_storage.ex:887 | KD-02 verified OPEN: render_blob (blob_storage.ex:1003-1014) emits only Content-Length/Etag/Last-Modified (ISO-8601, not RFC-1123); no BlobType/LeaseStatus/Content-Type/Content-MD5; `<Prefix>` echoes the stored key prefix |
| 10 | List Containers `GET /{a}?comp=list` | PARTIAL-WIRE-STUB | egress_router.ex:780 → blob_service.ex:80 | same Properties-element gaps; no `include` handling |
| 11 | Get User Delegation Key `POST /{a}?comp=userdelegationkey` | MISSING-UNREGISTERED | no POST 1-segment route → catch-all 404 (egress_router.ex:1298) | SAS delegation-key flows dead |
| 12 | Get/Set Container ACL `PUT/GET ?comp=acl` | MISSING-UNREGISTERED (MIS-ROUTED) | PUT falls to the create-container arm (egress_router.ex:876) → 409 ContainerAlreadyExists on an existing container; GET falls to the list arm (1016) → blob-list XML 200 | silent wrong semantics, no KD row |
| 13 | Container/Blob Lease `PUT ?comp=lease` | MISSING-UNREGISTERED (MIS-ROUTED) | PUT container → create-container arm → 409; PUT blob → put_blob arm (1067) stores the (empty) lease body AS THE BLOB BODY | KD-52 corruption class |
| 14 | Snapshot Blob `PUT ?comp=snapshot` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob arm (egress_router.ex:1067) overwrites the blob with the snapshot request's empty body | corruption class |
| 15 | Copy Blob `PUT` + `x-ms-copy-source` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob never reads x-ms-copy-source (blob_storage.ex:126-178) — empty body stored over the destination | corruption class |
| 16 | Set Tier `PUT ?comp=tier` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob arm overwrite with empty body | corruption class |
| 17 | Set Expiry `PUT ?comp=expiry` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob arm overwrite | corruption class |
| 18 | Append Block `PUT ?comp=appendblock` | MISSING-UNREGISTERED (MIS-ROUTED) | no appendblock arm — falls to put_blob (egress_router.ex:1067) → REPLACES the blob with the single block instead of appending | x-ms-blob-condition-appendpos (parameters.js:1668) ignored; appendBlob.js:121/163/212 |
| 19 | Page Blob create `PUT` + x-ms-blob-type=PageBlob; Page Write `PUT ?comp=page` | MISSING-UNREGISTERED (MIS-ROUTED) | x-ms-blob-type never read (blob_storage.ex:126); comp=page → put_blob overwrite with page bytes | corruption class |
| 20 | Get Page Ranges `GET ?comp=pagelist` | MISSING-UNREGISTERED (MIS-ROUTED) | falls past the blocklist branch to the conditional-get → serves blob CONTENT as 200 application/octet-stream (SDK XML decode error) | KD-52 Get-Block-List bug repeated |
| 21 | Get/Set Blob Tags `GET/PUT ?comp=tags` | MISSING-UNREGISTERED (MIS-ROUTED) | GET serves blob content; PUT overwrites blob with tags XML | corruption class |
| 22 | Query Blob Content `PUT ?comp=query` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob overwrite with query XML | corruption class |
| 23 | Seal Append Blob `PUT ?comp=seal` | MISSING-UNREGISTERED (MIS-ROUTED) | put_blob overwrite | corruption class |
| 24 | Find Blobs by Tags `POST /{a}?comp=blobs` | MISSING-UNREGISTERED | POST /:account matches no route → catch-all 404 (egress_router.ex:1298) | |
| 25 | Blob Batch `POST /{a}/{c}?comp=blob` (comp4 "batch", multipart/mixed) | MISSING-UNREGISTERED | no POST container route → 404 catch-all (egress_router.ex:1298) | BlobBatchClient unusable |
| 26 | Get Account Info `GET ?restype=account&comp=properties` | MISSING-UNREGISTERED | GET /:account arm only handles comp=list (780) → JSON 404; SDK expects XML | |
| 27 | Get Service Stats / Properties `?restype=service` | MISSING-UNREGISTERED | no route → 404 catch-all | |
| 28 | Undelete / Rename container `comp=undelete` / `comp=rename` | MISSING-UNREGISTERED | 404 or mis-route | |
| 29 | Immutability Policy / legal hold (container) | FULL-WIRE-SUPPORT | egress_router.ex:818 / 836 | note: SDK batch plane uses `comp=immutabilityPolicies` plural (parameters.js comp12) — smalt matches only the singular; a batch-plane PUT would fall to the create-container arm |
| 30 | Delete Blob | PARTIAL-WIRE-STUB | egress_router.ex:1278 | KD-05 verified OPEN: no `delete "/:account/:container"` route exists; 2-segment DELETE → catch-all 404 (1298), never 202 |

Headline structural finding: the generic Put Blob / Get Blob fallback arms
(egress_router.ex:1067 / 1166) absorb every `comp` value they do not name
explicitly. KD-52 was one instance (comp=blocklist); the same mis-dispatch
CLASS still absorbs comp=appendblock, snapshot, page, pagelist, tags, query,
tier, expiry, seal, lease, copy — each silently overwriting or serving blob
bodies instead of refusing. A default-deny `comp` whitelist at the top of
both splat routes is the mechanical fix.
UPDATE (lane W-5, v26.10.14): this headline finding is FIXED — fail-closed
comp whitelists now guard both blob splat routes; unlisted comps answer typed
400 and can no longer touch the blob body. See GAP-AUD1-01 status above and
receipt docs/jira/v26.10.14/receipts/w5-comp-whitelist.md.

## 2. Blob headers

| wire header | smalt state | site / evidence |
|---|---|---|
| x-ms-range / Range (ranged GET) | FULL-WIRE-SUPPORT | egress_router.ex:1161 (both headers), blob_storage.ex:774-872 (bytes=a-b / a- / -suffix, 416) |
| If-Match / If-None-Match (get/put/delete) | FULL-WIRE-SUPPORT | blob_storage.ex:808-840, 1122-1154 |
| x-ms-meta-* echo | FULL-WIRE-SUPPORT | blob_service.ex:313, blob_storage.ex:745 |
| x-ms-legal-hold / immutability headers | FULL-WIRE-SUPPORT | blob_storage.ex:658-693 |
| x-ms-blob-condition-appendpos / -maxsize | MISSING (ignored) | parameters.js:1654/1668; put_blob/6 never reads them (blob_storage.ex:126-178) — appendpos violation answered 201 instead of 412 AppendPositionConditionNotMet |
| x-ms-blob-type (PageBlob/AppendBlob create) | MISSING (ignored) | blob_storage.ex:126 |
| x-ms-copy-source | MISSING (ignored) | put_blob never reads |
| x-ms-access-tier / x-ms-lease-* / x-ms-tags / x-ms-expiry-option | MISSING (ignored) | parameters.js inventory |
| x-ms-range-get-content-md5 / crc64 | PARTIAL (ignored; SDK tolerates omission) | egress_router.ex:1166 |
| x-ms-version | PARTIAL-WIRE-STUB | egress_router.ex:1519: presence-only gate; SAS-only URIs (sig= in query, no header) answer 400 MissingXMsVersion — real Azure admits SAS query auth; value never validated (any non-empty passes) |
| SAS query tokens (sig/sv/sp/...) | MISSING-UNREGISTERED | no SAS verification anywhere in lib/ (zero `sig=` handling); token-shaped query strings never validated or refused typed |
| timeout (query) | PARTIAL (ignored — harmless) | parameters.js timeoutInSeconds |

## 3. Cosmos DB wire surface

| # | SDK operation / header | State | smalt site | gap / KD |
|---|---|---|---|---|
| 1 | Create Database `POST /dbs` | FULL-WIRE-SUPPORT | egress_router.ex:183; cosmos.ex:69 | |
| 2 | Database account `GET /` | FULL-WIRE-SUPPORT | egress_router.ex:749 (DatabaseAccount + writableLocations) | python/JS getDatabaseAccount served |
| 3 | List Databases feed envelope | FULL-WIRE-SUPPORT | cosmos.ex:110 ({"Databases", _count}) | KD-09 partial: no pagination |
| 4 | Container CRUD + pk definition | FULL-WIRE-SUPPORT | egress_router.ex:222-307; cosmos.ex:130 | partitionKey kind=Hash filled (egress_router.ex:1437) for python `_ExtractPartitionKey` |
| 5 | pkranges feed + 304 drain | FULL-WIRE-SUPPORT | egress_router.ex:288-307 | |
| 6 | Create doc `POST .../docs` | FULL-WIRE-SUPPORT | cosmos.ex:245-317 | 201 + _etag/_ts/_rid/_self |
| 7 | Upsert `x-ms-documentdb-is-upsert: true` | PARTIAL-WIRE-STUB | cosmos.ex:245 (create_doc never reads the header) | KD-36 verified OPEN: upsert-of-existing answers 409 (cosmos.ex:304 insert_new :exists → Conflict); real Cosmos replaces with 200 |
| 8 | Query `POST docs` + application/query+json | PARTIAL-WIRE-STUB | egress_router.ex:314/1830; cosmos.ex:589 whitelist | KD-06 verified OPEN (narrow whitelist, other forms 400 SyntaxError); x-ms-documentdb-isquery not checked (content-type only — tolerant) |
| 9 | x-ms-max-item-count | PARTIAL-WIRE-STUB | cosmos.ex:38 @query_limit 100 hardcoded, header never read | KD-08 verified OPEN (SDK: request.js:75 `headers[PageSize]`) |
| 10 | x-ms-continuation (query + list feeds) | FULL-WIRE-SUPPORT | cosmos.ex:496-538, 597-677 | container+scope-bound v1/v2 tokens, order-based cursor, 400 on foreign token |
| 11 | x-ms-session-token | FULL-WIRE-SUPPORT | cosmos.ex:1019-1034 (`version#lsn` — matches SDK VectorSessionToken parse) | |
| 12 | x-ms-alt-content-path | FULL-WIRE-SUPPORT | cosmos.ex:1019-1032 | |
| 13 | pk header `x-ms-documentdb-partitionkey` JSON array | FULL-WIRE-SUPPORT | partition_key.ex:35-43 (string/number/bool element) | SDK wire form: request.js:138-139 jsonStringifyAndEscapeNonASCII |
| 14 | Bulk (pk in header + body docs) | PARTIAL-WIRE-STUB | cosmos.ex:245 create_doc treats the bulk POST as single-doc create → pk-mismatch 400 | KD-44 verified OPEN |
| 15 | Change Feed `A-IM: Incremental feed` | MISSING-UNREGISTERED | list_docs (cosmos.ex:496) never reads A-IM — normal 200 feed returned; SDK changefeed iterator mis-parses | constants.js:55 (A_IM), request.js:82-87; never probed |
| 16 | sprocs / triggers / udfs routes | MISSING-UNREGISTERED | no routes → catch-all 404 (egress_router.ex:1298) | constants.js:218-220 path segments, :298-300 resource types |
| 17 | Patch `PATCH .../docs/:id` (RFC 6902) | MISSING-UNREGISTERED | no PATCH route on /dbs → catch-all 404 | constants.js:313 HTTPMethod.patch, :331 OperationType.Patch |
| 18 | RU charge echo / 429 Retry-After | FULL-WIRE-SUPPORT | cosmos.ex:933-979 | x-ms-retry-after-ms + session token on 429 |
| 19 | Master-key Authorization sig | FULL-WIRE-SUPPORT (enforce mode) | cosmos.ex:861-920 | string-to-sign matches real grammar |
| 20 | x-ms-documentdb-partitionkeyrangeid | PARTIAL (accepted-ignored) | pkranges single-range model; header ignored (ClientContext.js:624) | honest single-region model |
| 21 | pre/post-trigger headers | MISSING (ignored — silent no-op) | cosmos.ex:245 gate consults pk/auth/throttle only | real Cosmos executes them; typed UNSUPPORTED candidate |
| 22 | x-ms-documentdb-query / populatequerymetrics | MISSING (ignored, harmless) | | |

## 4. GAP blocks ready for KD filing

### GAP-AUD1-01 — Blob comp mis-dispatch CLASS (KD-52 generic) — CLOSED-WITH-RECEIPT (lane W-5, v26.10.14)
- Status: corruption CLASS dead — fail-closed comp whitelist landed on both blob splat routes (`@blob_put_comps`/`@blob_get_comps`, egress_router.ex PUT/GET arms; unlisted comp → typed 400 InvalidQueryParameter + x-ms-error-code header, never the generic body path). Mutation court PASS: `scripts/shim_court/comp_whitelist_court.sh` (BASELINE→AFTER→SHIM→BEFORE corruption witnessed→RESTORE byte-exact); witness `comp_whitelist_witness.exs`; tests `test/data_plane/blob_hardening_test.exs` GAP-AUD1-01 describe; receipt `docs/jira/v26.10.14/receipts/w5-comp-whitelist.md`. FEATURE GAPS REMAIN AS KD ROWS (appendblock/page/tags/tier/expiry/lease/snapshot/copy/seal/query/pagelist are typed-400 refusals, not implementations).
- SDK Call: Append Block `PUT ?comp=appendblock`; Snapshot `comp=snapshot`; Page Write `comp=page`; Get Page Ranges `comp=pagelist`; Set Tags `comp=tags`; Query `comp=query`; Set Tier `comp=tier`; Set Expiry `comp=expiry`; Lease `comp=lease`; Seal `comp=seal`; Copy `x-ms-copy-source`
- Wire Signature: `PUT/GET /{account}/{container}/{blob}?comp=<unhandled>` must be refused (404/501 typed envelope) for comp values the emulator does not implement; instead the generic Put/Get Blob arms absorb them
- Required Headers: x-ms-version; x-ms-blob-condition-appendpos/-maxsize (append); x-ms-blob-type (page/append create); x-ms-copy-source (copy)
- Smalt Current State: comp not in ["block","blocklist","metadata"] on PUT → read_body + put_blob (egress_router.ex:1067-1098) stores the body as blob content; comp != "blocklist" on GET → conditional read serves blob content (egress_router.ex:1142-1224)
- Root Cause File:Line: lib/smalt/egress_router.ex:1048 (PUT comp whitelist ["block","blocklist"] only) and :1142 (GET names only "blocklist")
- Recommended Action: default-deny `comp` whitelist at the top of both splat routes — known comps dispatch, unknown comps → typed XML `Error` envelope (InvalidQueryParameterValue per KD-04 token); then add a real appendblock arm (append semantics + appendpos/maxsize conditions → 412)
- Minimal Falsifier: `PUT /{a}/{c}/probe.txt?comp=snapshot` with x-ms-version → assert blob content UNCHANGED (today: 201 + content destroyed); `PUT ...?comp=appendblock` twice → assert content is the concat of both blocks; appendpos mismatch → 412

### GAP-AUD1-02 — Blob Batch missing (BlobBatchClient) — CLOSED-WITH-RECEIPT (W-7, 2026-10-15)
- Receipt: docs/jira/v26.10.14/receipts/w7-batch-sas.md — POST /{account}/{container}?comp=batch (and account-level POST /{account}?comp=batch) routes; multipart/mixed parser (boundary content-type, per-part headers stripped, sub-request request-line+headers parsed); sub-requests dispatched to the real engine (Delete Blob -> BlobStorage.delete_blob, Set Blob Tier -> new BlobStorage.set_blob_tier storing access_tier); multipart/mixed 202 response with per-sub-request status line + Content-ID echo; bounded at 256 sub-requests (257 -> 400 SubRequestCountExceedsLimit). Test-pinned in test/data_plane/blob_hardening_test.exs (batch of 3 deletes; set-tier; 257-bound).
- SDK Call: `BlobBatchClient.submitBatch` — `POST /{a}/{c}?comp=blob`, multipart/mixed (parameters.js comp4 "batch")
- Wire Signature: multipart/mixed envelope, per-sub-request `Content-Type: application/http`
- Required Headers: x-ms-version, multipart boundary
- Smalt Current State (post-W-7): POST container/account comp=batch routes + multipart/mixed parse/dispatch/render live in egress_router.ex blob_batch_arm; engine support: BlobStorage.set_blob_tier/5
- Root Cause File:Line: resolved (routes added before the 404 catch-all)
- Recommended Action: done — real multipart dispatch, not typed UNSUPPORTED
- Minimal Falsifier: WITNESSED — batch of 3 deletes -> 202 with three 202 sub-statuses and blobs removed; set-tier sub-request -> blob record access_tier=Cool; 257 sub-requests -> 400 (blob_hardening_test.exs, 105/0 green)

### GAP-AUD1-03 — Get User Delegation Key + SAS query auth absent — CLOSED-WITH-RECEIPT (W-7, 2026-10-15; user-delegation-key issuance itself remains UNSUPPORTED)
- Receipt: docs/jira/v26.10-14 placeholder-fixme `BlobServiceClient.getUserDelegationKey` `POST /{a}?comp=userdelegationkey` (parameters.js comp3); SAS query auth generally; related: `comp=acl` mis-route (GAP-AUD1-01 class)
- Wire Signature: XML KeyList response; SAS URIs (`sig=` in query) must be admitted WITHOUT an x-ms-version header
- Required Headers: none beyond the SAS query string
- Smalt Current State: POST /:account → 404 catch-all (egress_router.ex:1298); blob_route_guarded (egress_router.ex:1516-1543) requires the x-ms-version header → SAS-only URIs get 400 MissingXMsVersion; no sig verification exists in lib/ (zero matches)
- Root Cause File:Line: lib/smalt/egress_router.ex:1519 (header-only gate)
- Recommended Action: admit sig= query URIs (a typed UNSUPPORTED verification token is acceptable per audit convention); add comp=acl arm or typed UNSUPPORTED
- Minimal Falsifier: hand-rolled SAS URI `...?sv=...&sig=...` without x-ms-version → today 400 MissingXMsVersion; assert the admission decision becomes a TYPED decision (verified-or-coded-4xx), never MissingXMsVersion

### GAP-AUD1-04 — Cosmos Change Feed (A-IM: Incremental feed) absent — CLOSED-WITH-RECEIPT (W-6, 2026-10-15)
- Receipt: docs/jira/v26.10.14/receipts/w6-feed-patch.md — change_feed/list_docs honor `A-IM: Incremental feed`; per-container cursor (`ts` + id=>_etag boundary pins) in `:smalt_cosmos_pk_meta` under `{2, db, coll}`; continuation token emitted; without the header list behavior is unchanged (test-pinned)
- SDK Call: `container.readChangeFeed` / ChangeFeedIterator (LatestVersion mode)
- Wire Signature: `GET /dbs/:db/colls/:coll/docs` with `A-IM: Incremental feed` + partition-key header or cross-partition; real Cosmos answers 304 when no new docs
- Required Headers: A-IM, If-None-Match / If-Modified-Since, x-ms-continuation
- Smalt Current State: list_docs (cosmos.ex:496) never reads A-IM — a normal 200 full feed is returned; the SDK changefeed iterator receives the whole container as "changes"
- Root Cause File:Line: lib/smalt/data_plane/cosmos.ex:496 (no A-IM read; gate at :497-538 consults x-ms-continuation only)
- Recommended Action: detect A-IM → serve an incremental feed (LSN/_ts-gated, 304 when none) or mint typed UNSUPPORTED
- Minimal Falsifier: readChangeFeed fromNow → iterator must halt with zero changes after seeding; today returns the full container as changed

### GAP-AUD1-05 — Cosmos Patch (RFC 6902) unrouted — CLOSED-WITH-RECEIPT (W-6, 2026-10-15)
- Receipt: docs/jira/v26.10.14/receipts/w6-feed-patch.md — PATCH route + RFC 6902 engine (add/remove/replace/test/move/copy, RFC 6901 pointers), If-Match CAS (412 on mismatch/race), typed 400 malformed, 404 missing, full-document re-storage with fresh _etag/_ts (test-pinned)
- SDK Call: `item.patch` (constants.js:313 HTTPMethod.patch; :331 OperationType.Patch)
- Wire Signature: `PATCH /dbs/:db/colls/:coll/docs/:id`, content-type application/json_patch+json, body = RFC 6902 ops array
- Required Headers: x-ms-documentdb-partitionkey, optional If-Match
- Smalt Current State: no PATCH route on the /dbs surface (routes end at delete_doc, egress_router.ex:362) → catch-all 404 (1298)
- Root Cause File:Line: lib/smalt/egress_router.ex (PATCH route absent between :354-366)
- Recommended Action: add PATCH route + RFC 6902 engine (add/remove/replace/test) honoring If-Match/_etag, or typed UNSUPPORTED
- Minimal Falsifier: `item.patch([{op:"replace",path:"/v",value:2}])` → 200 with new _etag and GET shows v=2; today 404

### GAP-AUD1-06 — Stored procedures / triggers / UDFs unrouted
- SDK Call: `Scripts` client (StoredProcedure/Trigger/UserDefinedFunction) — constants.js:218-220 path segments, :298-300 resource types
- Wire Signature: `POST/GET/PUT/DELETE /dbs/:db/colls/:coll/{sprocs,triggers,udfs}/:name`
- Required Headers: x-ms-version, cosmos standard headers
- Smalt Current State: no routes → catch-all 404 JSON RouteNotFound (egress_router.ex:1298)
- Root Cause File:Line: lib/smalt/egress_router.ex (routes absent)
- Recommended Action: typed UNSUPPORTED refusal (Cosmos error envelope with code) — JS sproc eval out of scope; prefer typed refusal over 404
- Minimal Falsifier: `scripts.create(sproc)` → typed Cosmos-coded refusal instead of JSON 404 RouteNotFound

### GAP-AUD1-06b — Triggers silently no-op
- SDK Call: item create with `x-ms-documentdb-pre-trigger-include` / `post-trigger-include` (python http_constants.py inventory)
- Wire Signature: header present on POST docs → real Cosmos executes the trigger before/after the write
- Smalt Current State: headers ignored (cosmos.ex:245 gate consults pk/auth/throttle only) → 201 silent no-op
- Root Cause File:Line: lib/smalt/data_plane/cosmos.ex:245-253
- Recommended Action: present-but-unimplemented trigger headers → typed 400/501 (never a silent success)
- Minimal Falsifier: create with pre-trigger-include set → assert typed refusal (today 201)

### GAP-AUD1-07 — Blob list BlobProperties gaps (KD-02 confirmation — no new token)
- Confirms KD-02 OPEN: render_blob (blob_storage.ex:1003-1014) minimal Properties element; ISO-8601 Last-Modified; key-prefix echo at :993. File under the existing KD-02 row.
- Minimal Falsifier: existing (py probe 05 re-run)

### GAP-AUD1-08 — Container Delete unrouted (KD-05 confirmation — no new token)
- Confirms KD-05 OPEN: no `delete "/:account/:container"` route; 2-segment DELETE → catch-all 404 (egress_router.ex:1298)
- Minimal Falsifier: existing (SDK container delete → 202)

### GAP-AUD1-09 — x-ms-blob-condition-appendpos/maxsize ignored
- Filed within GAP-AUD1-01 (append arm); listed for the header-level falsifier: parameters.js:1654/1668
- Minimal Falsifier: PUT comp=appendblock with appendpos mismatch → must be 412 AppendPositionConditionNotMet; today the header is never read (blob_storage.ex:126)

### GAP-AUD1-09b — x-ms-range-get-content-md5/crc64 ignored
- parameters.js rangeGetContentMD5/CRC64; smalt answers full-200 with no Content-MD5 (egress_router.ex:1166). Typed UNSUPPORTED candidate; SDK tolerates omission — low severity

### GAP-AUD1-10 — x-ms-version value never validated
- parameters.js `version` default `2026-10-06`; real Azure validates the `YYYY-MM-DD` grammar and 400s unknown versions; smalt accepts any non-empty value (egress_router.ex:1519) — presence-only gate. Low severity.

## 5. Known anchors — verification status

| anchor | status | evidence |
|---|---|---|
| KD-52 block/blocklist arms | VERIFIED FIXED | egress_router.ex:1048 dedicated arms; blob_storage.ex:275/330 staged-block store; block_list_xml application/xml (478-487); court receipt cited |
| KD-01 Set-Metadata 200-empty | VERIFIED FIXED | egress_router.ex:1054-1065 (200 empty before body read); blob_storage.ex:714 replace semantics |
| KD-03 RFC-1123 | VERIFIED FIXED | blob_service.ex:245-251 rfc1123/1, used at :224 |
| KD-07 ReadFeed envelope | VERIFIED FIXED | egress_router.ex:330-352 {"_rid","Documents","_count"} |
| KD-36 upsert 409 | VERIFIED STILL OPEN | cosmos.ex:245-317 no is-upsert read; 409 at :304 |
| KD-44 bulk | VERIFIED STILL OPEN | no bulk handler; create_doc single-doc path 400s on pk mismatch (cosmos.ex:283-317; partition_key.ex:74-106) |
| KD-05 container delete | VERIFIED STILL OPEN | no 2-segment DELETE route; catch-all 404 egress_router.ex:1298 |
| KD-02 list BlobProperties | VERIFIED STILL OPEN | blob_storage.ex:1003-1014 |
| KD-06 query whitelist | VERIFIED STILL OPEN | cosmos.ex:589-592 |
| KD-08 max-item-count | VERIFIED (open) | cosmos.ex:38; header ignored |
| KD-09 container list pagination | VERIFIED (open) | cosmos.ex:172-185 full feed, no continuation |
| whitelist gate | verified (KD-06) | cosmos.ex:589 |
| blocklist court fences | verified | test/data_plane/blob_hardening_test.exs (113 tests) |
| x-ms-range support | verified FULL | egress_router.ex:1161; blob_storage.ex:844-872 |
| pk header JSON-array format | verified FULL | partition_key.ex:35-43 vs cosmos request.js:138-139 |

## 6. Counts

| state | count |
|---|---|
| FULL-WIRE-SUPPORT | 19 |
| PARTIAL-WIRE-STUB | 8 |
| MISSING-UNREGISTERED | 24 (10 mis-routed into the generic Put/Get Blob arms — the KD-52 class — 14 hard-404) |
| UNSUPPORTED-REGISTERED | 0 (no KD row covers any audited signature; WIRE_PARITY typed tokens cover EH/SB surfaces, not blob/cosmos wire ops) |
| Total signatures audited | 51 (30 blob comp/restype + header rows, 22 cosmos rows) |
