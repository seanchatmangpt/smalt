# SQL Ingestion Before Governance — SQLD/GLD Wave Map (v26.10.21)

Milestone-doc artifact (lane SQLD-9). Standing in every row is
receipt-derived; a lane with no receipt on disk is
**PENDING-SQLD-n / PENDING-GLD-n**, never a standing claim. Compiled
2026-10-21 against the ~17:0x tree state (mid-window: three sibling SQLD/GLD
files changed or moved during this pass — see the churn log).

## How do we handle SQL data *before*? (the honest answer)

The operator question — "how do we handle SQL data *before* (before
graphlaw/POWL governance, before the OCEL ledger exists)?" — has a concrete,
majority-witnessed answer as of this window:

1. **A ranked ladder of ingestion routes, fail-closed at every rung.** SQL
   data does not enter the governed ledger directly. The routes map
   (SQLD-1) carries the ranking + the andon refusal face; the file landed
   at 16:35 and was retracted by its lane before receipt (churn log) →
   standing **PENDING-SQLD-1**.
2. **A fail-closed pg_dump parser with an injection guard.** SQL data
   arriving as a dump file is parsed by `lib/smalt/sql_ingest.ex` (SQLD-2,
   PASS): only `COPY ... FROM stdin` blocks are extracted; a table name
   leg2b/leg6 witness the refusals: unterminated COPY block refused, an
   injection-token table name (`;`, `--`, quotes) refuses the WHOLE parse
   (`{:error, {:injection_token, name}}`, no partial ingestion of a
   poisoned dump). The DDL is read-only; nothing in a hostile dump is ever
   executed (GLD-5 P1: the `FROM PROGRAM` vector has no execution target).
3. **SQLite rides the duckdb sqlite_scanner.** A real `.db` is ATTACHed by
   the real duckdb CLI (SQLD-3, PASS): extension row
   `sqlite_scanner,installed=true` witnessed; OCEL v2 projection; EXACT
   aggregate parity sqlite3-CLI vs duckdb-over-attach behind a SHACL gate
   on the projection AST.
4. **Governance arrives with the schema.** SHACL shapes auto-generated from
   the projected schema (SQLD-5, ALIVE 14/14): NOT NULL → `sh:minCount 1`
   (nullable columns get no minCount, KD-156 SHACL semantics), PK columns
   carry identifier-pattern messages, shapes closed, byte-identical
   deterministic output; unmappable SQL types (DOUBLE, DECIMAL, TIMESTAMP,
   BLOB, ...) are a typed `ArgumentError` — never silent widening to
   string. Generated Turtle round-trips through the substrate's own
   `ShapeFile.parse!/2`, so generated governance cannot drift from the
   admission gate.
5. **Rows themselves are gated, not just schemas.** Per-row SHACL
   compliance over the SQLD-5 auto-shapes, before OCEL projection
   (`lib/smalt/graphlaw/sql_row_gate.ex`, GLD-6) — a refused dump projects
   NOTHING. File on disk mid-write; standing **PENDING-GLD-6**.
6. **Cold path + warm path.** Cold = full-dump ingest (COLD-1 / GLD-4,
   both PASS). Warm = CDC (GLD-2, PASS): epoch snapshot = fold; delta log
   = append-only OCEL events (`insert`; update → `update_before` +
   `update_after` paired by `"tx"`; delete → terminal event + tombstone);
   replay = sort by `(time, id)` + fold, idempotent on event id;
   durability via real append-only segment replay, typed
   `{:journal, :pending, "PROD-1"}` until PROD-1 lands (a
   `lib/smalt/storage/journal_sink.ex` was observed landing mid-window —
   compile-failing at last poll — so that typed PENDING may close shortly).
7. **The seed loop is closed at both ends.** GLD-4 proved the COLD-1
   corpus seeded FROM a SQL dump yields a byte-identical OCEL corpus and
   an identical quarantine/release partition — the ingestion path does not
   change the governed outcome.

## Lane standing table

| Lane | Subject | Standing | Evidence |
|---|---|---|---|
| SQLD-1 | ranked routes map + andon refusal face | PENDING-SQLD-1 | file landed 16:35, retracted before receipt |
| SQLD-2 | pg-dump ingestion (`lib/smalt/sql_ingest.ex`) | PASS | `receipts/sqld2-sql-ingest-court.md`; six-leg court, 3 identical runs |
| SQLD-3 | sqlite ingestion court | PASS | `receipts/sqld3-sqlite-ingestion-court.md`; `test/integration/sqlite_ingestion_court.py` exit 0 (re-run in this window) |
| SQLD-4 | mapping DSL (`lib/smalt/sql_ingest/mapping.ex`) | PENDING-SQLD-4 | file landed 16:45 mid-write, then moved/deleted before receipt |
| SQLD-5 | auto-shape generation | ALIVE (court 14/14) | `receipts/sqld5-sql-shape-gen.md`; `lib/smalt/graphlaw/sql_shape_gen.ex` |
| SQLD-8 | bulk-ingest perf baseline | PASS | `receipts/sqld8-ingest-baseline.md` |
| GLD-1 | N3 governance over ingested SQL data | PENDING-GLD-1 | fixtures only (`test/integration/fixtures/gld1/generate_fixtures.exs`); no court, no receipt |
| GLD-2 | CDC incremental design | PASS (mechanism proof) | `receipts/gld2-cdc-court.md`; `GLD-2-CDC-DESIGN.md` |
| GLD-3 | ingestion wire face | PENDING-GLD-3 | no artifact on disk |
| GLD-4 | cold-chain SQL-seed closure | PASS | `receipts/gld4-sql-seed-court.md` |
| GLD-5 | ingestion skeptic audit | SUSPECT (2 open defects F2/F3) | `receipts/gld5-ingestion-skeptic.md` |
| GLD-6 | per-row SHACL row gate | PENDING-GLD-6 | `lib/smalt/graphlaw/sql_row_gate.ex` on disk mid-write, no receipt |
| COLD-1 | cold-chain pipeline court | PASS | `receipts/cold1-pipeline-court.md` |

## The mapping DSL (SQLD-4) — PENDING

`lib/smalt/sql_ingest/` was observed mid-window with `mapping.ex` (11,368
bytes at 16:45, 5 public defs, CREATE-TABLE DDL → schema model →
`SqlShapeGen` shapes → per-row gate pipeline per its moduledoc) and is now
empty — the lane retracted/moved the file before receipt. Documented from
the receipt when it lands (PENDING-SQLD-4).

## Auto-shape generation (SQLD-5)

`Smalt.GraphLaw.SqlShapeGen.generate/1` takes the duckdb-DESCRIBE-shape
schema model (table + columns{name, type, null, pk}) and emits SHACL
Turtle in the substrate `ShapeFile` grammar: integer family → `xsd:integer`,
string family → `xsd:string`, boolean family → `xsd:boolean`; NOT NULL →
`sh:minCount 1`, PK identifier messages, `sh:closed true`; deterministic
byte-identical output; unmappable types raise typed `ArgumentError`. Court
14/14 on a 3-table schema (conforming rows pass; NULL-in-NOT-NULL,
string-in-int, unknown column refuse).

## N3 governance on ingested data (GLD-1) — PENDING

Fixtures landed: deterministic orders/events dump with deliberate ambiguity
(O6 NULL amount = fail-closed leg; E16 dangling FK; high-value threshold
500,000 cents; suspicious-customer window heuristic). The court that loads
them (`Code.compile_file`, plain `elixir`) has not landed → PENDING-GLD-1.

## CDC incremental design (GLD-2) — PASS

Design doc: `GLD-2-CDC-DESIGN.md`. Three-part
pattern (epoch snapshot as fold; append-only OCEL delta log with tx-paired
update images and tombstoned deletes; court with exact-delta / idempotency
/ durability / tamper legs). Court re-run in this window, exit 0:

```
GLD-2 COURT: PASS
ledger digest: a390a16485bd073fa809aa0b035967e7ab994e5665c8239c7f22a9a4ce10b783
events: 145  rows: 115  tombstones: 5
journal: {:journal, :pending, "PROD-1"}
```

## The wire face (GLD-3) — PENDING

No artifact on disk → PENDING-GLD-3.

## Perf baseline (SQLD-8) — PASS

100k-row pg COPY dump (4.23 MB) → OCEL projection, min-of-3 paired rounds,
`errors=0` (`scripts/bench/sqld8_ingest_baseline.{exs,sh}`):

| route | min wall | rows/sec | peak RSS (worker) |
|---|---|---|---|
| converter (dump→projection) | 1545 ms | 64,725 | 280.6 MiB |
| direct (csv→projection, denominator floor) | 222 ms | 450,450 | 95.4 MiB |

Correctness legs all passing (row counts exact both routes; cross-route
aggregate parity byte-identical; independent awk source-parity EXACT).
Fences derived from the measured baseline: converter ≤ 30 s (19.4x
headroom), direct ≤ 10 s (45x), worker RSS ≤ 512 MiB (1.82x). Long-term
CI form is a ratio fence (AR-BENCH-06).

## The skeptic findings (GLD-5) — SUSPECT, 2 open defects

GLD-5 audited `lib/smalt/sql_ingest.sql_ingest...` — audited
`lib/smalt/sql-ingest...`: audited `lib/smalt/sql_ingest.ex` at its 16:41
text (hostile-dump probes FROM PROGRAM / terminator smuggling / quoted
identifiers / formula CSV / unicode / escapes, re-run through the real
parse → CSV → duckdb `read_csv_auto` path). Verdict SUSPECT:

- **F1 (FIXED mid-audit)**: malformed COPY headers were silently skipped
  (fail-open); the 16:41 text refuses
  `{:error, {:injection_token, name}}`. The flip is the non-vacuity proof.
- **F2 (OPEN)**: `to_csv/2` conflates NULL (`\N`) and empty string — both
  render `""`, so consecutive empty fields collapse rows; duckdb returned
  2 of 3 rows in the probe. The lossless claim is false at the converter
  boundary.
- **F3 (OPEN)**: CSV formula injection (`=cmd`, `+1+1`, `@SUM(1)`) passes
  untouched into OCEL CSVs. Spreadsheet-class consumers are exposed.
- P1..P6 PASS/INERT: no execution path exists anywhere in the parser (the
  `FROM PROGRAM` vector has no target); `\.` data-line semantics is
  postgres-parity by design; unicode byte-preserved; zero-padded ints stay
  VARCHAR (by duckdb sniffer heuristic, not a landed guarantee); float
  value-preserved.

F2/F3 are open defects in `lib/smalt/sql_ingest.ex` until a closing receipt
flips them — no receipt, no flip.

F2/F3 remain the open-defect register for this surface until their closing
receipts land.

## The routes map (SQLD-1) — PENDING

The routes file (`lib/smalt/egress/sql_ingest_routes.ex`, 7,996 bytes)
landed 16:35 naming `andon_refusal/5` as the shared refusal face consumed
by the GLD-6 row gate, and was retracted before receipt. Standing
PENDING-SQLD-1; the ranked-route table is documented from its receipt when
it lands.

## Compile-freeze / churn log (16:40–17:0x, disclosed)

- 16:40 `sql_row_gate.ex` missing `end` (:135) froze shared compile;
  16:44–16:45 `sql_ingest/mapping.ex` missing delimiter (:206, later :386);
  by ~17:05 `mapping.ex` and `sql_ingest_routes.ex` were gone (retracted by
  their lanes) and `lib/smalt/storage/journal_sink.ex` (PROD-1) was landing
  compile-failing. No shared file was edited by SQLD-9; the SQLD-5 ExUnit
  court and GLD-4 court could not be re-run through `mix` in this pass
  (their receipts already carry green runs on the exact subjects).
- GLD-2 (stdlib-only `elixir`) and SQLD-3 (Python + real CLIs) were
  unaffected and were re-run clean in this window (output above in git
  history of this file; see receipts for the canonical output blocks).

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"
elixir test/integration/gld2_cdc_court.exs                 # GLD-2, PASS (re-run here)
python3 test/integration/sqlite_ingestion_court.py         # SQLD-3, PASS (re-run here)
elixir test/integration/coldchain_sql_seed_court.exs       # GLD-4, PASS (per receipt)
MIX_BUILD_ROOT=_build-lane9 mix test test/integration/sqld5_sql_shape_court.exs  # SQLD-5 (post-freeze)
bash scripts/bench/sqld8_ingest_baseline.sh                # SQLD-8 baseline
```

No `Process.sleep` in any court named here; ingest steps are bounded polls
with hard deadlines.
