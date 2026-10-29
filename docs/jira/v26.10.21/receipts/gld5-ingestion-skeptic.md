# GLD-5 — SQL-Ingestion Skeptic Audit (adversarial, v26.10.21)

- **Date**: 2026-10-21
- **Lane**: GLD-5 (skeptic, OTP-29), read-only except this receipt
- **Subject audited**: `lib/smalt/sql_ingest.ex` (UNTRACKED in-flight file owned by the SQLD wave; two mid-audit revisions observed, see D1/D2) @ HEAD af1a4f4, plus the landed courts `coldchain_sql_seed_court.exs` (GLD-4), `sqlite_ingestion_court.py` (SQLD-3), `coldchain_pipeline_court.exs` (COLD-1), `sqld5_sql_shape_court.exs` (SQLD-5), `gld2_cdc_court.exs` (GLD-2), and `scripts/bench/sqld8_ingest_baseline.exs` (SQLD-8).
**Standing**: SUSPECT — execution surface holds (nothing in a hostile dump is ever executed; typed refusals fire on the newest text), but **F2 and F3 remain open defects** in the canonical converter→CSV boundary, and the "lossless" claim is false at that boundary.
- **Context**: solo
- **Commands** (all run from `/Users/sac/smalt`):
  - `elixir tmp/gld5/probe.exs` — hostile-dump probes (FROM PROGRAM, terminator smuggling, quoted identifiers, `\.` handling, unterminated block, formula CSV, unicode, escapes)
  - `elixir tmp/gld5/probe2.exs` — typing/lossless legs through the real parse_dump → to_csv → duckdb CLI `read_csv_auto` path
  - probe scripts preserved: `/Users/sac/smalt/tmp/gld5/probe.exs`, `/Users/sac/smalt/tmp/gld5/probe2.exs`

## Mid-audit mutation disclosure (compile-freeze disclosure law)

`lib/smalt/sql_ingest.ex` is an untracked in-flight file and changed on disk
**twice during this audit** (mtime 16:38: schema-stripping of qualified table
keys `public.t` → `t`; mtime 16:41: malformed COPY headers now REFUSED
`{:error, {:injection_token, first_token}}` instead of silently skipped). All
probe verdicts below were **re-run against the 16:41 text**; findings against
the 16:36 text are retained as the mutation record (the flip is the
non-vacuity proof that F1 was real, not a probe artifact).

## Audit table

| # | Surface | Probe | Observed (real output, 16:41 text) | Verdict |
|---|---|---|---|---|
| F1 | `parse_dump/1` fail-open header skip | header `COPY public.t; DROP TABLE secrets-- (a) FROM stdin;` | 16:36 text: `{:ok, %{}}` (silently skipped — the documented `injection_token` refusal was unreachable for malformed headers). 16:41 text: `{:error, {:injection_token, "public.t;"}}` | **FIXED mid-audit by owning lane**. Close condition satisfied as observed; a regression court asserting this exact probe should land with the fix. |
| F2 | `to_csv/2` NULL/empty conflation → row loss | rows `["\N", "abc", ""]` through parse → CSV → `read_csv_auto` | csv `"v\n\nabc\n"`; duckdb returns **2 of 3 rows** | **OPEN DEFECT**. `csv_field(:null)` → `""` and empty string → `""`; NULL and empty string are unrepresentable downstream and consecutive empty rows collapse (row count is not preserved). The lossless claim is false at the converter boundary. |
| F3 | `to_csv/2` CSV formula injection | `=cmd\|'/c no'!A1`, `+1+1`, `-1+1`, `@SUM(1)` | emitted raw, no `=`/`+`/`-`/`@` neutralization | **OPEN DEFECT** — classic spreadsheet formula injection passes untouched into OCEL CSVs consumed by spreadsheet-class tools. |
| P1 | execution surface | `COPY x FROM PROGRAM '…\| sh';` | 16:41 text refuses (`{:error, {:injection_token, "x"}}`); earlier texts skipped silently; **no execution path exists anywhere** (parser extracts blocks, never evaluates) | PASS-INERT — the PROGRAM vector has no target. |
| P2 | `\.` data-line semantics | data line `\.` mid-block | terminates the block (postgres-parity); attacker-authored following blocks are ingested as their own tables | PASS (postgres-parity, by design) |
| P3 | typed refusals | unterminated COPY block | `{:error, :unterminated_copy_block}` | PASS |
| P4 | unicode fidelity | NFD `café` + U+202E RTL override through parse + CSV | byte-preserved, no normalization (also: RTL-override spoofing passes unflagged — downstream display risk only) | PASS-LOSSLESS |
| P5 | type fidelity — zero-padded ints | `007`,`12`,`8` through real `read_csv_auto` | typed **VARCHAR**, values `007`,`12`,`8` — no silent `007`→`7` collapse | PASS — but by duckdb sniffer heuristic (leading-zero ⇒ VARCHAR), not by a landed guarantee. |
| P6 | float fidelity | `-0.0`, `NaN`, `3.10` through real duckdb | `-0.0` and `nan` value-preserved; `3.10` → `3.1` (numeric typing, expected) | PASS at value level |
| P7 | caller/court census | who exercises `SqlIngest` | only `scripts/bench/sqld8_ingest_baseline.exs` (a **perf** baseline) — no correctness court drives the converter; SQLD-3/GLD-4 ingest via duckdb sqlite-attach / INSERT dumps. Correcting my earlier "zero callers" observation after SQLD-8 landed mid-audit. | FINDING — F2/F3 invisible to every landed court because no court asserts value-exact round-trip through `SqlIngest.to_csv`. |

## What the round-trip courts actually assert (point 3 of dispatch)

- SQLD-3: exact counts + aggregate parity — re-aggregated, never row-level byte-exact.
- COLD-1: partition equality + tamper legs — partition-level, not value-level.
- GLD-4: the only byte-exact leg (CSV byte-identity vs COLD-1 fixtures) — but it rides the INSERT seeding path with `printf('%.1f', …)`/`strftime` re-serialization, so it proves the pipeline preserves its own fixture encoding, never exercising `SqlIngest.to_csv`.
- SQLD-8: perf only (wall/RSS/rows-per-sec), `errors=0` counted, no value assertions.

## Mapping DSL / PII projection surface (point 4)

No mapping DSL is landed in lib/. Projections are hand-written SELECT column
lists inside the courts; `Smalt.GraphLaw.SqlShapeGen` emits **closed** SHACL
shapes (closed-shape schema drift is an admission failure — good), but shapes
derive from the full schema with no PII classification or column allowlist:
a projection SELECT naming a PII column (`email` in the SQLD-5 schema) lands
it in the OCEL ledger with no typed gate anywhere to refuse it. The
compliance surface is currently prose, not machinery.

## Verdict

Standing **SUSPECT**. Ordered kill list:

1. **F2** — silent row loss + NULL/empty conflation. Fix: quoted NULL sentinel
   (e.g. `""` → `""""` distinguishes only if NULL uses a distinct sentinel) or
   typed null column; then a value-exact court over `SqlIngest` itself
   (counts AND per-cell values, incl. `""`-vs-`\N`).
2. **F3** — formula-injection neutralization (prefix `'` on `=+-@` leading
   fields) or typed refusal for spreadsheet-hostile leading chars.
3. **F1 follow-up** — land a regression court pinning the
   `injection_token` refusal for malformed COPY headers (the fix flipped
   during this audit; pin it so it cannot silently revert).
4. **P7** — wire a correctness court through `SqlIngest` end-to-end, or mark
   the module UNWITNESSED in the lane ledger.

No code modified by this lane (read-only audit; probes in tmp/gld5/). The
owning lane's 16:38/16:41 edits to lib/smalt/sql_ingest.ex are theirs; both
edits improve the fail-closed surface and were witnessed here.
