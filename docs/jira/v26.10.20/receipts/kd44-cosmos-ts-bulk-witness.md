# KD-44 witness — cosmos TS bulk (K2 lane, 2026-2026-10-21)

**Standing:** ALIVE — fixed this lane; `KD-COVERS: KD-44` at
`lib/smalt/data_plane/cosmos.ex` bulk_operations/2.

## Defect (reproduced live, pre-fix)

```
$ curl -X POST .../docs -H 'x-ms-documentdb-partitionkey: ["a"]' -H 'x-ms-cosmos-is-batch: true' \
       -d '[{"operationType":"Upsert","partitionKey":"a","resourceBody":{"id":"b3","pk":"a","v":1}}]'
{"code":"BadRequest","message":"Partition key provided in the header doesn't match the partition key of the document."} [400]
```

The engine fed the per-op RAW-scalar pk ("a") straight into the pk header the
engine parses — `PartitionKey.parse("a")` fails (expects a JSON array), so the
real SDK bulk wire shape (pk in header + raw scalar in the op body) always 400'd.

## Fix (surgical, ~12 lines)

Wrap the per-op pk into the single-element JSON-array header shape, with the
same scalar normalization `PartitionKey.parse/1` applies (numbers/booleans via
`to_string/1`).

## Witness (in-process, real store, ephemeral boot — post-fix beam)

`MIX_BUILD_ROOT=_build-k2 mix test test/data_plane/cosmos_k2_rows_witness_test.exs`:

```
....
Finished in 0.07 seconds (0.00s async, 0.07s sync)
4 tests, 0 failures
```

The KD-44 test posts two real bulk Upsert ops with the SDK wire shape
(raw-scalar per-op `partitionKey`); both return statusCode 201. Note: the LIVE
substrate beam predates the fix — re-probe on next substrate recycle; the
falsifier "probes 16-17 re-run PASS" needs the TS SDK leg
(`SMALT_SDK_ROOT` currently absent per `just relay-env`, V261019-08) or a wire
re-probe post-recycle.
