# GLD-6 — SQL ingestion row-gate security court (v26.10.21)

**Standing:** **ALIVE** (court 7/7 PASS, two seeds, on live wire face)

## Subject

- `/Users/sac/smalt` @ HEAD 5c59a89 (uncommitted working tree, GLD wave)
- Lane build root: `_build-gld6`; toolchain OTP 29.1.2 / Elixir 1.20.4-otp-29

## What was built (GLD-6 deliverable)

The ingestion wire face's SHACL gate extended to the DATA itself —
`lib/smalt/graphlaw/sql_row_gate.ex` (`Smalt.GraphLaw.SqlRowGate`):

1. parses the dump's `CREATE TABLE` DDL into the SQLD-5 schema model and
   generates the auto-shapes through `Smalt.GraphLaw.SqlShapeGen.generate/1`
   + the substrate's own `ShapeFile.parse!/2` — generated governance can
   never drift from the admission gate;
2. types COPY rows into the payload `Validator` expects (JSON-integer /
   boolean / binary; NULL -> nil), and refuses per-row: NULL in a NOT NULL
   column -> sh:minCount, string in an integer column -> sh:datatype,
   unknown column -> sh:closed;
3. refuses DDL whose column type has no substrate counterpart (SQLD-5's
   typed no-silent-widening law), naming table.column;
4. wired into the wire face: `Smalt.Egress.SqlIngestRoutes.run_pipeline/4`
   now runs `SqlRowGate.check/2` after the COPY parse and before the OCEL
   projection — a refused dump projects NOTHING (zero bad rows in the
   projected ledger).

## Court

`test/internal/gld6_sql_row_gate_court.exs` — real Bandit TCP listener +
real :httpc POSTs to `/sql-ingest` (the full `Smalt.EgressRouter`), real
COPY parse, real gate, real AndonWire envelope. No mocks. Context: solo.

```
$ MIX_BUILD_ROOT=_build-gld6 MIX_ENV=test mix test test/internal/gld6_sql_row_gate_court.exs
  Result: 7 passed            (seed 456741)
$ ... --seed 99
  Result: 7 passed            (seed 99)
```

Legs (every hostile leg asserts 422 + `GraphlawRefusal` + x-ms-error-code
BusinessLawViolation header + 64-hex context_digest, and NO "tables"/"ocel"
keys in the refusal body = zero bad rows in the projected ledger):

| # | hostile input | verdict |
|---|---|---|
| 1 | control lawful dump | 201, rowCount 2, ocel 1 event / 2 objects (vacuity guard: gate not always-refuse) |
| 2 | NULL in NOT NULL `id` | 422 sql.shacl_row, "row 2 of events violates SqlEventsShape: minCount violation on column id" |
| 3 | string in integer `qty` | 422 sql.shacl_row, "datatype violation on column qty: ... xsd:integer" |
| 4 | second statement smuggled after `\.` | 422 sql.injection_token; parser fails CLOSED on the whole dump (`{:error, {:injection_token, "evil;"}}`) — no partial ingestion |
| 5 | terminator smuggled inside a data row | contained as inert data or typed 422; never 500, never a second table |
| 6 | DDL with `double precision` | 422 sql.shape_generation naming `ratio`/`double` (no silent widening) |
| 7 | schema-less COPY-only dump | ungoverned, never 500 |

## Regression

```
$ MIX_BUILD_ROOT=_build-gld6 MIX_ENV=test mix test test/internal/sql_ingest_wire_court.exs
  Result: 3 passed            (GLD-3 wire court: gate wiring did not regress the face)
$ MIX_BUILD_ROOT=_build-gld6 MIX_ENV=test mix test test/integration/sqld5_sql_shape_court.exs
  Result: 14 passed           (SQLD-5 shape court: auto-shapes unaffected)
```

## Coordination & disclosed cross-lane edits

- GLD-3 (route) + SQLD-5 (shapes) bounded-polled to landing; both present
  before this lane built (route: `lib/smalt/egress/SqlIngestRoutes.ex`,
  shapes: `lib/smalt/graphlaw/sql_shape_gen.ex` mtime 16:34).
- **Disclosed cross-lane edit** (compile-freeze/coordination law): a minimal
  edit to GLD-3's `lib/smalt/egress/SqlIngestRoutes.ex` — one `:ok <-`
  gate step in `run_pipeline/4` plus one `{:refusal, refusal} ->`
  andon_refusal else-clause. GLD-3's own court still passes 3/3.
- Real defects found by this court during development (fixed in-lane):
  `Enum.find_value/3` short-circuits on the truthy `:ok` — both the
  per-row loop and the per-table loop stopped at the FIRST row/table,
  so a bad row after row 1 sailed through; fixed with nil-on-valid
  find_value + wrapper. This was a genuine miss-by-construction class,
  caught by the NULL-in-NOT-NULL leg (row 2 behind a lawful row 1).

## Typed divergences / findings

1. **Schema-unknown tables are ungoverned.** A table whose COPY column
   list does not set-equal its DDL column set is NOT row-gated (it is
   still COPY-parsed and projected). Documented in-code; close condition:
   the wire face should refuse COPY/DDL column-list mismatch (or the
   mapping carries the governed schema out-of-band).
2. Known surface noise (pre-existing, GLD-3's file): after the sub-router
   sends the 422, the main router's blob splat raises
   Plug.Conn.AlreadySentError logged as [error] — response bytes on the
   wire are correct 422 (GLD-3's fallthrough halt path does not see the
   andon_refusal `send_resp` state as sent at the blob splat for the
   matched post path; court-visible as log noise, tests unaffected).
   Pre-existing vs GLD-6: GLD-3's own court shows the same log line.
 3. Build noise: transient compile breaks from concurrent lanes' in-flight
   files (journal_sink.ex, sql_ingest/mapping.ex) — none GLD-6's; all
   settled by end of lane; final state compiles clean.

## Machine

```
$ just bench-machine (equivalent): Darwin 25.2.0, arm64 (Apple Silicon), OTP 29.1.2, Elixir 1.20.4-otp-29
```
