# KD-64 witness — cosmos Patch RFC 6902 (K2 lane, 2026-10-21)

**Standing:** ALIVE — PATCH route + RFC 6902 engine landed in lib/ (route at
`lib/smalt/egress/CosmosRoutes.ex` with `KD-COVERS: KD-64`; engine
`Cosmos.patch_doc/4` with `KD-COVERS: KD-64` in
`lib/smalt/data_plane/cosmos.ex`), wire-proved against the LIVE substrate.

## Live wire proof (substrate 8443, STS bearer, fresh db k2db1792546924)

```
$ curl -X POST .../docs -d '{"id":"p2","pk":"a","v":1}'
  -> pre  etag "dc34fecb4e9966dcc56…, _v 1

$ curl -X PATCH .../dbs/:db/colls/k2c/docs/p2 \
       -H 'Content-Type: application/json_patch+json' \
       -H 'x-ms-documentdb-partitionkey: ["a"]' \
       -d '[{"op":"replace","path":"/v","value":2}]'
  -> 200 post etag "ee4e8484d55ee42957a…, _v 2, v=2
```

Falsifier condition "item.patch replace → 200 new _etag, GET shows v=2"
holds: 200, fresh etag (dc34fecb… → ee4e8484…), _v 1→2, GET confirms.
Not a catch-all 404 — the route dispatches and the engine honors the ops
array.

## Verdict

PASS — live wire: PATCH → 200, fresh _etag, _v 1→2, GET confirms v=2. Not a catch-all 404.
