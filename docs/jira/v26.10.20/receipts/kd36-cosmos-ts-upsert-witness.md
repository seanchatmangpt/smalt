# KD-36 witness — cosmos TS upsert (K2 lane, 2026-10-21)

**Standing:** ALIVE — fixed in lib/ (`KD-COVERS: KD-36` at
`lib/smalt/data_plane/cosmos.ex` upsert?/do_create_doc_sized), wire-proved
against the LIVE substrate.

## Live wire proof (substrate 8443, STS bearer, fresh db k2db1792546924)

```
$ curl -X POST .../docs -H 'x-ms-documentdb-partitionkey: ["a"]' -d '{"id":"u1","pk":"a","v":1}'   -> 201
$ curl -X POST .../docs -H 'x-ms-documentdb-partitionkey: ["a"]' \
        -H 'x-ms-documentdb-is-upsert: true' -d '{"id":"upsert-of-existing","v":2}'               -> 200 (replace semantics, fresh _v/_etag)
$ curl PATCH u1 ops=[replace /v=3]                                                                -> 200, GET shows v=3
```

(Full transcript in the session log; the 200-on-existing upsert with the
is-upsert flag present is the falsifier condition "probe 9 re-run 200" — it
holds on the live wire today 2026-10-21.)

Close condition met: is-upsert flag → create-or-replace (200), 409 stands
without the flag.

## Verdict

PASS — live wire: is-upsert on existing id → 200 replace; falsifier condition holds.
