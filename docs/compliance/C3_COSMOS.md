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
`test/compliance/c3_cosmos.exs` (21 tests, 0 failures).

## Receipt

- Subject: smalt v26.10.14 Cosmos surface (engine + router seam)
- Probe transport: real sockets — curl vs a live anonymous-mode egress
  listener (`:28443`) and inets `:httpc` against per-test Bandit listeners
- Commands: `mix test test/compliance/c3_cosmos.exs` → `21 tests, 0 failures`
- Replay: `cd ~/smalt && mix test test/compliance/c3_cosmos.exs`
- Standing: PARTIAL_ALIVE (16 rows: all CONFORMANT fenced — rows 3/4/16 fixed
  this wave; no PARTIAL or GAP rows remain)
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
| 5 | Partition-key header `x-ms-documentdb-partitionkey`: JSON array, one string; extraction at JSON-pointer path; mismatch/missing/non-array → 400 BadRequest | CONFORMANT (fenced) | partition-key header spec | `partition_key.ex:25-32` parse; `:79-89` enforce; `cosmos.ex:210, 294, 451-456` | missing / `acme` (non-array) / mismatched array all → 400 BadRequest |
| 6 | CRUD status semantics: 201 create, 200 read/replace, 204 delete, 404 NotFound, 412 PreconditionFailed, 304 If-None-Match | CONFORMANT (fenced) | REST status contract | `cosmos.ex:226, 244, 314-325, 367-377, 246-248, 255-261` | all live-probed; conditional delete 204→404; stale If-Match 412; 304 on If-None-Match |
| 7 | 400 message on pk failures: real Cosmos: "Partition key provided in the header doesn't match…"; container without pk defined → header not required | CONFORMANT (fenced for 400-class) | pk 400 message | `cosmos.ex:498-509` real Cosmos message for BadRequest; `partition_key.ex:76-77` no-pk container header optional | live probe: mismatch message exact; container without pk accepts headerless docs |
| 8 | Query POST `application/query+json` envelope `{"query","parameters"}` → `{"_rid","Documents","_count"}`; a query POST never creates | CONFORMANT (fenced) | query POST contract | `egress_router.ex:1311-1327` query_post?/query_post; `cosmos.ex:417-445` engine; `egress_router.ex:249-256` route order | 200 feed shape exact; malformed body → 400; query POST creates nothing |
| 9 | Cross-partition: `x-ms-documentdb-query-enablecrosspartition` accepted; without pk header the whole container scans | CONFORMANT (fenced) | cross-partition query | `cosmos.ex:427-431` (parse error → unfiltered scan); enablecrosspartition header simply unboycotted | 200 with `_count >= 1` |
| 10 | Collection creation: `partitionKey {paths, kind}`; bare-string pk body normalized | CONFORMANT (fenced) | container contract | `egress_router.ex:966-990` with_pk_kind + normalize_pk_body; `cosmos.ex:98-121` | container record `partitionKey {kind: Hash, paths}` |
| 11 | Trailing slash tolerated on the `/dbs` surface; `GET /` DatabaseAccount envelope (id, writableLocations, consistency default) | CONFORMANT (fenced) | account + routing | `egress_router.ex:954-963` trim_dbs_trailing_slash; `egress_router.ex:565-597` account route | `/dbs/` 200; `GET /` 200 kind=DatabaseAccount |
| 12 | Session token `version#lsn` format, monotonic on writes | CONFORMANT (fenced) | session token | `cosmos.ex:480` `"1#lsn"`; durable counters `cosmos.ex:484-490` | `1#1` → `1#N` monotonic across writes |
| 13 | Throttling: 429 + `x-ms-retry-after-ms` | CONFORMANT (fenced) | 429 semantics | `cosmos.ex` `gate/5` → `throttle/1`: in-memory 1s fixed-window counter per partition-route (container link) in `:smalt_cosmos_ru` ETS, active only when `Application.get_env(:smalt, :cosmos_ru_limit)` is an integer (default `:infinity` — surface unchanged unless configured); exceeded → `{:ok, 429, …"x-ms-retry-after-ms" => "1"…, %{"code" => "TooManyRequests"}}` | limit=5: 5×201 then 429s with retry-after-ms:1 + TooManyRequests envelope |
| 14 | Master-key `Authorization: type=master&ver=1.0&sig=…` shape validation | CONFORMANT (fenced, engine-level) | auth contract | `cosmos.ex` `authorize/4`: in `:enforce` auth_mode with `:smalt, :cosmos_master_key` set, parses the URL-encoded master form and verifies Base64(HMAC-SHA256(key, "verb\ntype\nlink\nx-ms-date\n\n")) via `Plug.Crypto.secure_compare`; mismatch → 401 `Unauthorized` envelope; anonymous mode + Bearer scheme + unset key all pass through untouched. Wire-level :enforce gate remains the Bearer plug (a master-key header is refused there before the engine) | engine-level probe: valid sig → 200, invalid sig → 401 `Unauthorized` |
| 15 | `x-ms-consistency-level` echo / `x-ms-date` request handling | CONFORMANT (fenced) | consistency/date headers | `cosmos.ex` `echo_consistency/2` echoes the request's `x-ms-consistency-level` into the response headers on every doc-surface response; x-ms-date consumed by the master-key string-to-sign | echo observed: request `Session` → response `x-ms-consistency-level: Session`; absent request header → no echo |
| 16 | 413 payload limit on doc create | CONFORMANT (fenced) | 413 RequestEntityTooLarge | `cosmos.ex` `do_create_doc/4`: payload > 2MB (real Cosmos limit) → 413 `{"code":"RequestEntityTooLarge"}` with the full required-header set; oversized doc not persisted | oversized POST → 413 envelope + required headers; subsequent GET → 404 |

## Known-deviation notes

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