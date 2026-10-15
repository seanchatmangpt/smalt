# C3 — Azure Cosmos DB NoSQL Compliance

# C3_COSMOS

## Scope

Subject: `Smalt.DataPlane.Cosmos` (`lib/smalt/data_plane/cosmos.ex`) +
`Smalt.DataPlane.PartitionKey` (`lib/smalt/data_plane/partition_key.ex`) +
the Cosmos routes of `Smalt.EgressRouter`
(`lib/smalt/egress_router.ex:125-289, 565-597, 954-990, 1311-1327`), smalt
v26.10.14, at the live HTTP wire, verified against the Azure Cosmos DB NoSQL
REST API contract (required response headers, `_etag` quoting, system
properties, partition-key header semantics, `application/query+json` query
envelope, status-code semantics, trailing-slash and account envelope).

Method: live wire probes — `Smalt.EgressRouter` under Bandit, real sockets
(curl against a live anonymous-mode egress instance + per-test Bandit
listeners in the fence suite). Fence tests:
`test/compliance/c3_cosmos.exs` (26 tests, 0 failures, 2026-10-15 lens-7 re-measured; lens-3 added byte-exact response-content-type pins, lens-4 added the row-18 continuation court, lens-7 added emit-then-resume round-trip courts for BOTH the list feed and the query feed)

## Receipt

- Subject: smalt v26.10.14 Cosmos surface (engine + router seam)
- Probe transport: real sockets — curl vs a live anonymous-mode egress
  listener (`:28443`) and inets `:httpc` against per-test Bandit listeners
- Commands: `mix test test/compliance/c3_cosmos.exs` → `26 tests, 0 failures` (lens-7 re-measured)
- Replay: `cd ~/smalt && mix test test/compliance/c3_cosmos.exs`
- Standing: PARTIAL_ALIVE (18 rows: 18 CONFORMANT fenced, 0 GAP — row 18
  re-graded CONFORMANT 2026-10-15 lens-4 after cosmos-lens3's authorized RAISE
  landed and was fenced; prior "1 pinned GAP (row 18)" claim superseded)
- Falsifier: any fence test failing, or any CONFORMANT row's live probe
  diverging from the md row without an md update in the same change.
- Falsifier receipt: `mix test test/compliance/c3_cosmos.exs` → **20 tests,
  0 failures** (2026-10-14; the two absence-PINs flipped to CONFORMANT
  assertions, plus default-`:infinity` and anonymous-mode regression rows).

## Compliance rows

| # | Row | Standing | Spec clause | smalt evidence | Probe result |
|---|-----|----------|-------------|----------------|--------------|
| 1 | Required headers on every response: `x-ms-request-charge`, `x-ms-session-token`, `x-ms-lsn`, `x-ms-alt-content-path` (alt-content-path on resource responses) | CONFORMANT (fenced) | Cosmos REST response headers | `cosmos.ex:465-478` success_headers; emitted by `cosmos_respond` (`egress_router.ex:1361-1373`) | 201/200/404/412/304/204 all carry request-charge + session-token + lsn; alt-content-path on resource ops |
| 2 | `_etag` quoted JSON string; echo in `ETag` header; stable on read, refreshed on write; `_ts` integer seconds | CONFORMANT (fenced) | system properties `_etag`/`_ts` | `cosmos.ex:519-521` quoted_sha256 (leading `"` + 64 hex + `"`); `_ts` at cosmos.ex:213/221/307 | `_etag` `"c3df4b42…"`, ETag header matches, changes on PUT, `_ts` monotonic |
| 3 | System properties `_rid` present, `_self` grammar `/dbs/{db}/colls/{coll}/docs/{id}` | CONFORMANT (fenced) | `_self` path grammar + composite resource-id | `cosmos.ex` `doc_rid/3` (coll rid 12 chars + 8-char doc segment); `_self` name-path grammar unchanged | doc `_rid` = `coll_rid(db, coll) <> rid_segment(id, 8)`, 20-char base64url |
| 4 | DB/container `_rid` grammar (8-char base64 resource id) | CONFORMANT (fenced) | resource-id grammar | `cosmos.ex` `db_rid/1` (8-char base64url of sha256(db)); `coll_rid/2` = db rid + 4-char segment; deterministic across restarts | db `_rid` 8-char base64url; coll `_rid` 12-char composite |
| 5 | Partition-key header `x-ms-documentdb-partitionkey`: JSON array, one scalar (string / number / boolean — type-aware like real Cosmos, lens-2 cycle 8; `null` element refused = pinned divergence); extraction at JSON-pointer path; mismatch/missing/non-array/multi-element → 400 BadRequest | CONFORMANT (fenced) | partition-key header spec | `partition_key.ex parse/1` (scalar clauses, to_string normalization matching `extract/2`); `cosmos.ex` enforce + `query_pk_check/3` | missing / non-array / mismatched / `[null]` / multi-element / object-element / nested-array all → 400 BadRequest; numeric pk end-to-end write+scoped-query fenced |
| 6 | CRUD status semantics: 201 create, 200 read/replace, 204 delete, 404 NotFound, 412 PreconditionFailed, 304 If-None-Match | CONFORMANT (fenced) | REST status contract | `cosmos.ex:226, 244, 314-325, 367-377, 246-248, 255-261` | all live-probed; conditional delete 204→404; stale If-Match 412; 304 on If-None-Match |
| 7 | 400 message on pk failures: real Cosmos: "Partition key provided in the header doesn't match the partition key of the document."; container without pk defined → header not required; container with EMPTY paths (`partitionKey` absent from create body) → header not required, query scans unfiltered | CONFORMANT (fenced for 400-class) | pk 400 message | `cosmos.ex` error_message/2 ("Partition key provided in the header doesn't match the partition key of the document.") byte-equal in engine + cosmos_test fence; `partition_key.ex` `enforce(_, _, %{"paths" => []}) -> :ok`; query_docs no-paths → unfiltered scan | live probe: mismatch message exact; container without pk accepts headerless docs. Byte parity beyond the md row's own quoted sentence is grounded in-repo (engine + fence); live-endpoint byte diff UNKNOWN (no Cosmos credentials in lane) |
| 8 | Query POST `application/query+json` envelope `{"query","parameters"}` → `{"_rid","Documents","_count"}`; a query POST never creates | CONFORMANT (fenced) | query POST contract | `egress_router.ex:1311-1327` query_post?/query_post; `cosmos.ex:417-445` engine; `egress_router.ex:249-256` route order | 200 feed shape exact; malformed body → 400; query POST creates nothing |
| 9 | Cross-partition: `x-ms-documentdb-query-enablecrosspartition` accepted; ABSENT pk header → whole container scans; PRESENT-but-malformed pk header → 400 BadRequest (never a silent cross-partition scan — measured pre-fix leak: "not-json" returned both partitions' docs with 200; closed lens-2 cycle 4, mutation M3-killed) | CONFORMANT (fenced) | cross-partition query | `cosmos.ex do_query_docs` query_pk_check/3 + with-else 400 envelope; absent header = deliberate cross-partition scan; enablecrosspartition header simply unboycotted | 200 on absent header; cross-partition SELECT \* returns EXACTLY both partitions' docs (`_count == 2`, id set `{"d1","d2"}`); pk-scoped query returns exactly the scoped partition (`_count == 1`); malformed headers "not-json"/"[]"/multi/"[1]"/"" all → 400 (c3 + cosmos_test fences, 2026-10-15) | |
| 10 | Collection creation: `partitionKey {paths, kind}`; bare-string pk body normalized | CONFORMANT (fenced) | container contract | `egress_router.ex:966-990` with_pk_kind + normalize_pk_body; `cosmos.ex:98-121` | container record `partitionKey {kind: Hash, paths}` |
| 11 | Trailing slash tolerated on the `/dbs` surface; `GET /` DatabaseAccount envelope (id, writableLocations, consistency default) | CONFORMANT (fenced) | account + routing | `egress_router.ex:954-963` trim_dbs_trailing_slash; `egress_router.ex:565-597` account route | `/dbs/` 200; `GET /` 200 kind=DatabaseAccount with exact location envelope (writable==readable `{"name":"East US","databaseAccountEndpoint":<this plane>}`, MWL=false, id=smalt, Session default) (c3 fence, 2026-10-15) |
| 12 | Session token `version#lsn` format, monotonic on writes | CONFORMANT (fenced) | session token | `cosmos.ex:480` `"1#lsn"`; durable counters `cosmos.ex:484-490` | `1#1` → `1#N` monotonic across writes |
| 13 | Throttling: 429 + `x-ms-retry-after-ms` | CONFORMANT (fenced) | 429 semantics | `cosmos.ex` `gate/5` → `throttle/1`: in-memory 1s fixed-window counter per partition-route (container link) in `:smalt_cosmos_ru` ETS, active only when `Application.get_env(:smalt, :cosmos_ru_limit)` is an integer (default `:infinity` — surface unchanged unless configured); exceeded → `{:ok, 429, …"x-ms-retry-after-ms" => "1"…, %{"code" => "TooManyRequests"}}` | limit=5: 5×201 then 429s with retry-after-ms:1 + TooManyRequests envelope |
| 14 | Master-key `Authorization: type=master&ver=1.0&sig=…` shape validation | CONFORMANT (fenced, engine-level) | auth contract | `cosmos.ex` `authorize/4`: in `:enforce` auth_mode with `:smalt, :cosmos_master_key` set, parses the URL-encoded master form and verifies Base64(HMAC-SHA256(key, "verb\ntype\nlink\nx-ms-date\n\n")) via `Plug.Crypto.secure_compare`; mismatch → 401 `Unauthorized` envelope; anonymous mode + Bearer scheme + unset key all pass through untouched. Wire-level :enforce gate remains the Bearer plug (a master-key header is refused there before the engine) | engine-level probe: valid sig → 200, invalid sig → 401 `Unauthorized` |
| 15 | `x-ms-consistency-level` echo / `x-ms-date` request handling | CONFORMANT (fenced) | consistency/date headers | `cosmos.ex` `echo_consistency/2` echoes the request's `x-ms-consistency-level` into the response headers on every doc-surface response; x-ms-date consumed by the master-key string-to-sign | echo observed: request `Session` → response `x-ms-consistency-level: Session`; absent request header → no echo |
| 16 | 413 payload limit on doc create | CONFORMANT (fenced) | 413 RequestEntityTooLarge | `cosmos.ex` `do_create_doc/4`: payload > 2MB (real Cosmos limit) → 413 `{"code":"RequestEntityTooLarge"}` with the full required-header set; oversized doc not persisted | oversized POST → 413 envelope + required headers; subsequent GET → 404 |
| 17 | Doc-id grammar: 1-255 chars, no "/", string-typed → else 400 BadRequest (create) / 404 (replace path id) | CONFORMANT (fenced) | doc resource-id rules (same grammar class as db/container names) | `cosmos.ex valid_doc_id?/1` + `doc_id_check/1`; boundary 255 legal; nothing stored under poisoned keys | "a/b" / "" / 256-char / integer id → 400 envelope, wire tier 400 via real HTTP (c3 row, lens-2 cycle 3); module fences lens-2 cycles 1-2; mutation M4-killed (lens-2 cycle 6) |
| 19 | Create on an existing doc id → 409 Conflict, original untouched (real Cosmos; previously a silent 201-overwrite — lens-2 cycle 9, mutation M6-killed) | CONFORMANT (fenced) | create status contract | `cosmos.ex do_create_doc_sized` via atomic `Store.insert_new/3` (exists-check + insert in one GenServer call); 8-way duplicate-create race → exactly one 201 / seven 409 | direct module fences (409 + original `_etag` untouched) + 8-way race fence, 2026-10-15 |
| 18 | Query feed pagination: real Cosmos emits `x-ms-continuation` when a feed page is truncated; SDKs loop on it | CONFORMANT (fenced, lens-4 re-grade; was GAP until cosmos-lens3's authorized RAISE landed) | feed continuation | `cosmos.ex:557` parse_continuation (forged token 400, cosmos.ex:652-670), `cosmos.ex:590-604` ORDER-based cursor + token-rides-only-on-truncation, `@query_limit 100` | Lens-4 live probe (102-doc container): page 1 → `_count == 100` + `x-ms-continuation: 1#102:d100`; resume with the token → `_count == 2`, NO token on the last page. Fenced in c3 (continuation court: resume honored, forged 400, malformed 400, last page token-free); forged-token leg mutant KILLED (c3 23 tests, 1 failure on mutant) |

## Known-deviation notes

- Implicit-create on doc paths: `create_doc`/`list_docs`/`query_docs` against a
  db/container that was never created succeed (201/200) — real Cosmos answers
  404 NotFound. Pinned as a KNOWN DIVERGENCE by
  `cosmos_test.exs "name-corpus precedence"` (create 201 fence); flipping it to
  404 is a semantic pivot touching the implicit-create flow and needs
  coordinator sign-off, not a silent lane change. Delete/get precedence already
  matches real Cosmos (nonexistent/invalid name → 404, never a name-shape 400).
- `x-ms-request-charge` is the CONSTANT "1.0" on every doc surface — it is not
  computed from take/depth/op. Honest documented constant, fenced as such;
  real per-request RU arithmetic is UNKNOWN (no live Cosmos probe in lane).
- Rows 3/4 `_rid` grammar fixed: deterministic composite of
  `base64url(sha256(...))` segments — db rid 8 chars, container rid = db rid
  + 4, doc rid = container rid + 8 (base64url alphabet). Stored and served
  consistently by db/container/doc records and the query feed envelope; the
  `_self` name-path grammar is unchanged (row 3 remains exact-match fenced).
- `partitionKey.kind` moved into the engine (`cosmos.ex create_collection`);
  a direct engine consumer now gets `kind: "Hash"` without the router seam.

## Falsifier receipt

- Falsifier: exact replay is `mix test test/compliance/c3_cosmos.exs
  test/data_plane/cosmos_test.exs` → **61 tests, 0 failures** (2026-10-14).
- No egress_router.ex edits; engine (`cosmos.ex`) + fence suite only — the
  router seam already passes arbitrary `{:ok, status, headers, body}` tuples
  through `cosmos_respond/2`, so 429/401/413 needed no router change.
- The `partitionKey.kind` is now set at the ENGINE level
  (`cosmos.ex create_collection`); the router's `with_pk_kind` seam remains as
  a `put_new` backfill for pre-existing records only.
- `x-ms-consistency-level` echo (row 15) verified, not redone (via landing
  105).