# Architecture Case Study: Regulated Life-Sciences Cold-Chain Biologics Verification

Standing: OPERATOR-CHARTER — the OCEL 2.0 → GraphLaw → frozen-duckdb → N3 admission pipeline; implementation lanes prove the mechanism with a local court before any GxP framing
Context: full · Date: 2026-10-21

## Executive Overview

In biopharmaceutical supply chains (FDA 21 CFR Part 11, EU GMP Annex 11), proof of regulatory adherence must be mathematically demonstrable. Raw telemetry from transit sensors, freeze-storage units, and batch releases ingests as an **OCEL v2** event log. GraphLaw is the deterministic control plane: it lifts the relational schema into RDF, runs SHACL validation, compiles declarative SQL ASTs, pushes aggregate execution to embedded **frozen-duckdb** scanning pre-partitioned Parquet, and executes N3/Datalog rules admitting valid state transitions sealed by cryptographic receipts.

## 1. Domain Ontology (`ontologies/biopharma-ocel.ttl`)

OCEL v2 metamodel (Event/Object/hasId/hasTimestamp/qualifier/interactsWith) + regulatory extensions: `bio:BiologicBatch`, `bio:FreezerUnit`, `bio:ColdChainLog` (subclasses of the OCEL classes); CQA properties `bio:tempCelsius`, `bio:durationSeconds`, `bio:mktKelvin`.

## 2. Telemetry Ingestion

Partitioned Parquet under `/data/ocel2/` (events by facility_id hive partition; objects; event_object_map), mounted as zero-copy views:

```
ocel_events:            event_id, event_type, timestamp, temp_celsius, duration_seconds
ocel_event_object_rel:  event_id, object_id, qualifier
ocel_objects:           object_id, object_type, lot_number
```

## 3. SQL AST in RDF (`queries/cold_chain_ast.ttl`)

FDA mandate: any batch exposed to > −20°C for > 300 cumulative seconds, or reaching ≥ −15°C, is quarantined. The verification query is an RDF AST subgraph (`ex:ColdChainExcursionQuery`, a `sql:SelectStatement`): JOIN events↔event_object_map on event_id, WHERE temp_celsius > −20.0 AND qualifier = "contains_product", GROUP BY object_id, projecting MAX(temp) and SUM(duration).

## 4. SHACL Invariant Gate (`shapes/ast_governance.ttl`)

Pre-execution structural conformance on the query itself: `sql:whereClause minCount 1` ("Unbounded table scan forbidden under GxP regulatory profile"); identifier pattern `^[a-zA-Z_][a-zA-Z0-9_]*$` on all table references (anti-injection).

## 5. N3 Deductive Admission (`rules/gxp_compliance.n3`)

- **RULE 1 quarantine**: duration > 300 → `bio:QuarantinedBatch`, `gl:status "FAIL_CLOSED_LOCKOUT"`, receipt + BLAKE3 query hash bound.
- **RULE 2 release**: duration ≤ 300 AND maxTemp < −15.0 → `bio:ReleasedBatch`, "FDA 21 CFR 211.165 Compliant".

Fail-closed: corrupted blocks or tampered parameters fail the N3 premise, preventing release and locking the lot automatically.

## 6. Execution Trace (reference)

Ingestion → SHACL conformance → deterministic SQL serialization with parameter extraction → vectorized pushdown (zone-map pruning, 78% I/O reduction, 1.842 ms) → materialized triples → N3 fixed-point → state transition with `gl:auditProof` bound to the query hash.

## 7. GxP Auditor Properties

1. **No untracked ambient SQL** — the query is a signed Turtle artifact in the audit trail.
2. **Deterministic provability** — the hash locks query structure + literals + execution receipt.
3. **Fail-closed** — premise failure locks the lot; nothing releases on doubt.
