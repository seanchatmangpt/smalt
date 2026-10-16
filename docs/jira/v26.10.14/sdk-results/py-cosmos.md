# PY-3 — Real python azure-cosmos SDK vs smalt Cosmos plane

- **Subject**: `/Users/sac/smalt` v26.10.14, live substrate (MIX_ENV=test, anonymous
  auth) on `http://127.0.0.1:8443`, ports 9443/8443/5672.
- **SDK**: `azure-cosmos 4.17.1` on CPython 3.14, venv
  `test/sdk-python/.venv-cosmos`.
- **Harness**: `test/sdk-python/py_cosmos.py` (25 checks),
  `test/sdk-python/py_headers.py` (header dump + container-list continuation probe).
- **Run**: 2026-10-15. **Result: 24/25 probe checks PASS; 4 divergences filed below.**

## Substrate lifecycle note

`/tmp/smalt-substrate.lock` was already HELD by another lane at start (flock
holders pids 62050/66273) with the substrate live on exactly our pinned ports.
Per no-destructive-conflict law the live substrate was REUSED, not killed: this
lane does not own the lock and left the substrate and lock untouched at exit.

## Passing surface (receipt)

| Area | Evidence |
|---|---|
| `get_database_account` (GET /) | 200, python `Documents.DatabaseAccount` shape accepted |
| DB + container create | 201; partition key `/pk` accepted |
| create/read/replace/delete item | round-trip incl. `_etag` echo; read-after-delete 404 |
| Query whitelist | `SELECT * FROM c` admitted; `SELECT c.id FROM c`, `WHERE`, `VALUE`, `OFFSET/LIMIT`, junk ` CosmosDB` all -> 400 `(SyntaxError) The query syntax is invalid.` |
| Cross-partition query | `enable_cross_partition_query=True` returned all 5 docs in one call |
| Pagination | 120 docs, `by_page()` → 2 pages; continuation token captured (`1#128:<base64>:[["pk"]]` format) and resume from mid-stream token returned exactly the remaining docs |
| Stale etag | replace + delete with stale etag → 412 `PreconditionFailed`; fresh etag admitted (`etag=` requires `match_condition=MatchConditions.IfNotModified` in SDK 4.x) |

## Divergences (status + body evidence)

1. **`SELECT * FROM root` ADMITTED** (expected 400 under the stated whitelist).
   The gate admits the `root` alias in addition to `c`. All other non-`SELECT
   *` forms refused with 400 SyntaxError. Either the whitelist should pin the
   alias set or the lane brief overstated "only `SELECT * FROM c`".
   ```
   status=200; rows returned (expected 400 SyntaxError)
   ```
2. **Non-query document ReadFeed shape breaks the python SDK**:
   `container.read_all_items()` (GET `/dbs/{db}/colls/{c}/docs`, no query)
   raises `TypeError: list indices must be integers or slices, not str` at
   `_cosmos_client_connection.py:1224` — SDK expects
   `{"Documents": [...], "_count": n}` envelope; substrate answers a bare JSON
   array for the non-query read feed. The query feed (POST with
   `x-ms-documentdb-query`) returns the correct envelope, and single
   `read_item` works — only the ReadFeed path diverges.
3. **`x-ms-max-item-count` not honored on query feed**: requested
   `max_item_count=10`; first page returned 100 docs (server default cap).
   Continuation itself is correct (all 120 docs across pages, token resumable).
4. **Container-list continuation absent**: `GET /dbs/{db}/colls` with 151
   containers returns all in ONE page, no continuation token issued
   (`StopIteration` on token scan). Real Cosmos paginates container feeds and
   honors maxItemCount; a python client listing a large database cannot
   resume. Header evidence: account GET / emits only `content-type`, `date`,
   `x-ms-request-charge: 1.0` — no `x-ms-version`/`x-ms-request-id` echo, but
   the python SDK does not require them for this route.

## No header-compat failures otherwise

azure-cosmos 4.17.1 (strict response-header validation) completed DB
create/read/list, container create/list/query, item CRUD, queries,
continuation paging, and conditional (etag) writes with zero header-shape
errors beyond divergences 2-4 above.

## Repro

```bash
/Users/sac/smalt/test/sdk-python/.venv-cosmos/bin/python \
  /Users/sac/smalt/test/sdk-python/py_cosmos.py     # 24/25 (root-alias check pins divergence 1)
/Users/sac/smalt/test/sdk-python/.venv-cosmos/bin/python \
  /Users/sac/smalt/test/sdk-python/py_headers.py    # divergences 2-4
```

Standing: ALIVE for the exercised surface (CRUD, whitelist-gate query,
cross-partition, doc-feed continuation, conditional etag writes);
PARTIAL with 4 filed divergences (root alias, ReadFeed envelope,
max-item-count, container-list continuation).
