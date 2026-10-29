# SQLD-3 — SQLite Ingestion Court (duckdb sqlite_scanner, real CLIs)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · Lane: SQLD-3 · Milestone: v26.10.21

## Subject

- Court: `/Users/sac/smalt/test/integration/sqlite_ingestion_court.py`
- Artifacts: `/Users/sac/smalt/tmp/sqlite_court/` (`events.db`, `projection_ast.ttl`,
  `ocel_events.csv`, `ocel_objects.csv`, `ocel_relationships.csv`)

## Toolchain (typed availability check)

- `/usr/bin/sqlite3` 3.51.0 (2025-06-12) — db generation via CLI stdin script.
- `/opt/homebrew/bin/duckdb` CLI v1.4.1 (Andium) b390a7c376.
- Extension: `duckdb_extensions()` row `sqlite_scanner,installed=true,loaded=false`
  (install_mode REPOSITORY); `LOAD sqlite_scanner` succeeds. The extension name is
  `sqlite_scanner`, NOT `sqlite` (a query for `extension_name='sqlite'` returns
  0 rows — recorded so no future lane reads that as "absent").
- python3 `duckdb` module: absent (not needed; CLI used throughout).
- Typed SKIP path implemented (exit 3) if the extension is uninstalled.

## Corpus

Deterministic LCG (seed 20261021), fixed schema `objects(object_id, object_type, site)`
+ `events(event_id, ts, activity, object_id, temp, duration)`:
60 objects (freezer/conveyor/pallet × S1/S2), 900 events. Byte digest of the
generated db: `sha256(f95d1e78b9ba…)` stable across runs.

## Pipeline

`sqlite3` CLI generates `events.db` → duckdb `LOAD sqlite_scanner; ATTACH … (TYPE sqlite)`
→ `COPY` to OCEL v2 CSVs (events with attribute columns temp/duration, objects,
relationships with `performed_on` qualifier) → SHACL-shaped gate on the projection
AST TTL → parity queries compiled FROM the AST.

## Court result (two consecutive runs, identical — deterministic)

```
row counts exact: events=900 objects=60 rels=900
query parity (sqlite3 CLI vs duckdb-over-attach): EXACT
conveyor|299|142536|37.9|6.9385
freezer|307|140914|37.5|9.6951
pallet|294|144723|37.9|7.5531
OCEL projection parity (aggregate from projected CSVs == source): EXACT
SHACL gate on projected AST: PASS; AST-compiled parity query: EXACT
COURT RESULT: PASS
audit_hash: 115e9f232a10bfd8a41ef74f20764293cccfbf88cfc051e407be6ea663adae45
```

Exit 0 both runs; identical audit_hash (aggregate rows + projected events CSV).

## Court legs

1. **Row counts exact, three engines**: sqlite3 over the .db, duckdb over the
   sqlite ATTACH, and the OCEL CSV projection all agree (900/60/900), plus
   relationship-shape assert (`qualifier == 'performed_on'` on every row).
2. **Query parity**: per-object_type `COUNT/SUM(duration)/MAX(temp)/ROUND(AVG(temp),4)`
   byte-identical from the sqlite3 CLI and duckdb-over-attach.
3. **Projection parity**: the same aggregate recomputed from the projected
   OCEL CSVs (`read_csv_auto`) equals the source aggregate — the projection is
   lossless for the court's measures.
4. **SHACL gate + AST-compiled query**: required properties present, identifier
   regex `^[a-zA-Z_][a-zA-Z0-9_.]*$` on every declared table/column/key, exactly
   one `ocel:Projection` node, corpus cardinality pinned; the parity query is
   then compiled from the AST's `sql:eventsTable/objectsTable/joinColumn` and
   reproduces the source aggregate exactly.

## Defects found and fixed during the run (honest record)

- Generator stored whole object tuples as event FKs (sqlite parse error) — fixed
  to `obj[0]`.
- Extension probe asserted `loaded` instead of `installed` — fixed; both legs typed.
- duckdb CSV normalization sliced off `object_type` (assumed a phantom label
  column) — fixed.
- OCEL event projection initially omitted `temp`/`duration` attribute columns —
  added (OCEL v2 event attributes).
- SHACL `sql:tables` regex only matched the first element of the RDF list —
  fixed to parse the full object list.

## Machine

macOS 26.2 (25C56), arm64 (Apple Silicon); python3 3.x homebrew; sqlite3 3.51.0;
duckdb v1.4.1 (Andium). This is a court, not a bench lane — no jsonl emitted;
`just bench-machine` not invoked.
