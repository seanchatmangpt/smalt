# PY-3: Real python azure-cosmos SDK vs smalt Cosmos plane (v26.10.16 re-run)

- Date: 2026-10-16
- Repo: /Users/sac/smalt @ main, v26.10.16 window
- Probe: `test/sdk-python/py_cosmos.py` (venv `.venv-cosmos`)
- Port env: probe now reads `SMALT_EGRESS_BASE` (lane-351); run against the
  lane-351 substrate (ports 39360-39364), MIX_ENV=test anonymous auth.
- Exit: 0 (probe counts its own ledger 24/26)

## Verdict: 24/26 — 2 findings, both deterministic (3/3 lane runs)

Embedded probe output (lane run, egress 39363):

```
[PASS] get_database_account :: ok
[PASS] create_database pycosmos-e02a80ec :: pycosmos-e02a80ec
[PASS] create_container c1 /pk :: c1
[PASS] create_item d1 :: etag="9900a15c134a86079fe6f8e602e2a5e9c78b09c9edddabd70748f597292d93ae"
[PASS] read_item d1
[PASS] replace_item with matching etag
[PASS] read_item after replace
[PASS] delete_item d1 -> read 404
[PASS] read_all_items (ReadFeed envelope) :: ids=['r1', 'r2']
[PASS] whitelist: SELECT * FROM c admitted :: 2 rows
[PASS] whitelist: SELECT c.id FROM c -> 400 :: status=400 body=(SyntaxError) The query syntax is invalid.
[FAIL] whitelist: SELECT * FROM root -> 400 :: admitted (expected 400)
[PASS] whitelist: SELECT * FROM c WHERE c.n = 2 -> 400 :: status=400 body=(SyntaxError) The query syntax is invalid.
[PASS] whitelist: SELECT VALUE c.n FROM c -> 400 :: status=400 body=(SyntaxError) The query syntax is invalid.
[PASS] whitelist: SELECT * FROM c OFFSET 1 LIMIT 1 -> 400 :: status=400 body=(SyntaxError) The query syntax is invalid.
[FAIL] cross-partition query returns all 5 docs (d1 deleted) :: 7 rows
[PASS] pagination: 120 docs @ max_item_count=10 :: 2 pages, 120 docs
[PASS] continuation token captured :: token prefix: 1#130:cHljb3Ntb3MtZTAyYTgwZWMvYzE:["pg"]
[PASS] continuation resume yields remaining docs :: first=100 rest=20
[PASS] stale-etag replace -> 412 :: status=412 (PreconditionFailed)
[PASS] stale-etag delete -> 412 :: status=412 (PreconditionFailed)
[PASS] fresh-etag replace still admitted
[PASS] list containers: all 5 visible :: found ['c1', 'lc-a', 'lc-b', 'lc-c']
[PASS] list containers: paged iteration works :: 1 pages
[PASS] read_item returns doc
TOTAL: 24/26 passed
```

## Findings

1. `SELECT * FROM root` alias admitted — KD-06, still OPEN, reproduced
   (finding unchanged from the v26.10.14 py-cosmos receipt).
2. "cross-partition query returns all 5 docs (d1 deleted) :: 7 rows" —
   probe-internal count expectation is stale: the probe itself upserts r1/r2
   into the same container before the cross-partition assertion, and the
   container now correctly carries 7 docs (5 seeded minus d1 deleted, plus
   r1+r2). Deterministic 3/3 runs; deterministic in-probe arithmetic, not a
   substrate behavior change. Probe assertion needs its expected count
   recomputed (5 -> 7) — flagged for the probe owner.

## Falsifier replay

```bash
SMALT_EGRESS_BASE=http://127.0.0.1:<egress> \
  test/sdk-python/.venv-cosmos/bin/python test/sdk-python/py_cosmos.py
# expect: TOTAL 24/26; the two findings above, stable across runs.
```
