# SQLD-5: auto-shape generation for SQL ingestion (SqlShapeGen)

Date: 2026-10-21
Lane: SQLD-5 (writer, OTP-29), MIX_BUILD_ROOT=_build-sqld5
Repo: /Users/sac/smalt (canonical checkout)

## Standing
**Standing:** ALIVE

**ALIVE** — module compiles, court green 14/14 on the exact subject.

## Module

`lib/smalt/graphlaw/sql_shape_gen.ex` — `Smalt.GraphLaw.SqlShapeGen`

* `generate/1`: projected relational schema (duckdb `DESCRIBE` shape:
  table / columns{name, type, null, pk}) -> SHACL Turtle in exactly the
  grammar `Smalt.GraphLaw.Validator.ShapeFile` parses (the GL-2 law
  compiler's grammar).
* Type map: INTEGER family -> `xsd:integer`, VARCHAR/TEXT family ->
  `xsd:string`, BOOLEAN family -> `xsd:boolean`. NOT NULL columns emit
  `sh:minCount 1`; nullable columns emit no minCount (KD-156 SHACL
  semantics). PK columns carry the identifier-pattern `sh:message`.
  Unmappable types (DOUBLE, DECIMAL, TIMESTAMP, BLOB, ...) are a typed
  `ArgumentError` — never silent widening to string.
* `parse/1`: round-trips through the substrate's own
  `ShapeFile.parse!/2`, so generated governance cannot drift from the
  compiled admission gate.

Adjacency note: SQLD-4 (mapping.ex) coordination — no shared file
touched; this lane owns only `sql_shape_gen.ex` +
`sqld5_sql_shape_court.exs`.

## Courts

`test/integration/sqld5_sql_shape_court.exs` — 3-table schema
(customers/orders/order_items), generated shapes parsed by the
substrate parser:

* generation: one NodeShape per table; datatype mapping per column
  family; minCount 1 exactly on NOT NULL columns; PK identifier message;
  byte-identical determinism; unsupported SQL type and malformed table
  spec each raise typed ArgumentError.
* governance (the closed loop — generated shapes govern ingested rows
  via `Validator.validate_shape/2`): conforming rows PASS; NULL in a
  NOT NULL column refuses (minCount); string in an int column refuses
  (datatype); int in a boolean column refuses (datatype); an unknown
  column refuses (closed shape — schema drift is an admission failure);
  each of the 3 tables' shapes governs its own rows end to end.

## Command output (real)

```
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
$ MIX_BUILD_ROOT=_build-sqld5 mix test test/integration/sqld5_sql_shape_court.exs
Running ExUnit with seed: 477365, max_cases: 32
............
Finished in 0.08 seconds (0.00s async, 0.08s sync)

Result: 14 passed
```

## Notes

* Context: solo (graphlaw/ free of concurrent writers to these files).
* One transient mid-write read of `sql_shape_gen.ex` by the compiler
  (partial file) — resolved by the re-write; final on-disk state is the
  version above, byte-stable across two further compiles.
* Lane build root `_build-sqld5` left in place for the SQLD lane family;
  coordinator reclaims at integration (`just lane-clean`).
