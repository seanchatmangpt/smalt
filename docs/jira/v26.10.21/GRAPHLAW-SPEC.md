# Architectural Specification: Ontological Boundary Enforcement via graphlaw & POWL v2

Standing: OPERATOR-CHARTER (Chicago Verification Standard) — the GL-1..12 lanes implement this spec; refinements below supersede lane-dispatch details where they differ
Context: full · Target: Smalt v26.10.21 / graphlaw-powl Integration Wave · Date: 2026-10-21

## 1. System Topology

```
[ Inbound Wire / Agent Transition Proposal ]
                     │
                     ▼
+─────────────────────────────────────────────────────────────────────────────+
| GL-8: Wire-Plane Ingress Normalization & Deserialization                    |
| - REST (:8081/:8443) or AMQP 1.0 Transfer (:5672) frames                    |
| - Maps payloads into an ephemeral in-memory RDF Triple-Set                  |
+──────────────────────────────────────┬──────────────────────────────────────+
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| GL-1 / GL-2: Guard Seam (SHACL Compiled Predicates)                         |
|  * Threshold Classes (sh:maxInclusive, sh:minInclusive)                     |
|  * Presence Classes (sh:minCount, sh:datatype)                              |
|  * Exclusion Classes (sh:disjoint, Separation of Duties)                    |
+──────────────────────────────────────┬──────────────────────────────────────+
        Invariants Satisfied │                          │ Invariant Violated
                             ▼                          ▼
+──────────────────────────────────────+ +────────────────────────────────────+
| Admitted State Mutation              | | GL-1/GL-3: Fail-Closed ANDON      |
| - ETS mutation (5 µs CAS)            | | - Zero state mutation committed   |
| - prov:Activity execution step       | | - PROV-O ANDON Receipt            |
| - Next topological edge              | | - FOND repair loopback dispatch   |
+──────────────────┬───────────────────+ +─────────────────┬────────────────+
                   └───────────────────┬───────────────────┘
                                       ▼
+─────────────────────────────────────────────────────────────────────────────+
| GL-3 / GL-12: Unified Provenance Ledger & Merkle Sealing                    |
| - Successful transitions AND ANDON refusals sealed into the OCEL 2.0 trace  |
| - Refusals are first-class audit evidence (GL-12)                           |
+─────────────────────────────────────────────────────────────────────────────+
```

## 2. Component Specifications

### GL-1: In-Process Executor Guard Seam
Intercepts every atomic POWL transition before ETS mutation. Fail-closed: predicate false or raise → abort with zero memory mutation, increment the node's ANDON refusal counter, re-route to the configured FOND strong-cyclic repair branch.

### GL-2: SHACL → Guard Compiler
Compiles declarative shapes into BEAM guard functions across three classes: Threshold (numeric bounds), Presence (field existence / signature tokens), Exclusion (Separation of Duties, `requester_id =/= approver_id`).

### GL-3: ANDON Receipt Specification (JSON-LD)

```json
{
  "@context": ["https://www.w3.org/ns/prov.jsonld", {"andon": "https://smalt.io/ontology/andon#"}],
  "@type": "andon:RefusalReceipt",
  "andon:refusalId": "urn:smalt:andon:99182a",
  "andon:violatingActivity": "urn:smalt:activity:commit_payout",
  "andon:failedConstraint": "https://smalt.io/shapes#ComplianceApprovalRequired",
  "andon:shapeClass": "ThresholdViolation",
  "andon:detail": "Transaction value $50,000 exceeds threshold $10,000 without authorized signature",
  "andon:suggestedRepairAction": "urn:smalt:action:request_compliance_signature",
  "prov:atTime": "2026-10-21T14:49:00.120Z",
  "prov:wasInvalidatedBy": "urn:smalt:actor:unauthorized_agent_01"
}
```

### GL-4: Canonical Business-Net Court
Three-tier lifecycle: L1 ($5k) admitted ≤5µs, zero refusals; L2 ($50k unsigned) ANDON + FOND repair; L3 (signed repair) settles cleanly.

### GL-5: Stochastic Agent-Bounding Court
500 adversarial proposals (prompt-injection simulations, ID transposition, out-of-bounds amounts, missing privacy flags). Criterion: 0 violating ETS mutations; 100% of refusals emit valid ANDON receipts naming the SHACL rule.

### GL-6: Dual-Governance Court
The same RDF ontology governs live POWL transitions and `frozen-duckdb` audit filtering — byte-identical row selections vs live guard decisions; divergence impossible by construction.

### GL-7: Rule-Change Dynamic Recompile Court
Admin mutation updates the RDF graph (ceiling $10k → $2.5k); the compiled guard predicate pointer updates **in-place via an atomic ETS swap**; net topology unchanged; the next $5k transaction ANDONs on the very next reduction slice.

### GL-8: Wire-Plane ANDON Face
HTTP (:8081/:8443): `422 Unprocessable Entity` + `x-ms-error-code: BusinessLawViolation` + JSON-LD refusal envelope. AMQP (:5672): `rejected` disposition, error condition `smalt:business-rule-failed`, custom message annotations.

### GL-9: Governance-Tax Differential Benchmark
Reduction count + wall delta: raw ETS write (~5µs) vs SHACL-guarded ETS write. Fence: governance overhead ≤ 15µs per node step.

### GL-10: Adversarial Skeptic Lane
Bypass probes (direct sub-function invocation), representation fuzzing (nested/non-canonical RDF terms), fail-closed verification (forced formatter/evaluator crash must abort, never default-open).

### GL-11: GRAPHLAW-POWL.md
Canonical manifest: supported SHACL shapes, error codes, FOND repair conventions, benchmark baselines.

### GL-12: Full-Stack Seal Court
ANDON refusals are first-class audit evidence: event ID assigned, hashed into the monotonic OCEL 2.0 Merkle DAG, sealed alongside valid transactions.

## 3. Verification & Acceptance Gates

| Lane | Output Target | Primary Falsifier |
|---|---|---|
| GL-1 | executor guard wrapper | Any mutation after predicate failure |
| GL-2 | predicate-fun compiler | Generated fun > 15µs evaluation |
| GL-3 | JSON-LD refusal receipt | Missing @type/failedConstraint/repair action |
| GL-4 | 3-tier business net court | No recovery after compliance signature |
| GL-5 | 500-iteration fuzz harness | Any illegal ETS mutation |
| GL-6 | dual-governance parity court | Query divergence vs execution |
| GL-7 | live rule swap court | Stale predicate after atomic swap |
| GL-8 | 422 + rejected-disposition witnesses | HTTP 500 or connection drop |
| GL-9 | governance overhead jsonl | > 15µs/step overhead |
| GL-10 | adversarial crash-injection suite | Crash fails open |
| GL-11 | GRAPHLAW-POWL.md | Missing derivation or receipt anchors |
| GL-12 | Merkle audit receipt containing refusal | Refusal omitted from sealed token |

## Coordinator Arbitration (2026-10-21, post-GL-wave)

1. **`lib/smalt/POWL2/` vs `lib/smalt/powl2/`**: same inode (APFS case-alias, not a duplicate directory). Module namespace is `Smalt.Powl2.*`; on-disk casing `powl2` is canonical. No action.
2. **Guard-form war (settled)**: all 7 data-plane/router files now carry the compound form `is_integer(x) and x >= lo and x <= hi` inside `defguardp int_in/3` — semantically identical to the `:erlang.is_integer/3` BIF delegate on OTP 29.1.2 (GL-CONF's erlc probe confirmed the BIF is real). The compound form is the current green state across every lane's runs; re-pinning a fourth time on a semantic no-op is declined. Both forms are lawful under the pinned toolchain; the ledger records the arbitration, not a fourth flip.
3. **ANDON wire shape**: canonical is `Smalt.Powl2.AndonWire` union envelope (GLADJ ruling, 43/43 across 4 courts).
