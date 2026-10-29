# COLD-1 — Cold-Chain Pipeline Court (real duckdb CLI)

**Standing:** PASS
Context: solo · Date: 2026-10-21 · OTP-29 / OTP 29.1.2, Elixir 1.20.4-otp-29
Lane: COLD-1 · Milestone: v26.10.21 · Subject: COLDCHAIN-CASE-STUDY.md pipeline mechanism

## Court

- `/opt/homebrew/bin/duckdb` CLI v1.4.1 (Andium) b390a7c376, invoked via
  `System.cmd` (`-csv -noheader -c <sql>`), reads the three OCEL v2 CSVs
  (`read_csv_auto`) — parquet-free equivalent, per task.
- SHACL-shaped structural gate on the AST TTL before execution
  (whereClause present; `^[a-zA-Z_][a-zA-Z0-9_]*$` on `sql:tables` identifiers).
- SQL compiled from the RDF AST fixture
  (`test/integration/fixtures/coldchain/cold_chain_ast.ttl`), hand-compiled per
  case-study §3: JOIN events↔rel↔objects, `WHERE temp > -20.0 AND qualifier =
  'contains_product' AND object_type = 'bio:BiologicBatch'`, GROUP BY object_id,
  MAX(temp), SUM(duration).
- Independent Elixir re-derivation of the N3 partition from rule semantics
  (`duration > 300 OR max >= -15.0 -> quarantine; else release`), asserted as
  EXACT SET EQUALITY against the duckdb+N3 pipeline result.

## Result (two consecutive runs, identical — deterministic)

```
COLD-1 COURT: PASS
quarantined: ["BATCH-A1", "BATCH-A2", "BATCH-Q1", "BATCH-Q2", "BATCH-Q3"]
released:    ["BATCH-R1", "BATCH-R2", "BATCH-R3", "BATCH-R4", "BATCH-R5"]
missing_premise_quarantined: ["BATCH-A2"]
tamper_leg:  PASS
audit_hash:  6971c912530619217b462f0b458a390eec34383a8155e0ccfcce869e4b6aeb8e
```

Corpus: 10 batches = 3 quarantine-class (Q1–Q3) + 5 release-class (R1–R5) +
2 ambiguous (A1: max == −15.0 exactly and duration == 300 exactly → quarantine
via `>=`; A2: all events at −20.0 exactly → eliminated by strict `> −20.0` →
NO aggregate row → fail-closed quarantine via missing-premise path, never by
value). 17 events / 17 rels / 10 objects.

## Non-vacuity legs

1. **Fail-closed missing premise (A2)**: A2 quarantines through the
   missing-aggregate-row path (`missing_premise: true` in the receipt map),
   not by an aggregate value. Asserted separately from the value-based verdict.
2. **Tamper leg**: tampered corpus (`-20.0` → `-19.0` in ocel_events.csv)
   provably CHANGES the observed aggregates (A2 gains an aggregate row) and the
   changed observation resolves fail-closed to quarantine; a truncated
   ocel_events.csv makes the real duckdb CLI exit nonzero (refusal) which maps
   to fail-closed lockout. The court now RAISES if this leg fails.
3. **Partition gate**: exact set equality against the independently re-derived
   expected partition raises on any drift.

## Findings during the run

- **Fixture-design correction (recorded honestly)**: the first release-class
  fixture draft stored release batches entirely at ≤ −20.0, so the `temp >
  −20.0` pushdown eliminated them and the pipeline fail-closed them. Release
  batches must carry qualifying exposure events (−20 < temp < −15, cumulative
  duration ≤ 300). Fixed in the generator with an explanatory NOTE comment.
- **Compile-freeze disclosure (cross-lane)**: `mix compile` of the shared tree
  is currently broken by an unrelated lane's UNTRACKED in-flight file
  `lib/smalt/wasm/worker.ex` (undefined variable `^port`, worker.ex:85).
  The court therefore runs with plain `elixir` (stdlib + duckdb CLI only) —
  `elixir test/integration/coldchain_pipeline_court.exs` — not `mix run`.
  No shared file was edited by this lane.

## Machine

- macOS 26.2 (25C56), arm64 (Apple Silicon), OTP 29.1.2 / Elixir 1.20.4-otp-29,
  duckdb CLI v1.4.1 (Andium) b390a7c376.
- (`just bench-machine` invocation was denied by the permission system in this
  lane; the above was collected directly. This is a court, not a bench lane —
  no jsonl emitted.)

## Artifacts

- Court: `/Users/sac/smalt/test/integration/coldchain_pipeline_court.exs`
- Fixture generator:
  `/Users/sac/smalt/test/integration/fixtures/coldchain/generate_fixtures.exs`
- AST TTL fixture:
  `/Users/sac/smalt/test/integration/fixtures/coldchain/cold_chain_ast.ttl`
- Corpus: `/Users/sac/smalt/tmp/coldchain/` (3 CSVs, regenerable byte-identical)
- Result: `/Users/sac/smalt/tmp/coldchain-court-result.terms` (scratch)

## Replay

```
cd /Users/sac/smalt
export PATH="$HOME/.asdf/shims:$PATH"   # elixir 1.20.4-otp-29 via .tool-versions
elixir test/integration/coldchain_pipeline_court.exs
```

Exit 0, output above. No `Process.sleep` anywhere in the court or generator.

## Standing

PASS — the cold-chain pipeline mechanism (OCEL v2 CSV → RDF-AST-compiled SQL →
real duckdb CLI aggregate pushdown → N3 partition → fail-closed ambiguity
resolution → sha256 audit hash bound per batch) is ALIVE as a local mechanism
proof with real tools. Not a GxP claim: no BLAKE3, no frozen-duckdb embedding,
no Parquet partitioning — those remain case-study projections (see
COLDCHAIN-CASE-STUDY.md standing: OPERATOR-CHARTER).
