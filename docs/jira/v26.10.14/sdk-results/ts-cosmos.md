# TS-3: Real TypeScript @azure/cosmos SDK court vs smalt Cosmos NoSQL plane

- Date: 2026-10-15 (runs 23:02Z–00:57Z+)
- Repo: /Users/sac/smalt @ main (3fc2543), v26.10.14, MIX_ENV=test substrate
- Lane: TS-3 (SDK lane fan-out)
- Probe: `test/sdk-full/cosmos.probe.mjs` (in-repo; NOT wired into ts-run.mjs suite —
  standalone node script per coordinator course-correction)
- Boot: same shape as `test/sdk-full/ts-run.mjs` (MIX_ENV=test, `mix run --no-start
  --no-halt -e` with arm/egress/amqp/eh/tls ports pinned 9443/8443/5672/5673/9444,
  dev TLS material from .smalt/tls), under exclusive `flock /tmp/smalt-substrate.lock`.
  Boot+test window ~4s; lock contention from sibling lanes caused multi-queue waits
  (up to ~20 min) — recorded, not budgeted.
- SDK: @azure/cosmos 4.10.1 (npm install in test/sdk-full; package.json not committed)
- Endpoint: http://127.0.0.1:8443 (egress Cosmos NoSQL plane), master key = random
  64-char hex (substrate runs auth_mode :anonymous; key is wire-present but not
  verified — same honest wiring as test/sdk-smoke/cosmos.test.cjs)

## Verdict: 17/20 PASS, 3 DIVERGENCES (exit 1, fail-closed)

| # | Probe | Verdict | Evidence |
|---|---|---|---|
| 1 | databases.createIfNotExists | PASS | 201; db ts3db-<ts> |
| 2 | containers.createIfNotExists (partitionKey /pk) | PASS | 201 |
| 3 | items.create | PASS | 201, 64-hex `_etag` |
| 4 | item.read round-trip (multibyte `héllo 🌊`) | PASS | 200, value byte-identical |
| 5 | items.replace unconditional | PASS | 200, fresh etag |
| 6 | replace with IfMatch current etag | PASS | 200 |
| 7 | replace with STALE etag | PASS | 412 `{"code":"PreconditionFailed","message":"The condition specified using HTTP conditional header(s) is not met."}` |
| 8 | delete with STALE etag | PASS | 412, same envelope |
| 9 | items.upsert EXISTING id | **DIVERGENCE** | 409 `{"code":"Conflict","message":"Entity with the specified id already exists in the system."}` — real Cosmos upserts (200 replaced); smalt treats upsert-of-existing as create-conflict. Reproduced 4/4 runs. |
| 10 | items.upsert NEW id | PASS | 201 (correct create leg) |
| 11 | item.delete bare | PASS | 204 |
| 12 | query `SELECT * FROM c` (whitelist-admitted) | PASS | 200, 1 doc, requestCharge=1 |
| 13 | query `SELECT * FROM c WHERE c.pk = 'p1'` (refused) | PASS | 400 `{"code":"SyntaxError","message":"The query syntax is invalid."}` — exact refusal envelope; SDK raises code 400 |
| 14 | partition-scoped query (`query(sql, {partitionKey})`) | PASS | 200, only pk=p1 docs returned |
| 15 | seed 120 docs sequential create | PASS | 120/120 in 48ms |
| 16 | items.bulk, 3 ops, single partition | **DIVERGENCE** | SDK-side wrap "Bulk request errored with: Partition key provided in the header doesn't match the partition key of the document." Server 400. Reproduced across all runs (150-op single-partition chunks AND 3-op minimal batch). Real Cosmos bulk sets the pk header from each op's document; smalt's bulk path rejects the header-vs-doc pk match the SDK actually sends. |
| 17 | items.bulk, 3 ops, cross-partition | **DIVERGENCE** | Same 400 pk-mismatch. |
| 18 | pagination: query maxItemCount=25 over 121 docs | PASS | 2 pages, 121 docs total, real continuation token (`1#125:dHMzZGIt...:seq`) honored across `.fetchNext()` |
| 19 | databases.readAll listing | PASS | all 4 databases returned |
| 20 | containers.readAll listing | PASS | c1 returned |

## SQL whitelist gate (newly landed)

- Admitted: `SELECT * FROM c` — 200, feed with results, requestCharge surfaced.
- Refused: `SELECT * FROM c WHERE c.pk = 'p1'` — HTTP 400 with body
  `{"code":"SyntaxError","message":"The query syntax is invalid."}`; @azure/cosmos
  raises a 400 error carrying that body verbatim. Envelope matches the Cosmos
  syntax-error shape.

## Divergence detail (fail-closed, reproduced)

1. **upsert-of-existing returns 409 Conflict** (expected 200 replace). Wire shape:
   upsert is POST with `x-ms-documentdb-is-upsert: true`; smalt ignores the upsert
   flag and applies create semantics. 4/4 runs.
  - Note: `container.items.bulk` fails independently (below) so upsert-via-bulk is
     double-blocked.
2. **items.bulk always 400** "Partition key provided in the header doesn't match the
   partition key of the document" — single-partition batches of 150 chunked to 50 and
   minimal 3-op batches, single and cross partition, 3/3 runs that exercised it.
   SDK sends pk in both `x-ms-documentdb-partitionkey` header and body; smalt's bulk
   handler rejects the SDK's actual wire shape.

## Probe-script (lane-local) notes, not subject defects

- @azure/cosmos v4 ignores `{ifMatchETag}`; `accessCondition: {type:"IfMatch"}` is
  the SDK-correct precondition form (matches smoke test note).
- QueryIterator v4: `.fetchNext()` per page; `.getQueryIterator`/`nextToken` don't exist.

## Falsifier / replay

```
cd /Users/sac/smalt/test/sdk-full && npm install @azure/cosmos --no-audit --no-fund
flock -x /tmp/smalt-substrate.lock -c 'bash /tmp/ts3-run.sh'   # boot + probe + kill (lock released)
# or directly once substrate is up on 8443:
cd /Users/sac/smalt/test/sdk-full && node cosmos.probe.mjs
```

Receipt lines live in /tmp/ts3-probe-out.log (ephemeral); the probe itself is the
durable replay key (`test/sdk-full/cosmos.probe.mjs`).

Standing: PARTIAL_ALIVE — CRUD/etag/precondition/query-whitelist/partition-scope/
continuation-pagination/listing surfaces are SDK-real ALIVE; upsert-existing and the
entire bulk surface are REFUTED with wire evidence.
