# KD-09 witness — cosmos container list pagination (K2 lane, 2026-10-21)

**Standing:** ALIVE — fixed this lane; `KD-COVERS: KD-09` at
`lib/smalt/data_plane/cosmos.ex` list_collections/2.

## Defect

`list_collections/1` returned all containers in one page with no continuation
(151 containers in the original evidence); the pure paginator
`Smalt.DataPlane.CosmosFeeds.paginate_doc_set/3` (lane w6ai) existed in lib/
with ZERO consumers — the engine never wired it.

## Fix

`list_collections(db, headers \\ %{})`: sorts by id, honors
`x-ms-max-item-count` (1..1000), resumes from `x-ms-continuation`, echoes the
token only while pages remain; garbage/stale token → typed 400. Route
(`CosmosRoutes.get "/dbs/:db/colls"`) now passes `header_map(conn)`. Container
read route (`GET /dbs/:db/colls/:coll`) keeps calling `/1` (default-arg
compatible).

## Witness (in-process, real store, ephemeral boot — post-fix beam)

```
$ MIX_BUILD_ROOT=_build-k2 mix test test/data_plane/cosmos_k2_rows_witness_test.exs
4 tests, 0 failures
```

KD-09 test: 4 containers in the db, max-item-count=2 → page1 _count=2 with
continuation; resume pages disjoint ids; last page carries no token.
Close condition "paginate container feed, honor maxItemCount" met.
Live-substrate re-probe after next recycle (running beam predates fix).

## Verdict

PASS — post-fix beam: container feed paginates with continuation; 4/4 witness tests green.
