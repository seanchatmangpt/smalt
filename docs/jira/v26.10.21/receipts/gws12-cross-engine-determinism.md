# GWS-12 — Cross-Engine Determinism Court (cold-chain admission surface)

**Standing:** PASS (3 legs, partition identical; 2 typed findings recorded)
Context: solo · Date: 2026-10-21 · Lane: GWS-12 · Milestone: v26.10.21

## Subject

Determinism cross-engine court over the case study's cold-chain admission
surface, both repos, current branches:

- `/Users/sac/graphlaw` @ 7eecf86 (plus concurrent lanes' in-flight files,
  disclosed below — none touched by this lane)
- `/Users/sac/smalt` @ 8c97a98 (main)

## Legs

| Leg | Engine | Mechanism | Standing |
|---|---|---|---|
| (a) | native graphlaw ABI (`graphlaw::abi::call`, Rust, debug) | same JSON request → response bytes | PASS |
| (b) | wasm module `graphlaw_wasm.wasm` (wasm32-wasip1, v26.10.13 artifact, wasmi host, gl_alloc/gl_call/gl_free) | same JSON request → response bytes | PASS |
| (c) | smalt COLD-1 court (Elixir + duckdb CLI 1.4.1 + independent N3 re-derivation) | `elixir test/integration/coldchain_pipeline_court.exs` | PASS (replayed this lane) |

Legs (a)/(b) are driven by the landed GWS-5/6 harness
(`tests/common/mod.rs`: native vs wasm byte-identity is asserted on EVERY
request). The court is
`/Users/sac/graphlaw/tests/gws12_coldchain_cross_engine.rs` (2 tests, NEW,
this lane's only diff).

## Court mechanics

1. Real duckdb CLI computes the aggregate pushdown over COLD-1's real fixture
   CSVs (10 batches / 17 events; 9 aggregate rows — BATCH-A2 pushdown-eliminated,
   asserted). Same WHERE/GROUP BY shape as COLD-1's Leg 2.
2. Phase-5 materialized triples: one `bio:ExcursionBatch` per aggregate row,
   each carrying `gl:auditProof "6971c912…"^^xsd:hexBinary` — the COLD-1 audit
   hash, which seals query+literals.
3. The GWS-6 ruleset (SWAP math builtins) runs as `{"op":"n3"}` through native
   and wasm; byte-identity asserted on the raw response bytes.
4. Partition asserted IDENTICAL across all three legs:

```
gws12_partition_identical_across_all_three_legs ... ok
gws12_tampered_aggregate_flips_partition_identically_on_both_engines ... ok
test result: ok. 2 passed; 0 failed
```

```
COLD-1 COURT: PASS
quarantined: ["BATCH-A1", "BATCH-A2", "BATCH-Q1", "BATCH-Q2", "BATCH-Q3"]
released:    ["BATCH-R1", "BATCH-R2", "BATCH-R3", "BATCH-R4", "BATCH-R5"]
missing_premise_quarantined: ["BATCH-A2"]
tamper_leg:  PASS
audit_hash:  6971c912530619217b462f0b458a390eec34383a8155e0ccfcce869e4b6aeb8e
```

5. Cross-language audit-hash reproduction: the COLD-1 audit hash
   (sha256(canonical_query || "||" || "{-20.0, -15.0, 300}"), the Elixir
   `inspect/1` tuple form) was re-derived byte-exactly in Python from the
   formula → identical 32-byte digest. The audit hash binds query+literals
   identically cross-language and cross-engine.

## Findings (typed, honest)

1. **Partition-identical, path-typed divergence (expected, not a defect)** —
   COLD-1's Elixir admission rule is `duration > 300 OR maxTemp >= -15.0 →
   quarantine`; the landed GWS-6 N3 ruleset is `duration > 300 → QUARANTINE`
   (typed) with `maxTemp >= -15` covered only by fail-closed silence
   (R1-tampered/Q2/A1 derive NOTHING rather than a typed QuarantinedBatch).
   The quarantine/release PARTITION is identical on every leg; only the typed
   path differs (value-based vs silence-based quarantine for
   {A1, Q2, A2-silent}). Union set equality is what the court asserts; a
   typed `math:greaterOrEqual` RULE 1b would make the paths coincide too.
2. **GWS-5 court red on the current graphlaw tree (pre-existing, concurrent
   lanes)** — `cargo test --test wasm_governance_preflight`: 1/3 pass, 2 FAIL
   (`governance_preflight_refuses_whereless_scan_naming_select_statement_shape`
   and `..._injection_token...`): the engine now reports the violated shape
   IRI as `sql:HasWhereClause`/component MinCount where the test text expects
   `sql:SelectStatementShape`. graphlaw HEAD is 7eecf86 but the tree carries
   OTHER LANES' uncommitted in-flight edits (Cargo.toml, src/lib.rs,
   src/rules/mod.rs, ontologies/shapes/ast_governance.ttl,
   tests/wasm_governance_preflight.rs itself, plus untracked
   src/bin/graphlaw_run.rs, src/duckdb_op.rs, tests/fixtures/coldchain_e2e/).
   This lane did not modify any of them (this lane's only graphlaw diff is
   the new untracked test file). Ownership belongs to the lane editing
   ast_governance.ttl / wasm_governance_preflight.rs.
3. **GWS-6 green**: `wasm_n3_admission` 3/3, including
   `n3_admission_matches_native_differential` (wasm == native byte-identical).
   Re-confirmed together with GWS-12: 3 passed + 2 passed, zero failures.

## Non-vacuity

- Tamper leg inside the court: BATCH-R1's aggregate tampered to -12.0 must
  flip it OUT of the release set identically on native and wasm (asserted
  byte-identity on the tampered corpus too). Passes — the court is divergence
  sensitive, not vacuously identical corpora.
- A2 missing-premise fail-closed leg asserted (aggs.len() == 9, no A2 row).

## Machine

`just bench-machine`: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
Runtime on PATH (used by the COLD-1 replay): Erlang/OTP 28 [erts-16.2] /
Elixir 1.19.5. Court is a determinism court, not a bench lane — no jsonl
emitted; this is not a bN lane.

## Artifacts

- Court (new, this lane): `/Users/sac/graphlaw/tests/gws12_coldchain_cross_engine.rs`
- Landed harness used: `/Users/sac/graphlaw/tests/common/mod.rs`
- smalt COLD-1 court replayed:
  `/Users/sac/smalt/test/integration/coldchain_pipeline_court.exs`
- smalt fixture corpus (regenerated by the replay):
  `/Users/sac/smalt/tmp/coldchain/*.csv`
- Preceding landed courts: GWS-6
  `/Users/sac/graphlaw/tests/wasm_n3_admission.rs` (3/3 PASS),
  GWS-5 `/Users/sac/graphlaw/tests/wasm_governance_preflight.rs` (1/3, finding 2)
- COLD-1 receipt of record:
  `/Users/sac/smalt/docs/jira/v26.10.21/receipts/cold1-pipeline-court.md`
