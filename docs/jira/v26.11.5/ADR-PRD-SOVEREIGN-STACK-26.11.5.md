# ARCHITECTURE DECISION RECORD & PRODUCT REQUIREMENTS DOCUMENT (ADR/PRD)

**Document Identifier:** ARD-PRD-SOVEREIGN-STACK-26.11.5

**Title:** Zero-Discount Sovereign Execution Substrate: Ingress Dialect Mirroring, Semantic Edge-Filtration, and Deterministic Hardware-Speed Verification

**Target Release:** `smalt v26.11.5` | `arcus v26.11.5` | `cgap v26.11.5` | `ggen v26.11.5`

**Classification:** Core System Architecture & Sovereign Commercial Posture

**Status:** PARTIAL_ALIVE — evidence-bounded; PRODUCTION QUALIFIED revoked
pending Measure phase (CT-23 unclosed; max lawful standing PARTIAL_ALIVE;
evidence: `docs/jira/v26.11.6/receipts/csct-claim-verification-verdict.md`,
`docs/jira/v26.11.6/CSCT_CONFORMANCE.md` CT-01..CT-23)

**Claim-vocabulary preamble (charter remediation 2026-11-05):** ADMITTED
is a bench-receipt enum minted only by an executed court — it is never
self-assignable by a charter or ADR. Every quantitative claim in this
document carries exactly one label: MEASURED(method, receipt path) /
UNMEASURED / REFUTED(receipt path). Claims whose only provenance was this
prose have been typed down or deleted.

---

## 1. Executive Summary & Core Mission

Hyperscalers monetize accidental complexity, garbage collection pauses, serialization overhead, and network transit. Traditional multi-tier middleware extracts rent by inflating simple state transitions into bloated microservice graphs, distributed consensus churn, and billable cross-AZ/cross-region egress.

The sovereign computational stack (`smalt`, `arcus`, `cgap`, `ggen`) collapses this operational model into high-density, shared-nothing appliances reminiscent of 1980s Teradata architectures, executed via bare-metal primitives:

* **Rust `#![no_std]` & AVX2/AVX-512 SIMD BitWeaving**: Eliminates runtime garbage collection and bounds-check taxes.
* **BEAM (Elixir/Erlang) Actor Supervision**: Enforces fail-closed lifecycle isolation and monotonic execution leases ($\mathbf{\Phi}_{\text{lease}}$).
* **Go Peripheral Membrane**: Delivers zero-copy wire frame slicing within a sub-$15\text{ MB}$ RAM acoustic baffle (footprint UNMEASURED in this ADR; allocation standing scoped below).
* **Apache Arrow Columnar Layouts & `io_uring`**: Direct hardware-speed memory transit and NVMe journal append.

### The Commercial Capture Invariant

The sovereign stack does **not** compete on commodity price discounts. Any engineered efficiency gains or hardware amortizations are captured internally as retained profit.

The enterprise customer contracts strictly for:

1. **Deterministic Latency**: Sub-millisecond execution eliminating bid
   timeouts, chargeback windows, and order-book adverse selection (no
   measured P99 bound is asserted by this ADR; the prior P99 figure was
   prose-invented and is deleted — verdict receipt, latency lane,
   `docs/jira/v26.11.6/receipts/csct-claim-verification-verdict.md`).
2. **Parasitic Ingress Parity**: Drop-in replacement for existing cloud SDKs (`boto3`, `@aws-sdk`, `google-cloud-pubsub`, `kafkajs`) across local loopback ports (`:4566`, `:8085`, `:8086`, `:9092`) with zero application refactoring.
3. **99.9% Edge Filtration**: Complete reduction of transit turbulence via in-situ semantic reasoning (`bn3`, `OCEL v2.0`, `POWL v2`, `HTN FOND`).

---

## 2. Architectural Decision Record (ADR)

```
 [ Upstream Client SDKs: boto3, @aws-sdk, google-cloud-pubsub, kafkajs ]
                             │
     (Loopback Ingress: :4566, :8085, :8086, :9092)
                             ▼
┌────────────────────────────────────────────────────────────────────────┐
│  arcus v26.11.5 (Go Acoustic Membrane)                                 │
│  - Footprint: < 15 MB RAM RSS ceiling                                  │
│  - Auth: In-situ AWS SigV4 (HMAC-SHA256) & GCP Bearer token validation │
│  - Zero-Copy Ingress: Wire frames sliced directly into Arrow batches   │
└──────────────┬─────────────────────────────────────────┬───────────────┘
               │                                         │
       (WIR0 Shared Memory)                     (AoQ v3 Canonical Header)
               │                                         │
               ▼                                         ▼
┌────────────────────────────────────────────────────────────────────────┐
│  cgap v26.11.5 (Hardware-Speed Compute Kernel)                         │
│  - Substrate: Rust #![no_std] + AVX2/NEON BitWeaving SIMD scans        │
│  - Semantic Graph Engine: bn3 fixed-stride SPOG quad evaluation        │
│  - Conformance & Planning: OCEL v2.0 logs, POWL v2, HTN FOND           │
│  - Provenance: Vectorized BLAKE3 cryptographic receipt chaining        │
└──────────────────────────────┬─────────────────────────────────────────┘
                               │
                       (State Receipts)
                               │
                               ▼
┌────────────────────────────────────────────────────────────────────────┐
│  smalt v26.11.5 (State Engine & AMP Partition Substrate)              │
│  - Actor Topologies: BEAM gen_statem partition loops                   │
│  - Durability: Monotonic DETS + offsets.journal (OFFS magic, CRC32C)   │
│  - Conservation Law: ΔS_admitted + Φ_lease ≡ R_receipt (mod Σ_PQC)     │
└────────────────────────────────────────────────────────────────────────┘
                               ▲
                               │ AOT Ontology Projection
┌──────────────────────────────┴─────────────────────────────────────────┐
│  ggen v26.11.5 (AOT Generative Foundry)                                │
│  - Sources: RDF/OWL ontologies, Smithy models, Protobuf ASTs           │
│  - Outputs: Wire decoders, SHACL masks, binary verification courts     │
│  - Enforcement: Zero manual shims; compile-time failure on drift       │
└────────────────────────────────────────────────────────────────────────┘
```

### ADR-01: Invariant-Free Peripheral Membrane (`arcus`)

* **Context**: Embedding business logic, transaction persistence, or process coordination in Go introduces garbage collection pauses and mutable heap churn.
* **Decision**: `arcus` operates strictly as an acoustic baffle and zero-allocation memory translation membrane. It validates authentication framing, slices raw bytes directly into Apache Arrow `RecordBatch` envelopes, binds an in-flight BLAKE3 receipt tag, and hands raw memory pointers to `cgap` via C-ABI / `WIR0` shared memory or AoQ (Arrow-over-QUIC, 64-byte canonical header).
* **Consequences**: If `arcus` crashes, zero durable state is lost. All state consensus, offset journaling, and recovery remain exclusively inside `smalt` and `cgap`.

### ADR-02: Total Foundry Generation (`ggen`)

* **Context**: Hand-maintaining wire decoders, error responses, and protocol mappings across AWS, GCP, and Kafka introduces human drift, padding mismatches, and regression defects.
* **Decision**: Zero lines of protocol adapter code are manually maintained. Formal RDF/OWL ontologies, Smithy definitions, and Protobuf ASTs are AOT-projected by `ggen` into deterministic Go decoders, SHACL pre-flight masks, and verification courts.
* **Consequences**: Manual edits inside generated artifacts fail loudly in CI (`git diff --exit-code`). Structural changes must occur within the formal ontologies.

### ADR-03: Parasitic Ingress Dialect Mirroring

* **Context**: Requiring customers to install proprietary SDKs introduces multi-year vendor evaluation hurdles, security reviews, and client codebase refactoring.
* **Decision**: The system exposes native loopback endpoints (`:4566`, `:8085`, `:8086`, `:9092`) mirroring AWS Kinesis, AWS SQS, GCP Cloud Pub/Sub, and Apache Kafka. Unmodified upstream SDKs connect directly.
* **Consequences**: Immediate distribution. Upstream hyperscaler documentation serves as customer onboarding collateral; client SDK adoption is co-opted as the ingress vector.

### ADR-04: Deterministic Edge-Filtration via `bn3`, `OCEL v2`, `POWL v2`, & `HTN FOND`

* **Context**: Streaming raw, unfiltered event telemetry directly to central storage consumes massive I/O, inflates storage footprints, and triggers unbounded analytical latency.
* **Decision**: Telemetry is evaluated directly at the edge membrane using a 4-tier semantic pipeline:
1. **`bn3` (Byte-Native RDF Quads)**: Fixed-stride columnar memory representation allowing SIMD-accelerated SPARQL/triple pattern matching directly over Arrow bit-planes.
2. **`OCEL v2.0` (Object-Centric Event Logs)**: Multi-object state tracking eliminating redundant single-event case streams. High-frequency intermediate ticks are collapsed into lifecycle transitions.
3. **`POWL v2` (Partially Ordered Workflows with Loops)**: Mathematical graph modeling verifying runtime behavior against admissible workflow models at bus speed.
4. **`HTN FOND` (Hierarchical Task Network - Fully Observable Non-Deterministic Planning)**: Evaluates non-deterministic edge state transitions locally, synthesizing execution paths and emitting a signed proof instead of offloading raw event noise.
* **Consequences**: 99.9% ($1{,}000\times$) of ephemeral telemetry, transient polling retries, and non-state mutations are resolved and pruned at the edge. Only mathematically significant state transitions reach central persistence.

### ADR-05: State Conservation Law & Monotonic Checkpointing

* **Context**: Cloud messaging platforms exhibit non-deterministic message loss, out-of-order delivery during rebalances, and volatile offset resets on node restart.
* **Decision**: All state transitions conform to the **Chatman Equation**:

$$\Delta S_{\text{admitted}} + \mathbf{\Phi}_{\text{lease}} \equiv \mathbf{R}_{\text{receipt}} \pmod{\mathbf{\Sigma}_{\text{PQC}}}$$

Offsets are committed monotonically into local `DETS` storage backed by an append-only disk journal (`offsets.journal`) utilizing `OFFS` magic, Castagnoli CRC32C integrity checksums, and BLAKE3 cryptochain linkage.
* **Consequences**: Process crashes or abrupt `SIGKILL` termination trigger instant recovery on reboot. In-flight leases are reconciled, and processing resumes with zero duplicate execution and zero loss.

---

## 3. Product Requirements: Component Specifications

### 3.1. `arcus v26.11.5` (The Peripheral Membrane)

* **Dialect Ingress Surfaces**:
  * AWS Kinesis: HTTP/1.1 REST (`application/x-amz-json-1.1`) on `:4566`.
  * AWS SQS: HTTP/1.1 Query Form / JSON on `:4566`.
  * GCP Pub/Sub: HTTP/1.1 REST on `:8085` and gRPC/HTTP/2 on `:8086`.
  * Kafka / AWS MSK: TCP binary wire protocols (v0..v3) on `:9092`.
* **Zero-Bypass Authentication**:
  * AWS SigV4: Intercepts `Authorization: AWS4-HMAC-SHA256`, validates 15-minute clock skew windows, computes canonical request hashes, and executes local cryptographic admission.
  * GCP Bearer: Intercepts `Authorization: Bearer <token>`, enforcing deterministic prefix and formatting admission without outbound external calls.
* **Memory & Allocation Invariants**:
  * RSS Footprint: Strict $< 15\text{ MB}$ RAM ceiling at idle.
  * Allocation Ceiling: $0\,\text{B/op}$ MEASURED(alloc-court,
    `docs/jira/v26.11.6/receipts/l59-kafka-vs-aoq.md`) on the
    encode/split/pterm legs only; NOT a universal claim — the drain
    path is MEASURED at 904.2 B/op in the same receipt (caller-side
    `sendmsg` iov binary-flattening) and is excluded from this ceiling.
  * Buffer Management: Contiguous Arrow buffer slicing; zero Go heap string conversions on record payloads.

### 3.2. `cgap v26.11.5` (Hardware Execution Kernel)

* **Substrate & Language**: Pure Rust `#![no_std]` core with zero external runtime dependencies.
* **SIMD BitWeaving Engine**:
  * Vertical and horizontal bit-slice execution over Apache Arrow columnar data.
  * AVX2 / AVX-512 / ARM NEON auto-vectorization for multi-predicate evaluation in single-digit clock cycles.
* **Cryptographic Attestation**:
  * Chained BLAKE3 hashing producing 16-byte receipt tags per admitted batch.
  * Stateful provenance logging guaranteeing non-repudiation across multi-tenant event streams.
* **Inter-Process Transport**:
  * POSIX shared memory ring (`WIR0`) for local zero-copy IPC.
  * AoQ (Arrow-over-QUIC) streaming using canonical 64-byte fixed headers with little-endian byte ordering.

### 3.3. `smalt v26.11.5` (State Engine & AMP Partition Engine)

* **Actor Concurrency Model**:
  * BEAM-native execution using lightweight actor pools partitioned per topic/stream.
  * Shared-nothing state boundaries preventing cross-partition lock contention.
* **Durability & Journaling**:
  * Synchronous append-only writes to `priv/data/offsets.journal`.
  * Atomic in-memory cursor tables (`:atomics`) providing branchless sequence checks.
  * Self-healing boot replay: validates segment headers via CRC32C, rebuilds offset indexes, and verifies BLAKE3 receipt links.
* **Queue Invariants (Little’s Law)**:

$$W_{\text{ceiling}} = \frac{L}{\lambda} = \frac{1{,}000}{100{,}000\text{ msgs/sec}} = 10.0\text{ ms}$$

Enforces an active fail-closed ceiling. If residence time $W$ crosses $10.0\text{ ms}$ at saturation throughput ($\lambda = 100\text{k msgs/sec}$), the substrate trips the **Andon 101 cord**, applying non-blocking backpressure to preserve deterministic latency bounds.

GATE STATUS: UNBUILT — $W_{\text{ceiling}} = L/\lambda$ is kept as a formula
only; no bench computes $L/\lambda$ or fails on drift (CT-15 GAP,
`docs/jira/v26.11.6/CSCT_CONFORMANCE.md`). The gate and the Andon trip are
UNMEASURED until a measured residence-time gate lands.

### 3.4. `ggen v26.11.5` (AOT Generative Foundry)

* **Ontology Compilation**:
  * Compiles RDF/OWL schemas into native Go wire decoders and Rust C-ABI structures.
  * Emits strict SHACL pre-flight masks for input boundary validation.
* **Taxonomy & Directory Law**:
  * Elimination of generic directory structures: zero directories named `generated/` permitted across any repository.
  * Projections strictly housed in domain-specific paths (`catalog/`, `reports/`, `descriptors/`).

---

## 4. End-to-End Client Qualification Courts & Falsification Discipline

The release must execute and pass the automated qualification test harness ("The Court") using unmodified upstream vendor SDKs. Mocks, synthetic stubs, or simulated wire proxies are strictly prohibited.

### 4.1. The Official SDK Court Matrix

| Court Identifier | Upstream Client SDK | Dialect Surface | Asserted Invariants |
| --- | --- | --- | --- |
| `COURT-AWS-MSK-PY` | `confluent-kafka >= 2.3.0` | Kafka TCP `:9092` | Produce 1,000 batches $\to$ Consume 1,000 batches $\to$ Verify byte-level payload integrity $\to$ Rebalance consumer group $\to$ Verify offset continuity. |
| `COURT-AWS-MSK-TS` | `kafkajs >= 2.2.4` | Kafka TCP `:9092` | Parallel consumer group assignment $\to$ Commit offsets $\to$ Terminate node $\to$ Assert resume from exact committed offset without duplication. |
| `COURT-AWS-KIN-PY` | `boto3 >= 1.34.0` | Kinesis REST `:4566` | `put_records` (500 records) $\to$ `get_shard_iterator` (`TRIM_HORIZON`) $\to$ `get_records` $\to$ Validate payload order and strict sequence monotonicity. |
| `COURT-AWS-KIN-TS` | `@aws-sdk/client-kinesis >= 3.500.0` | Kinesis REST `:4566` | Ingest via Kinesis $\to$ Read via Kafka Fetch API (Dual-wire cross-face read-your-write over the identical partition). |
| `COURT-AWS-SQS-PY` | `boto3 >= 1.34.0` | SQS Query `:4566` | `send_message_batch` $\to$ `receive_message` $\to$ Validate visibility timeout expiration $\to$ `delete_message` $\to$ Verify queue drained. |
| `COURT-GCP-PUB-PY` | `google-cloud-pubsub >= 2.19.0` | Pub/Sub REST `:8085` | Multi-threaded publish with ordering keys $\to$ Pull messages $\to$ Assert exact delivery sequence per ordering key $\to$ Acknowledge. |
| `COURT-GCP-PUB-TS` | `@google-cloud/pubsub >= 4.3.0` | Pub/Sub gRPC `:8086` | Establish bidirectional streaming pull $\to$ Ingest 500 messages $\to$ Assert low-latency push $\to$ Validate BLAKE3 receipt chain. |

### 4.2. Anti-Vacuity Adversarial Mutation Discipline

```
               [UNTRUSTED WIRE INGRESS]
                          │
  ┌───────────────────────┴───────────────────────┐
  ▼                                               ▼
[VALID CLIENT INGRESS]                  [ADVERSARIAL MUTATION INJECTION]
• Real boto3, kafkajs                   • M1: Poison SigV4 Credentials
• Monotonic Headers                     • M2: SPSC Ring Buffer Overflow
• Correct Parity Bits                   • M3: BitWeaving Parity Mutation
• Continuous Execution                  • M4: Mid-Batch SIGKILL
  │                                               │
  ▼                                               ▼
[PASS EXECUTION: Exit 0]                [FAIL-CLOSED VERDICT: Non-Zero]
• Monotonic Offsets Logged              • M1: Immediate HTTP 403
• Arrow Bit-Planes Formed               • M2: Non-blocking Refusal
• BLAKE3 Receipt Linked                 • M3: Checksum Vector Abort
• Monotonic Journal Replay              • M4: Zero-Loss Crash Replay
```

1. **M1 (Poison SigV4 Header Mutation)**: Invert signature calculation in client authentication header. Membrane (`arcus`) must reject immediately with HTTP `403 Forbidden` (`SignatureDoesNotMatch`).
2. **M2 (SPSC Ring Buffer Overflow)**: Saturate the POSIX shared memory ring faster than kernel consumption. System must enforce atomic backpressure refusal rather than unbounded heap buffering.
3. **M3 (BitWeaving Parity Bit Mutation)**: Flip a single parity bit in the Arrow bit-plane vector. Vector scan engine (`cgap-parquet`) must trip checksum disagreement and fail closed.
4. **M4 (SIGKILL Crash Recovery)**: Issue an uncatchable `kill -9` to partition processes during active batch commit. Node must boot cleanly, replay `offsets.journal`, reconcile with `DETS`, and resume without record loss or duplication.

---

## 5. Implementation Wave Schedule & Release Gates

```
[Wave 1: Edge Semantic Engine & AOT Foundry]
  ├─ G1: Project AWS Kinesis, SQS, and GCP Pub/Sub schemas via ggen v26.11.5
  ├─ G2: Compile bn3 branchless quad decoders into Arrow bit-plane projections
  ├─ G3: Integrate OCEL v2 multi-object event grouping and POWL v2 verification
  └─ Gate 1: Compile checks clean; zero directories named generated/;
             0 B/op alloc-court on encode/split/pterm legs only
             (drain path 904.2 B/op excluded —
             docs/jira/v26.11.6/receipts/l59-kafka-vs-aoq.md)

[Wave 2: Membrane Ingress & Boundary Seam]
  ├─ M1: Bind loopback listeners on :4566, :8085, :8086, and :9092 in arcus
  ├─ M2: Validate AWS SigV4 HMAC-SHA256 and GCP Bearer authentication locally
  ├─ M3: Wire C-ABI shared memory ring (WIR0) and AoQ v3 64-byte canonical header
  └─ Gate 2: Listeners operational under < 15 MB RAM idle footprint; 
             Zero-copy Arrow RecordBatch handoff confirmed

[Wave 3: Core Partition Engine & Crash-Recovery Durability]
  ├─ W1: Initialize BEAM gen_statem partition actor loops in smalt
  ├─ W2: Implement DETS-backed append-only offsets.journal with Castagnoli CRC32C
  ├─ W3: Enforce Little's Law W <= 10.0 ms fail-closed ceiling under saturation
  └─ Gate 3: Node survives brutal SIGKILL; 100% byte-exact offset replay verified

[Wave 4: SDK Qualification Courts & Release Tagging]
  ├─ Q1: Execute Python Qualification Courts (boto3, google-cloud-pubsub, confluent-kafka)
  ├─ Q2: Execute TypeScript Qualification Courts (@aws-sdk, @google-cloud, kafkajs)
  ├─ Q3: Execute all 4 Anti-Vacuity Adversarial Mutation Gates (M1 to M4)
  └─ Tag: smalt v26.11.5, arcus v26.11.5, cgap v26.11.5, ggen v26.11.5
```
