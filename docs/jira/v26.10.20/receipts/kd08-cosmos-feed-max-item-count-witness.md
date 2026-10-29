# KD-08 witness — cosmos query feed max-item-count (K2 lane, 2026-10-21)

**Standing:** ALIVE — fixed this lane; `KD-COVERS: KD-08` at
`lib/smalt/data_plane/cosmos.ex` feed_limit/1 (wired at both feed take sites:
`do_list_docs/4` and `scan_query_docs/5`).

## Defect (reproduced live, pre-fix)

```
$ curl -X POST .../docs -H 'x-ms-max-item-count: 2' -H 'Content-Type: application/query+json' \
       -d '{"query":"SELECT * FROM c"}'
page1 count 7 ['m1','m2','m3','m4','m5','p2','u1']  — header ignored, one page, no continuation
```

## Fix

`feed_limit(headers)`: parse `x-ms-max-item-count`, valid 1..1000 caps the
page and a continuation token rides the response only while pages remain
(row-18 semantics preserved); absent/out-of-range falls back to the default
page size (Azure caps at 1000).

## Witness (in-process, real store, ephemeral boot — post-fix beam)

```
$ MIX_BUILD_ROOT=_build-k2 mix test test/data_plane/cosmos_k2_rows_witness_test.exs
4 tests, 0 failures
```

KD-08 tests: query feed with max-item-count=2 over 5 docs → page1 _count=2
with `x-ms-continuation`, resume returns the remaining 3, no overlap; list
feed same contract. Regression scope: `mix test test/data_plane/` → 52 tests,
1 failure (cosmos_sql_raise_test "unknown fn in projection" — PRE-EXISTING at
HEAD: `lib/smalt/cosmos_sql.ex` untouched by this lane). Live-substrate
re-probe needed after next substrate recycle (running beam predates fix).

## Verdict

PASS — post-fix beam: query feed honors max-item-count=2 with continuation; 4/4 witness tests green.
