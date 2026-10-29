# SQLD-4 — Relational → OCEL Mapping DSL + Court

**Standing:** ALIVE
Context: solo · Date: 2026-10-21 · Lane: SQLD-4 · Milestone: v26.10.21
Subject: `lib/smalt/sql_ingest/mapping.ex` + court (12/12, 3 consecutive green runs)

## What landed

- `lib/smalt/sql_ingest/mapping.ex` — `Smalt.SqlIngest.Mapping`: a
  `sql:TableMapping` Turtle DSL (SQL-AST-in-RDF pattern) with three
  roles: `event` (row → OCEL event: id/type/time/relationships),
  `object` (row → object), `rel` (row → relationship attached to an
  existing event + the object it names — relationship rows double as
  object observations so referential integrity holds without a fourth
  mapping).
- Compiled projection spec (`Mapping.compile/1` fills `typed_columns`:
  declared columns keep declared types; undeclared columns are absent
  from the spec and typed by value at projection time).
- `Mapping.shacl_gate/1` — fail-closed gate on the mapping itself: every
  mapping must declare `sql:sourceTable` + a known role; role=event
  MUST declare `sql:eventTypeColumn` AND `sql:timestampColumn` (an
  untyped/timeless event is laundered nowhere); role=object needs
  key + type; role=rel needs event key, object key, type; duplicate
  source tables refuse; unknown predicates are typed parse refusals.
  `compile/1` refuses an ungated mapping.
- `Mapping.project/2` — projects parsed dump tables (`%{"col" => value}`
  rows, `Smalt.SqlIngest.parse_dump/1`-compatible) into the COLD-1
  OCEL v2 schema, enforcing referential integrity with
  `Smalt.Ocel.validate_envelope/2` before returning — a dangling
  relationship is `{:error, {:dangling_relationships, _}}`, never a
  partial envelope.
- `Mapping.to_cold1_csvs/1` — renders the three COLD-1 CSVs
  (`ocel_events.csv` / `ocel_event_object_rel.csv` / `ocel_objects.csv`),
  COLD-1 core columns leading.
- Court: `test/integration/sql_ingest_mapping_court.exs` (12 tests),
  fixture: `test/integration/fixtures/sql_ingest/sql_mapping.ttl`
  (3-table mapping: orders→events, customers→objects, order_items→rels).

## Court (real output, 3 consecutive runs identical)

```
Result: 12 passed      # x3 consecutive runs
```

Coverage: 100 deterministic synthetic rows (25 customers + 40 orders +
35 order_items) project to 40 events / 60 objects (25 Customer + 35
OrderItem) / 75 rel rows; envelope encodes via the substrate's own
`Smalt.Ocel.encode/1` (exact COLD-1 four-key envelope:
`ocel:eventTypes`/`ocel:objectTypes`/`ocel:events`/`ocel:objects`) and
round-trips through `Smalt.Ocel.decode/1`; unmapped columns (`memo`,
`temp_celsius`, `duration_seconds`) are typed
(`xsd:string`/`xsd:integer`) and kept, never dropped; object attributes
typed (region string, active boolean); determinism leg (two projections
→ byte-identical envelope JSON); COLD-1 CSV face (core columns lead);
fail-closed legs: missing eventTypeColumn, missing timestampColumn, rel
missing objectKeyColumn, unknown role "banana", duplicate sourceTable,
compile-refuses-ungated-mapping, unknown sql: predicate = typed parse
refusal, dangling relationship refused.

## Compile-freeze disclosures (cross-lane, per SLA)

1. `lib/smalt/graphlaw/sql_shape_gen.ex` (SQLD-5's untracked file):
   heredoc terminator on a mid-line (`.\n"""`) — Elixir requires the
   closing `"""` to start the line; the file did not compile tree-wide.
   Minimal fix: moved the terminator to its own line. During the fix I
   briefly overwrote the file with a 10-line partial using Write —
   restored within minutes because the SQLD-5 owner lane had already
   rewritten the full file on disk; my patch then applied to the owner's
   full version. Final diff is one line's shape (terminator position);
   content of the generated Turtle gains a trailing newline before the
   terminator. Disclosed to SQLD-5 via this receipt.
2. `lib/smalt/graphlaw/sql_row_gate.ex` and
   `lib/smalt/storage/journal_sink.ex` (other lanes, actively WIP):
   NOT touched — waited for their owners' fixes; compile went clean on
   retry (poll, no sleeps — 45 s poll interval between `mix compile`
   attempts, observation-driven: each attempt reads real compiler
   output).
3. The court itself is sleep-free (0 `Process.sleep` in module, court,
   and fixture; grep-checked).

## Machine

`just bench-machine` → `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
(default toolchain report; this lane ran on the asdf-pinned toolchain
OTP 29.1.2 / Elixir 1.20.4-otp-29 per `.tool-versions`). Not a bench
lane — no jsonl emitted.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-sqld4 mix compile
MIX_BUILD_ROOT=_build-sqld4 mix test test/integration/sql_ingest_mapping_court.exs
```

Exit 0, `Result: 12 passed`.

## Standing

ALIVE — the mapping DSL, gate, projection, and CSV face are exercised by
a real court over real collaborators (stdlib-only Turtle parser,
substrate `Smalt.Ocel` encode/validate), 3 consecutive green runs.
Boundary: 100-row synthetic corpus (court-scale, not a soak);
`typed_columns` records declared vs inferred, not duckdb-native column
types (that is SQLD-5's DESCRIBE face).
