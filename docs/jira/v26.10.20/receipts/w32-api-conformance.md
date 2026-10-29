# W32 API-Conformance Audit (real-Azure REST spec vs smalt wire)

- **Standing:** PARTIAL_ALIVE
- Date: 2026-10-21
- Context: solo
- Method: live wire probes against the running substrate (never restarted; pid 9849,
  `just substrate-status` UP) with curl — 3+ representative transactions per leg
  captured verbatim (request shape + status + headers + body) into `/tmp/w32/capture.txt`,
  then checked against the official Azure REST API reference (learn.microsoft.com
  blob/queue storage REST, Cosmos NoSQL REST, Key Vault secrets 7.4, Service Bus ARM
  2021-04-01). Chicago-style: real transport, real outputs, no mocks.
- Scope: the 5 core legs — blob, cosmos/CAS, kv (Key Vault secrets), queue, sb-rules.
- Report-only: no lib edits, no git. New divergences are typed candidates for the
  registrar (KD rows), not minted rows.

## Per-leg conformance tables

### Leg 1 — blob storage

| # | Contract point | Official spec | smalt wire (observed) | Verdict |
|---|---|---|---|---|
| 1 | URL shape | `PUT https://{account}.blob.core.windows.net/{container}/{blob}` | `PUT /{account}/{container}/{blob}` on data plane, host-relative | MATCH (loopback host form) |
| 2 | Create container | `PUT /{c}?restype=container` → 201, empty body, ETag `0x…` | 201, empty body, `etag: "7DF1489EBAED675F2EA7DDBACE921B55"` | DIVERGE (etag format only) — NEW-candidate W32-1 |
| 3 | Put Blob (BlockBlob) 201 | 201, **empty body**, ETag `0x…` header | 201 + `content-type: application/json` + JSON body `{"content_length":9,"etag":…,"headers":{…},"last_modified":…,"name":…}` | DIVERGE — NEW-candidate W32-2 (non-spec JSON body on Put Blob) |
| 4 | Get Blob success | 200, body = blob bytes | 200, body = exact bytes | MATCH |
| 5 | Get Blob missing | 404 `BlobNotFound` | 404 `BlobNotFound` + `x-ms-error-code` | MATCH (code; envelope → row 8) |
| 6 | Ranged GET | 206 + `Content-MD5` when `x-ms-range-get-content-md5:true` | 206 + `content-md5: QinWkbB7EzQdpT8Xq58kFg==` | MATCH — KD-66 close verified live |
| 7 | Container re-create | 409 `ContainerAlreadyExists` | 409 | MATCH — KD-130 verified live |
| 8 | Storage error envelope | XML `<Error><Code>…</Code><Message>…</Message></Error>` | JSON `{"error":{"code":…,"message":…}}` | DIVERGE — KNOWN: `GAP(blob-error-envelope-json)` closed deliberately (v26.10.14 register cross-check; KD-04 registers residual token-name delta). Verified, not re-minted. **UPDATED 2026-10-21 (kd-registrar): blob-face storage errors now render XML + `x-ms-error-code` (KD-137/KD-139 landed; witness bkd-kd135-137-139-witness.md); the JSON-envelope DIVERGE above is historical to the original W32 run.** |
| 9 | WORM container overwrite | real Azure allows on default container | 409 `ContainerLocked` ("container policy enforces immutable WORM retention") | DIVERGE — KNOWN: KD-135, observed live, matches row exactly |
| 10 | Storage ETag format | `0x…` quoted hex (e.g. `"0x8DAB1C3…"`) | 64-char hex quoted (blob), uppercase hex quoted (container) | DIVERGE — NEW-candidate W32-3 |

### Leg 2 — cosmos / CAS

| # | Contract point | Official spec | smalt wire (observed) | Verdict |
|---|---|---|---|---|
| 1 | Create DB/coll | `POST /dbs`, `POST /dbs/{db}/colls` → 201 | 201, `_rid` 5/8-char chain, `_self`, `_ts` | MATCH |
| 2 | Doc create | `POST …/docs` with `x-ms-documentdb-partitionkey` header | 201; without the header → 400 "Partition key provided in the header doesn't match…" | MATCH (both faces) |
| 3 | Doc read echo | JSON doc + system props `_rid/_self/_ts/_etag` | doc + `_rid/_self/_ts/_etag` **plus `_gen`, `_v`** | DIVERGE (extra system props) — NEW-candidate W32-4 (minor) |
| 4 | `_etag` format | quoted GUID (`"00000000-0000-…"`) | quoted 64-char hex | DIVERGE — NEW-candidate W32-5 (minor; SDK-tolerated) |
| 5 | Session headers | `x-ms-request-charge`, `x-ms-session-token`, `x-ms-lsn`, `x-ms-alt-content-path` | all present, correct values | MATCH |
| 6 | Query feed envelope | `{"Documents":[…],"_count":n,"_rid":…}` | `{"Documents":[],"_count":0,"_rid":…}` | MATCH (KD-07 close verified live) |
| 7 | CAS happy path | PUT replace with `If-Match` current `_etag` → 200, new etag | 200, etag bumped, `_v` incremented | MATCH |
| 8 | CAS stale | PUT with `If-Match` stale/mismatched etag → 412 `PreconditionFailed` | 412, JSON `{"code":"PreconditionFailed",…}` — reproduced 4×, incl. GUID-format etag | MATCH |
| 9 | Error envelope | JSON `{"code","message"}` | JSON, same shape | MATCH |
| 10 | — | — | one transient `HTTP/1.0 500` empty-body/close during first stale-If-Match PUT at 16:52:28; **not reproducible in 4/4 subsequent identical attempts** | SUSPECT (transient crash-class response, no typed body; watch, no KD row on 1 sighting) |

### Leg 3 — kv (Key Vault secrets, 7.4)

| # | Contract point | Official spec | smalt wire (observed) | Heightened |
|---|---|---|---|---|
| 1 | Set secret create | `PUT /secrets/{name}?api-version=7.4` → **201** | **200** on first create | DIVERGE — NEW-candidate W32-6 |
| 2 | Secret id | `https://{vault}.vault.azure.net/secrets/{name}/{version-GUID}` | `https://127.0.0.1:8443/secrets/w32secret/76866` (loopback host, numeric version segment) | DIVERGE — NEW-candidate W32-7 |
| 3 | Get secret | 200, `{value, attributes{id…}}` | 200, `{"attributes":{"created":…,"enabled":true,"updated":…},"id":…,"value":…}` | MATCH (shape) |
| 4 | api-version validation | invalid/future api-version → 400 | `api-version=2099-01-01` accepted → 200 | DIVERGE — NEW-candidate W32-8 (exceeds the KD-78 monotonic-admission pin: 2099 is future, not ≤ latest) |
| 5 | Error envelope | JSON `{"error":{"code","message"}}` | JSON, same shape | MATCH |

### Leg 4 — queue storage

| # | Contract point | Official spec | smalt wire (observed) | Verdict |
|---|---|---|---|---|
| 1 | Create queue | `PUT /{q}?restype=queue` → 201 | 201 | MATCH |
| 2 | Put message | `POST /{q}/messages` XML `<QueueMessage><MessageText>` (base64) → 201 `<QueueMessagesList>` with MessageId/InsertionTime/ExpirationTime/PopReceipt/TimeNextVisible (RFC1123) | exact echo, all five elements + base64 PopReceipt `djI6…==` | MATCH |
| 3 | Get messages | 200 XML with DequeueCount + MessageText | exact, `DequeueCount:1`, `TimeNextVisible` advanced | MATCH |
| 4 | Delete message missing | 404 `MessageNotFound` | 404 `MessageNotFound` | MATCH (code; envelope → blob row 8, same JSON-vs-XML divergence applies) |
| 5 | `x-ms-request-id` | GUID | 16-hex non-GUID (`3b7b0404357a46c0`) on queue plane (blob plane emits real GUIDs) | DIVERGE — NEW-candidate W32-9 (minor) |

### Leg 5 — sb-rules (Service Bus ARM control plane)

| # | Contract point | Official spec (SB ARM 2021-04-01) | smalt wire (observed) | Verdict |
|---|---|---|---|---|
| 1 | Namespace PUT | requires `sku.name`; returns 200/201 (LRO) | requires `sku.name` (400 `InvalidResourceShape` without) → **202 Accepted** | MATCH (sku req) / DIVERGE minor (202 vs 200/201) — NEW-candidate W32-10 |
| 2 | Topic/subscription PUT | `location` NOT required for child resources | 400 `InvalidResourceShape` "may carry at most one location" when body omits `location` | DIVERGE — NEW-candidate W32-11 (GraphLaw gate rejects spec-valid bodies) |
| 3 | Rule PUT | `PUT …/rules/{r}` `{properties:{filterType:"SqlFilter", sqlFilter:{sqlExpression:…}}}` → 201 | 201 | MATCH (status) |
| 4 | Rule GET echo | echoes `sqlFilter.sqlExpression` | **filter NOT persisted — GET echoes `{"filter":{"trueFilter":true}}`** | DIVERGE — NEW-candidate W32-12 (highest-value: SQL filter silently dropped, real-Azure behavior break for filter-based subscriptions) |
| 5 | ARM api-version gate | invalid api-version → 400 `InvalidApiVersionParameter` naming latest supported | 400, same code + "latest supported … is '2021-04-01'" | MATCH |
| 6 | Parent-not-found | 404 `ResourceNotFound` | 404 `ResourceNotFound`, typed parent message | MATCH (but error `target`/`id` omits `providers/Microsoft.ServiceBus` segment) — minor, fold into W32-12 or separate W32-13 |

## Known-divergence verification (cited, not re-minted)

- KD-66 (ranged GET content-md5): CLOSED verified live — 206 + `content-md5` present.
- KD-130 (container re-create): CLOSED verified live — 409 on re-create.
- KD-135 (WORM delete/overwrite): OPEN verified live — 409 `ContainerLocked` exactly as rowed.
- JSON-vs-XML storage error envelope: registered via closed `GAP(blob-error-envelope-json)` (v26.10.14 register cross-check section); ~~smalt answers storage errors as JSON `{"error":{…}}`, deliberately.~~ **UPDATED 2026-10-21 (kd-registrar, premise-rot fix): the blob face now renders Azure StorageError XML with `x-ms-error-code` (KD-137/KD-139 shims in `lib/smalt/egress_router.ex`, witness `bkd-kd135-137-139-witness.md`); the JSON envelope note above is historical as-of the original W32 run.**
- KD-07 (cosmos feed envelope): CLOSED verified live — proper `{"Documents",_count}` envelope.

## New divergence candidates for the registrar (typed)

| id | surface | divergence | evidence |
|---|---|---|---|
| W32-1 | blob create-container | ETag format: uppercase/plain hex vs real-Azure `0x…` | capture `blob-create-container` |
| W32-2 | blob Put Blob | 201 response carries non-spec JSON body; real Azure: empty | capture `blob-put-blob2` |
| W32-3 | blob | storage ETag format hex vs `0x…` | capture `blob-put-blob2` |
| W32-4 | cosmos docs | extra system props `_gen`/`_v` in doc body | capture `cosmos-doc-create2` |
| W32-5 | cosmos docs | `_etag` 64-hex vs GUID format | capture `cosmos-doc-create2` |
| W32-6 | kv secrets | PUT create answers 200; real Azure 201 | capture `kv-secret-put` |
| W32-7 | kv secrets | secret `id` loopback host + numeric version segment vs `{vault}.vault.azure.net/…/{GUID}` | capture `kv-secret-get` |
| W32-8 | kv secrets | future `api-version=2099-01-01` accepted; real Azure 400 | capture `kv-secret-get-badapi` |
| W32-9 | queue | `x-ms-request-id` non-GUID on queue plane | capture `queue-put-msg` |
| W32-10 | sb namespaces | PUT → 202 vs real Azure 200/201 | capture `sb-ns-put2` |
| W32-11 | sb topics/subs | `location`-less valid body refused 400 `InvalidResourceShape` | capture `sb-topic-put` (reproduced 3×) |
| W32-12 | sb rules | SQL filter not persisted; GET echoes `trueFilter:true` | capture `sb-rule-put6`/`sb-rule-get5` |

## Receipt

Probes: ~30 live transactions across 5 legs, all captured verbatim in `/tmp/w32/capture.txt`
(request+response, headers+bodies). Machine context: not a bench lane, no
`just bench-machine` row (report-only audit; no ops/sec emitted). No lib edits; no git.
Substrate untouched (`just substrate-status`: UP pid 9849 throughout).

**Standing:** **PARTIAL_ALIVE** — wire observed and receipted; the 12 typed candidates above
await registrar rows; W32-12 (SB rule filter drop) is the highest-value fix target.

## RE-WITNESS addendum — 2026-10-22 (lane BK-REWIT3): live wire re-probe; 8 of 12 candidates CLOSED by later lanes

Re-ran representative contract points against the running substrate (STS
bearer minted via `POST /dev/oauth2/v2.0/token`; data plane http://127.0.0.1:8443,
ARM http://127.0.0.1:9443). Original evidence above untouched. Real output:

```
kv  PUT /secrets/w32rewit3?api-version=7.4            -> 201            (W32-6 CLOSED: spec 201)
kv  GET /secrets/w32rewit3?api-version=2099-01-01     -> 400            (W32-8 CLOSED: future api-version refused)
blob PUT container (x-ms-version: 2021-12-02)          -> 201
blob PUT block blob                                    -> 201, EMPTY body,
     etag: "0x5D41402ABC4B2A76", x-ms-request-server-encrypted: true     (W32-2 + W32-3 CLOSED)
cosmos POST doc                                        -> doc body = _etag/_rid/_self/_ts + user
     data only; _etag quoted GUID "f1e8dc98-8e05-…"                      (W32-4 + W32-5 CLOSED)
sb   PUT namespace                                     -> 202            (W32-10 STILL OPEN)
sb   PUT topic/subscriptions, location-less body       -> 201            (W32-11 CLOSED)
sb   PUT rule {SqlFilter, "n = 1"}                     -> 201; GET echoes
     "sqlFilter":{"sqlExpression":"n = 1"}             (W32-12 CLOSED: filter persisted)
sb   PUT rule unsupported construct ("sent = TRUE")    -> 400 InvalidFilter (typed, not silent)
```

Not re-probed this pass (row stays as-of-2026-10-21): W32-1 (container etag
format — blob-face etag observed 0x format above, container face untested),
W32-7 (secret id host form), W32-9 (queue x-ms-request-id). SUSPECT cleared:
the receipt carries fresh command-embedded wire evidence (exit=0 curl class,
status codes above). Registrar note: W32-2/3/4/5/6/8/11/12 candidates are
OBSOLETE (divergences closed); W32-10 remains a live candidate.

## SUPERSEDE addendum — 2026-10-22 (lane BK-SUPW): W32-10 CLOSED-NOT-A-DIVERGENCE

W32-10 (SB namespace PUT 202) is **CLOSED-NOT-A-DIVERGENCE** — the 202 carries the
full Azure-AsyncOperation LRO face, real-Azure parity; no KD id was minted.
See `docs/jira/v26.10.22/receipts/bkw3210-ns202.md`. All 12 candidates in this
receipt are now closed/obsolete; "W32-10 STILL OPEN" and "live candidate" above
are superseded as of this addendum.
