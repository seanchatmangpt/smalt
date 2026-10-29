# GLD-4 — Cold-Chain SQL-Seed Closure Court (seed loop: SQL in → same pipeline → same decisions)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · OTP 29.1.2 / Elixir 1.20.4-otp-29
Lane: GLD-4 (OTP-29) · Milestone: v26.10.21 · Subject: COLD-1 pipeline ingestion path

## Claim closed

The COLD-1 corpus seeded FROM a postgres-style SQL dump produces (a) a
BYTE-IDENTICAL OCEL corpus and (b) an IDENTICAL quarantine/release partition to
the COLD-1 receipt — the ingestion path does not change the governed outcome.

## Pipeline under court

```
ColdchainFixtures.batches()  (same literal source as COLD-1's generator — the
                              dump cannot drift from the fixtures by construction)
  -> tmp/coldchain-sqlseed/coldchain_dump.sql
     (CREATE TABLE ocel_events / ocel_objects / ocel_event_object_rel + INSERTs;
      temp_celsius DECIMAL(5,1) — exact one-decimal literals, no float drift)
  -> real duckdb CLI v1.4.1 executes the dump into a persistent seed.duckdb
  -> OCEL projection: SELECT ... ORDER BY pk -> CSV (headers aliased to the
     COLD-1 fixture header names; ordering matches the fixture serialization:
     sorted batch, then event index == lexicographic pk order)
  -> excursion aggregate over the INGESTED SQL tables (same canonical query
     text as COLD-1, tables instead of read_csv_auto) -> N3 admission
```

## Results (two consecutive runs, identical output — deterministic)

```
GLD-4 SQL-SEED COURT: PASS
byte_identity: ["ocel_events.csv", "ocel_event_object_rel.csv", "ocel_objects.csv"]
quarantined: ["BATCH-A1", "BATCH-A2", "BATCH-Q1", "BATCH-Q2", "BATCH-Q3"]
released:    ["BATCH-R1", "BATCH-R2", "BATCH-R3", "BATCH-R4", "BATCH-R5"]
missing_premise_quarantined: ["BATCH-A2"]
partition_matches_cold1_receipt: true
ingest_rows: %{events: 17, rels: 17, objects: 10}
bounded_poll_leg: PASS
fail_closed_leg: PASS
```

Byte-equality evidence — sha256, COLD-1 hand-generated vs SQL-seeded (identical
on both court runs):

```
1b2db9dcdd03bbb61a8a7117755301c250f991907c21826f053efab866c449d8  ocel_events.csv      (both dirs)
b6dbd631571a7d7c82ac1125043a56f15865090ee26da34d3f1644dd4fc6c8d5  ocel_event_object_rel.csv (both dirs)
473f19f4d39a75f412abc379e9a069ce36e206ef466c57b346d81135a97c0b18  ocel_objects.csv     (both dirs)
```

Partition is exactly the COLD-1 receipt partition
(`docs/jira/v26.10.21/receipts/cold1-pipeline-court.md`): q = {A1, A2, Q1, Q2, Q3},
r = {R1..R5}, missing-premise = {A2} — including A2's fail-closed
missing-aggregate-row path through the SQL-seeded tables.

## Court legs

1. **Byte-identity**: SQL-seeded OCEL CSVs byte-identical (sha256) to COLD-1's
   hand-generated fixtures. RAISES on any differ.
2. **Partition identity**: excursion query + N3 admission over the ingested SQL
   tables == COLD-1 receipt partition, exact set equality on all three sets.
3. **Fail-closed on the SQL path**: BATCH-A2 has no aggregate row in the
   SQL-seeded corpus and quarantines via missing-premise, never by value.
4. **Bounded-poll non-vacuity**: the ingest runs under a hard deadline
   (`Task.yield/2`, 15 min); the leg proves the deadline BINDS with a real
   poison dump (runaway recursive CTE) against a 3 s deadline — `Task.yield`
   returned nil (the poison genuinely exceeded the bound and was
   `Task.shutdown(:brutal_kill)`-ed), which maps to a typed fail-closed
   refusal. A poll that could not time out would raise (vacuous-gate failure).
   No `Process.sleep` anywhere.

## Premise corrections (recorded honestly)

- **Dispatch named "the exact COLD-1 corpus values: BATCH-MAB-9042/9043/9044"**:
  no `MAB-9042` rows exist anywhere in the repo (grep: zero hits) and COLD-1's
  corpus is BATCH-Q1–Q3 / R1–R5 / A1–A2. The binding assertion in the same
  dispatch ("byte-identical corpus to COLD-1's hand-generated fixtures") pins
  the ids to the real COLD-1 values, so the court uses those. The MAB ids are
  recorded as dispatch drift, not silently renamed.
- **"SQLD-2 pattern"**: no such register row exists in the repo. Implemented as
  the bounded-poll execution shape the dispatch describes (15 min deadline,
  typed refusal on breach).
- Engine note: duckdb CLI v1.4.1 executes the postgres-flavour dump
  (CREATE TABLE + INSERT). This proves the SQL-in-seed path on a real engine;
  it is not a postgres-server run (no server in the loop).

## Machine

- macOS 26.2 (25C56), arm64, Apple M3 Max 16-core / 48 GB.
- OTP 29.1.2 / Elixir 1.20.4-otp-29; duckdb CLI v1.4.1 (Andium) b390a7c376.
- `just bench-machine` (this lane, granted): `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
  (report-only tool reports its own default toolchain versions; the court itself
  ran under OTP 29.1.2 as above). This is a court, not a bench lane — no jsonl.

## Artifacts

- Court: `/Users/sac/smalt/test/integration/coldchain_sql_seed_court.exs`
- Seed dump (regenerable): `/Users/sac/smalt/tmp/coldchain-sqlseed/coldchain_dump.sql`
- SQL-seeded corpus: `/Users/sac/smalt/tmp/coldchain-sqlseed/` (3 CSVs + seed.duckdb)
- Baseline corpus: `/Users/sac/smalt/tmp/coldchain/`
- Result (scratch): `/Users/sac/smalt/tmp/coldchain-sqlseed-court-result.terms`

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"   # elixir 1.20.4-otp-29
elixir test/integration/coldchain_sql_seed_court.exs
```

Exit 0. Two consecutive runs byte-identical (CSV sha256 stable across runs).

## Standing

PASS — the seed loop is closed: SQL dump in → same duckdb+N3 pipeline →
byte-identical corpus and identical governed partition. The pipeline is
source-neutral across CSV and SQL ingestion for this corpus. Scope: local
mechanism proof on duckdb CLI; not a GxP claim, not a postgres-server run.
