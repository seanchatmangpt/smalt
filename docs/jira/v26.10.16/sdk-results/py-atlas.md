# PY-ATLAS — Purview Atlas v2 REST probes (python requests)

- **Subject**: `/Users/sac/smalt` (MIX_ENV=test, lane-private substrate) on
  `http://127.0.0.1:39323`, lane port block 39320-39324.
- **Client**: python `requests 2.34.2`, venv `test/sdk-python/.venv-eh`.
- **Harness**: `test/sdk-python/py_atlas.py` (16 checks) +
  `test/sdk-python/run_atlas.sh` (lane runner, exclusive flock with lock fd
  closed on the substrate spawn).
- **Run**: 2026-10-16. **Result: 16/16 probe checks PASS.**

## Embedded command output

```
PASS create_entity: server-assigned guid 201 :: status=201 code=None msg=None
PASS create_entity: client-supplied guid preserved :: status=201 code=None msg=None
PASS bulk: 3 entities -> 201 with guidAssignments + mutatedEntities :: status=201 code=None msg=None
PASS bulk: mutatedEntities.CREATE lists all 3 :: status=201 code=None msg=None
PASS get_entity: round-trip (KD-41) (typeName + attributes echo) :: status=200 code=None msg=None
PASS relationship: 201 with guid+id echo :: status=201 code=None msg=None
PASS lineage output: cyclic graph returns all 3 edges :: status=200 code=None msg=None rels=3
PASS lineage input: sink sees all upstream edges :: status=200 code=None msg=None
PASS lineage both: includes back-edge (sink->src) :: status=200 code=None msg=None
PASS lineage both: baseEntityGuid echoes guid (KD-41) :: status=200 code=None msg=None
PASS refusal: non-map entity -> 400 ATLAS-400-00-001 (entity body required)
PASS refusal: bulk 101 entities -> 400 ATLAS-400-00-001 (bulk is limited to 100 entities, got 101)
PASS refusal: unknown guid -> 404 ATLAS-404-00-005 (entity <guid> not found)
PASS refusal: relationship missing end guids -> 400 ATLAS-400-00-001 (relationship requires end1/end2 guids)
PASS refusal: bad direction -> 400 ATLAS-400-00-001 (direction must be one of input, output, both)
PASS refusal: lineage unknown guid -> 200 empty relations
TOTAL: 16/16 passed
```

## Passing surface (receipt)

| Area | Evidence |
|---|---|
| create_entity (single) | 201; server-assigned GUID; client-supplied GUID preserved |
| entity/bulk (atomic) | 201 `guidAssignments` + `mutatedEntities.CREATE` for 3 entities; 101 entities -> typed 400 `ATLAS-400-00-001` (limit 100), no partial insert |
| get_entity | 200 round-trip (typeName echo); unknown guid -> typed 404 `ATLAS-404-00-005` |
| relationship | 201 with `guid`+`id` echo (end1/end2 wire shape); missing end guids -> typed 400 |
| lineage | BFS over a real 3-node cyclic graph: `output` from src, `input` into sink, `both` incl. the back-edge — all 200 with full edge set; bad direction -> typed 400; unknown guid -> 200 empty relations |

## Standing

ALIVE (16/16 PASS, exit 0, lane runner exit 0). Zero failures, zero skips.
KD-41 (purview-atlas / no py probe cell) is witnessed by this receipt: the
coverage cell is PASS via REST probes; the row flip goes through
`scripts/kd_flip.py --apply`, gated on this receipt's mtime postdating the
probe file mtime — not claimed here.
