# SQLD-2 — postgres-dump ingestion court (real duckdb CLI)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · OTP 29.1.2 / Elixir 1.20.4-otp-29
Lane: SQLD-2 · Milestone: v26.10.21 · Subject: SQL-data-before ingestion mechanism

## Court

- Real `/opt/homebrew/bin/duckdb` CLI v1.4.1 (Andium) b390a7c376, invoked via
  `System.cmd` against a persistent db file (`tmp/sqld2/duck.db`) —
  `read_csv` with an explicit typed column map; six-leg court at
  `/Users/sac/smalt/test/integration/sqld2_sql_ingest_court.exs`.
- Corpus: deterministic synthetic pg_dump (orders/customers/order_events,
  500 rows, COPY format), generator
  `/Users/sac/smalt/test/integration/fixtures/sqld2/generate_dump.exs`
  (xorshift64* PRNG, fixed seed, no clock/rand — two runs byte-identical,
  sha256 `c5c65bd153391752d05a56b3d9311a0492d90f21e44da4d28a82637afeed1990`).
- Converter: `/Users/sac/smalt/lib/smalt/sql_ingest.ex` (`Smalt.SqlIngest`,
  NEW this lane, stdlib-only, no Jason) — pure-Elixir COPY-block parser with
  COPY-text unescaping and RFC4180 CSV emit.

## Legs (actual output, run 3 of 3 — all three runs identical)

```
leg1 scanner: read_pg_copy refused as expected -> typed fallback (Elixir COPY parse + CSV load)
leg2 converter: counts=[{"customers", 120}, {"order_events", 80}, {"orders", 300}] (500 rows), columns exact
leg2b unterminated COPY block: refused
leg3 duckdb: 120/300/80 = 500 typed rows loaded; referential + domain integrity 0 violations
leg4 OCEL v2: 80 events / 420 objects / 380 rels, 0 dangling rels
leg4 persist: tmp/sqld2/ocel/ triple written via real duckdb COPY
leg5 excursion: duckdb == Elixir re-derivation, n=11 orders: O-100, O-111, O-162, O-166, O-206, O-251, O-253, O-299, O-32, O-60, O-8
leg6 SHACL gate: injection-token table refused; whole-parse fail-closed (pattern-match assertion, acceptance raises)

SQLD2 COURT: PASS
```

## Typed fallback (exercised, not assumed)

duckdb v1.4.1's postgres extension (`postgres_scanner` installed OK) has no
dump-file reader: no `read_pg_copy`-style table function exists in this build
(ATTACH requires a live postgres server). Leg 1 RUNS the probe and asserts the
typed catalog refusal before falling back — the fallback premise is executed
against the real CLI, never assumed. Fallback: `Smalt.SqlIngest` COPY parse →
CSV → duckdb `read_csv` typed load.

## Non-vacuity legs

1. **Scanner refusal asserted** (leg1): if a future duckdb gains a dump
   reader, this leg fails loudly and the fallback loses its justification.
2. **Excursion exact set equality** (leg5): real duckdb aggregate query vs
   independent Elixir re-derivation from the raw parsed rows — mismatch
   raises; empty excursion set raises (an empty corpus would make the leg
   tautological). COLD-1 pattern.
3. **SHACL gate** (leg6): poisoned dump with table name
   `orders; DROP TABLE orders;--` is refused
   `{:error, {:injection_token, "orders;"}}`; refusal is WHOLE-PARSE
   fail-closed (clean tables from the same dump are discarded). Pattern-match
   assertion — gate acceptance raises.
4. **Unterminated COPY block** (leg2b): truncated dump refuses with
   `{:error, :unterminated_copy_block}`.

## Defect found and fixed during the run (recorded honestly)

The first gate draft SILENTLY SKIPPED malformed COPY headers (regex
non-match → skip branch), so the poisoned header passed through unrefused —
leg 6 caught it on the first court run. Fix in `lib/smalt/sql_ingest.ex`:
any `COPY`-prefixed line not matching the strict
`COPY <ident>[.<ident>] [(cols)] FROM stdin;` shape is refused whole
(`{:error, {:injection_token, first-token}}`). Skipping was the vacuity; the
gate now fails closed. Court rerun: PASS (3 consecutive runs).

## Findings

- duckdb `-csv` + `System.cmd` integer (HUGEINT) fields coerce cleanly;
  DOUBLE fields render `106.0`. Naive comma-split of query output is a
  documented limit: safe here (no comma-carrying values in the corpus);
  comma-carrying values would need RFC4180 parsing at the query-output step
  (the EMIT side of `SqlIngest.to_csv/2` does quote, and duckdb `read_csv`
  parses quotes, so the LOAD side is RFC4180-safe).
- No-sleep: no `Process.sleep` anywhere in module, generator, or court.

## Machine

`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.20.4","otp":"29","darwin":"26.2"}` —
`just bench-machine` output. macOS 26.2 (25C56), arm64; duckdb CLI
v1.4.1 (Andium) b390a7c376.

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"   # elixir 1.20.4-otp-29 via .tool-versions
elixir test/integration/fixtures/sqld2/generate_dump.exs
elixir test/integration/sqld2_sql_ingest_court.exs
```

Exit 0, output above. Deterministic: 3 consecutive runs identical; the
persisted OCEL triple (`tmp/sqld2/ocel/ocel_{events,objects,rels}.csv`,
81/421/381 lines) is byte-identical across runs.

## Standing

PASS — the SQL-data-before mechanism (pg_dump COPY → pure-Elixir
`Smalt.SqlIngest` parse → CSV → real duckdb CLI typed load → OCEL v2
projection → COLD-1-pattern excursion query → fail-closed SHACL gate) is
ALIVE as a local mechanism proof with real tools. Not claimed: real-postgres
ingestion, GxP guarantees, or a duckdb postgres-scanner path (that path is
typed-refused by leg 1 on this build).
