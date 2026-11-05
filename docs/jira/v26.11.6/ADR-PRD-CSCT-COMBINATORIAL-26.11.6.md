# ARCHITECTURE DECISION RECORD & PRODUCT REQUIREMENTS DOCUMENT (ADR/PRD)

**Document Identifier:** ADR-PRD-CSCT-COMB-26.11.6  
**Title:** RFC-0042 CSCT Combinatorial Matrix: Exhaustive 80-Cell Triumvirate Verification across `cgap`, `arcus`, and `smalt`  
**Target Release:** `v26.11.6`  
**Status:** PARTIAL_ALIVE — evidence-bounded; "Active Sovereign Standard"
revoked pending Measure phase (CT-23 unclosed, 13/80 cells executed;
evidence: `receipts/csct-claim-verification-verdict.md`,
`CSCT_CONFORMANCE.md` CT-01..CT-23)  
**Authors:** System Architecture Group  
**Classification:** Internal Core Architecture & Commercial Execution Standard

**Claim-vocabulary preamble (charter remediation 2026-11-05):** ADMITTED is
a bench-receipt enum minted only by an executed court — never self-assignable
by a charter or ADR. Every quantitative claim below carries exactly one
label: MEASURED(method, receipt path) / UNMEASURED / REFUTED(receipt path)
/ MODEL-DERIVED UNMEASURED. Rows whose only provenance was this prose or
the `cell_idx % n` formula have been typed down.  

---

## 1. Executive Summary & Core Thesis

Enterprise cloud vendors (AWS, Azure, GCP) maintain monopoly pricing through synthetic software-defined boundaries. Hyperscalers charge customers for inter-service data transfer, JSON/Protobuf serialization, and virtualized runtime taxes that have no basis in physical silicon.

`RFC-0042 Challenger Sales Chicago Test (CSCT)` moves performance qualification from internal engineering telemetry into an **asymmetric commercial execution instrument**. To make this challenge incontrovertible, `v26.11.6` proves that sovereign wire-parity and microarchitectural supremacy hold not merely on a single toy benchmark, but across the **entire combinatorial Cartesian product of cloud protocols, transport boundaries, and silicon execution kernels**.

The substrate unites three distinct sovereign systems into a single zero-overhead computing fabric (The Triumvirate):
1. **`arcus` (Peripheral Wire Membrane):** Zero-copy ingress decoders for AWS SigV4 (Kinesis, SQS), GCP Pub/Sub Bearer OAuth, Kafka TCP binary wire, and Azure AMQP 1.0.
2. **`smalt` (State & Actor Core):** BEAM partition actors, `PartitionLog` append-only journals, monotonic partition leases, and `OffsetJournal` persistence surviving `SIGKILL`.
3. **`cgap` (Silicon Execution Substrate):** In-register Apache Arrow bit-plane layouts, vertical `BitWeaving` range scan pruning, lock-free POSIX shared memory SPSC rings, and BLAKE3 cryptographic attestation chains.

---

## 2. The 5-Dimensional Combinatorial Space

The qualification surface is defined formally as the Cartesian product of five orthogonal dimensions:

$$\mathbf{\Omega}_{\text{CSCT}} = \mathcal{D} \times \mathcal{T} \times \mathcal{K} \times \mathcal{S} \times \mathcal{A}$$

```
                                  [COMBINATORIAL CSCT SPACE]
                                              │
         ┌────────────────────────────────────┼────────────────────────────────────┐
         ▼                                    ▼                                    ▼
  [DIALECTS (D: 5)]                  [TRANSPORTS (T: 4)]                  [KERNELS (K: 4)]
  • D1: AWS Kinesis                  • T1: Network Socket (TCP)           • K1: Arrow Bit-Plane
  • D2: AWS SQS                      • T2: POSIX SHM SPSC Ring            • K2: BitWeaving Scan
  • D3: GCP Pub/Sub                  • T3: In-Process C-ABI NIF           • K3: OffsetJournal Replay
  • D4: Kafka / AWS MSK              • T4: UDS AOQ1 Sidecar               • K4: BLAKE3 PQC Receipt
  • D5: Azure Event Hubs                      │                                    │
         │                                    │                                    │
         └────────────────────────────────────┼────────────────────────────────────┘
                                              ▼
                             [PRIMARY COMBINATORIAL CELLS]
                                   5 x 4 x 4 = 80 Cells
                                              │
         ┌────────────────────────────────────┴────────────────────────────────────┐
         ▼                                                                         ▼
[CHALLENGER ARC STAGES (S: 6)]                                            [ANTI-VACUITY MUTATIONS (A: 4)]
• S1: ST-01 (Warmer - Wire Parity)                                        • A1: M1 (Poison SigV4 -> 403)
• S2: ST-02 (Reframe - amplification UNMEASURED, CT-06)                                         • A2: M2 (SPSC Overflow -> Refusal)
• S3: ST-03 (Drowning - $422k/mo, inputs UNMEASURED, CT-04)                                         • A3: M3 (BitWeaving Parity -> Refusal)
• S4: ST-04 (Emotional - P99 < 5ms, gate UNBUILT, CT-15)                                       • A4: M4 (SIGKILL -> Zero-Loss Replay)
• S5: ST-05 (New Way - 320.0 ns/record MEASURED one-shot)
• S6: ST-06 (Solution - ROI gate 350.0, MODEL-DERIVED UNMEASURED)
```

### 2.1 Dimension 1: Client Ingress Dialects ($\mathcal{D}$, $|\mathcal{D}| = 5$)
Every dialect is driven strictly by unmodified official client SDKs:
- **$D_1$ (AWS Kinesis):** SigV4 HMAC-SHA256 authenticated REST via `boto3` / `@aws-sdk/client-kinesis`.
- **$D_2$ (AWS SQS):** Query / JSON protocol with deterministic MD5 checksums and `ReceiptHandle` acking via `boto3`.
- **$D_3$ (GCP Pub/Sub):** REST / gRPC publish-pull loops authenticated via OAuth2 Bearer tokens (`ya29...`).
- **$D_4$ (Kafka / AWS MSK):** TCP binary framing, Castagnoli CRC32C checksums, and `RecordBatch` v2 decoding via `kafka-python-ng` / `kafkajs`.
- **$D_5$ (Azure Event Hubs):** AMQP 1.0 framing, token-based CBS auth, and partition batch leasing.

### 2.2 Dimension 2: Transit Seams & Transports ($\mathcal{T}$, $|\mathcal{T}| = 4$)
- **$T_1$ (Network Socket TCP):** Standard loopback socket transport (:4566, :8085, :9092, :5672).
- **$T_2$ (POSIX SHM SPSC Ring):** Single-Producer Single-Consumer lock-free circular slot ring in `/dev/shm` with branchless power-of-2 index masking.
- **$T_3$ (In-Process C-ABI NIF):** Direct pointer handoff across Erlang NIF boundaries (`cgap-beam` / `cgap-ffi`) with GC-pinned resource binaries (`resbin`).
- **$T_4$ (Unix Domain Socket - UDS):** AOQ1 sidecar supervisor domain socket with monotonic generation fencing.

### 2.3 Dimension 3: Silicon Execution & Storage Kernels ($\mathcal{K}$, $|\mathcal{K}| = 4$)
- **$K_1$ (Apache Arrow In-Register Layout):** 64-byte aligned bit-plane slicing with bitmask nulls eliminating JSON parsing overhead.
- **$K_2$ (Vertical BitWeaving Range Scan):** MSB-first pruned column evaluation pruning entire 64-lane blocks before lower bit words are loaded.
- **$K_3$ (PartitionLog & OffsetJournal Persistence):** Monotonic offset assignment and synchronous log append surviving brutal `SIGKILL`.
- **$K_4$ (BLAKE3 Cryptographic Attestation):** Monotonic hash chain binding input frame, partition lease, and output receipt under post-quantum signature schemes.

### 2.4 Dimension 4: Challenger Arc Stages ($\mathcal{S}$, $|\mathcal{S}| = 6$)
- **$S_1$ (ST-01 Warmer):** Baseline wire-parity across 1,000,000 records.
- **$S_2$ (ST-02 Reframe):** Serialization/memory amplification exhibit —
  UNMEASURED (CT-06; the prior 4.53x/4.75x/6.66x constants were stitched
  from unrelated sources and are deleted, verdict:20).
- **$S_3$ (ST-03 Rational Drowning):** Status-quo exhibit:
  $\$422{,}386/\text{month}$ ($\$5{,}068{,}632/\text{year}$) vs
  $\$1{,}200/\text{month}$ ($\$14{,}400/\text{year}$) — arithmetic
  cents-exact, inputs UNMEASURED (verdict:27; no pricing receipt, SUT
  ceiling asserted never priced; CT-04).
- **$S_4$ (ST-04 Emotional Impact):** 10x saturated burst injection with
  $P99 < 5\text{ ms}$ vs cloud GC $2{,}750\text{ ms}$ under Little's Law
  ceiling $W \le 10\text{ ms}$ (formula kept; gate UNBUILT — CT-15 GAP;
  the prior "$W_{\text{actual}} \approx 0.045\text{ ms}$" and "222x
  safety margin" were formula-generated and are deleted, verdict:11).
- **$S_5$ (ST-05 A New Way):** Zero-copy C-ABI NVMe append target.
  Lawful residue: 320.0 ns/record MEASURED (one-shot, unfenced — durable
  receipt value, verdict:21); the prior "$< 15\text{ ns/record}$" and
  universal "$0\text{ B/op}$" claims are deleted (formula constants and
  L59-refuted universal — verdict:18/:20,
  `receipts/l59-kafka-vs-aoq.md`).
- **$S_6$ (ST-06 The Solution):** Commercial gross ROI gate
  ($\text{ROI} \ge 352\times$ target, executable gate pin $350.0$)
  with cryptographically chained BLAKE3 receipt. Standing MODEL-DERIVED
  UNMEASURED until CT-04 closes.

### 2.5 Dimension 5: Anti-Vacuity Adversarial Mutations ($\mathcal{A}$, $|\mathcal{A}| = 4$)
- **$A_1$ (M1 Poison SigV4):** Mutated signature / credential must fail closed with HTTP 403 Forbidden.
- **$A_2$ (M2 SPSC Ring Overflow):** Writing to a saturated ring must yield backpressure refusal (`try_push == false`), never silent drop or memory corruption.
- **$A_3$ (M3 BitWeaving Parity Flip):** Single bit inversion in bit-plane representation must trigger differential checksum refusal.
- **$A_4$ (M4 SIGKILL Crash Recovery):** Abrupt termination during active commits must cleanly restore state from `offsets.journal` with zero data loss.

---

## 3. Mathematical Laws & Physical Invariants

### 3.1 The Chatman Equation

$$\Delta S_{\text{admitted}} + \mathbf{\Phi}_{\text{lease}} \equiv \mathbf{R}_{\text{receipt}} \pmod{\mathbf{\Sigma}_{\text{PQC}}}$$

Every cell in the 80-element matrix satisfies this invariant:
- $\Delta S_{\text{admitted}}$: Schema shape admitted by formal ontology and wire verifier.
- $\mathbf{\Phi}_{\text{lease}}$: Monotonic lease assigned by the partition actor.
- $\mathbf{R}_{\text{receipt}}$: Immutable receipt containing identity, authority, consequence, replay, and standing.
- $\mathbf{\Sigma}_{\text{PQC}}$: Cryptographic boundary guaranteeing tamper-evidence.

### 3.2 Little's Law Invariant ($W_{\text{ceiling}} = L / \lambda$)

Under a continuous $100\text{k msgs/sec}$ saturate load ($\lambda = 100,000$) with a maximum buffer depth of 1,000 frames ($L = 1,000$):

$$W_{\text{ceiling}} = \frac{1,000}{100,000} = 10\text{ ms}$$

If residence time exceeds $10\text{ ms}$, the system has breached queuing
equilibrium. The ceiling $W_{\text{ceiling}} = L/\lambda$ is kept as a
formula; GATE STATUS: UNBUILT (CT-15 GAP — no bench computes $L/\lambda$
or fails on drift). The prior "$W_{\text{actual}} \approx 0.045\text{ ms}$"
and "$222\times$ safety margin" figures were formula-generated
(verdict:11) and are deleted; no measured P99 is asserted here.

### 3.3 The Commercial ROI Equation

Canonical form (remediation 2026-11-05):

$$\text{ROI}_{\text{gross}} = \frac{\$5,068,632.00}{\$14,400.00} = 351.99\times$$

Executable gate pin: $350.0$ (cgap `crates/csct` REQUIRED_ROI_X, arcus
ST-06 gate $\ge 350\times$). Standing: MODEL-DERIVED UNMEASURED until
CT-04 closes — inputs are hardcoded ledger lines with no pricing receipt
(verdict:27). Note the registered pin divergence (csct-spec/README 352.0
vs code 350.0; KD row minted this remediation). The prior "net
350.988 ≈ 351×" line was removed with this rewrite; the gross form above
is the only canonical expression.

---

## 4. The 80-Cell Combinatorial Matrix

| Cell ID | Dialect | Transport | Silicon Kernel | Primary Metric Verified | Anti-Vacuity Guard |
|---|---|---|---|---|---|
| C01..C04 | AWS Kinesis | TCP Socket | Arrow / BitWeaving / Journal / BLAKE3 | Ingest $> 100\text{k/s}$, P99 $< 5\text{ms}$ | M1 (SigV4 403) |
| C05..C08 | AWS Kinesis | POSIX SHM | Arrow / BitWeaving / Journal / BLAKE3 | Zero-copy $0\text{ B/op}$, $< 15\text{ns/rec}$ | M2 (SPSC Overflow) |
| C09..C12 | AWS Kinesis | C-ABI NIF | Arrow / BitWeaving / Journal / BLAKE3 | NIF direct pointer handoff | M3 (Parity Checksum) |
| C13..C16 | AWS Kinesis | UDS AOQ1 | Arrow / BitWeaving / Journal / BLAKE3 | Monotonic supervisor generation | M4 (SIGKILL Replay) |
| C17..C20 | AWS SQS | TCP Socket | Arrow / BitWeaving / Journal / BLAKE3 | Batch 10 msgs, MD5 verified | M1 (SigV4 403) |
| C21..C24 | AWS SQS | POSIX SHM | Arrow / BitWeaving / Journal / BLAKE3 | SPSC slot lease, ack handle | M2 (SPSC Overflow) |
| C25..C28 | AWS SQS | C-ABI NIF | Arrow / BitWeaving / Journal / BLAKE3 | In-process queue actor deref | M3 (Parity Checksum) |
| C29..C32 | AWS SQS | UDS AOQ1 | Arrow / BitWeaving / Journal / BLAKE3 | Sidecar egress push | M4 (SIGKILL Replay) |
| C33..C36 | GCP Pub/Sub | TCP Socket | Arrow / BitWeaving / Journal / BLAKE3 | Bearer auth, publish/pull loop | M1 (Bearer 401) |
| C37..C40 | GCP Pub/Sub | POSIX SHM | Arrow / BitWeaving / Journal / BLAKE3 | Zero-alloc frame transfer | M2 (SPSC Overflow) |
| C41..C44 | GCP Pub/Sub | C-ABI NIF | Arrow / BitWeaving / Journal / BLAKE3 | GC-pinned resbin handoff | M3 (Parity Checksum) |
| C45..C48 | GCP Pub/Sub | UDS AOQ1 | Arrow / BitWeaving / Journal / BLAKE3 | Sub-socket streaming pull | M4 (SIGKILL Replay) |
| C49..C52 | Kafka/MSK | TCP Socket | Arrow / BitWeaving / Journal / BLAKE3 | Magic-2 RecordBatch CRC32C | M1 (CRC Refusal) |
| C53..C56 | Kafka/MSK | POSIX SHM | Arrow / BitWeaving / Journal / BLAKE3 | Zero-copy DMA slot ring | M2 (SPSC Overflow) |
| C57..C60 | Kafka/MSK | C-ABI NIF | Arrow / BitWeaving / Journal / BLAKE3 | Direct partition log append | M3 (Parity Checksum) |
| C61..C64 | Kafka/MSK | UDS AOQ1 | Arrow / BitWeaving / Journal / BLAKE3 | High-throughput stream socket | M4 (SIGKILL Replay) |
| C65..C68 | Azure EH | TCP Socket | Arrow / BitWeaving / Journal / BLAKE3 | AMQP 1.0 frame disposition | M1 (CBS 401) |
| C69..C72 | Azure EH | POSIX SHM | Arrow / BitWeaving / Journal / BLAKE3 | Lock-free slot disposition | M2 (SPSC Overflow) |
| C73..C76 | Azure EH | C-ABI NIF | Arrow / BitWeaving / Journal / BLAKE3 | In-process partition lease | M3 (Parity Checksum) |
| C77..C80 | Azure EH | UDS AOQ1 | Arrow / BitWeaving / Journal / BLAKE3 | Sidecar AMQP proxy | M4 (SIGKILL Replay) |

**Cell provenance annotation (per `receipts/csct-claim-verification-verdict.md`
:11, remediation 2026-11-05):** all 80 cells are FORMULA-GENERATED, not
court-executed — the receipt's per-cell metrics are arithmetic on the loop
index (`cell_idx % n`; 19 distinct values across 80 cells), probe outcomes
(incl. Kafka SIMULATED_WIRE) are non-gating and dropped from the evidence
payload, and T2/T3/T4 transports are never combined with dialects (60 cells
pure formula). The 16 D5/Azure cells are NO-COLLABORATOR (CT-01: no dialect
face, no client, no probe exists). The table below is the TARGET surface
the matrix names, not a record of execution.

---

## 5. Verification & Acceptance Criteria

1. **Complete Matrix Execution:** 13/80 cells EXECUTED (the ~13 distinct
   real tests under the wave — verdict:9/:11), 67/80 NOT-TESTED. The
   original "All 80 cells must be executed and verified by automated
   courts" criterion is unmet by its own standard (verdict:11); it
   remains the close condition for CT-01/CT-23.
2. **Fail-Closed Anti-Vacuity:** Every court must witness real rejection when presented with mutated or corrupt frames (M1..M4).
3. **Little's Law Invariant:** End-to-end P99 latency across all 80 cells
   must strictly observe $P99 < 5.0\text{ ms}$, bounded by
   $W_{\text{ceiling}} = 10\text{ ms}$. The $W \le 10\text{ ms}$ figure is
   a ceiling FORMULA only; the enforcing gate is UNBUILT (CT-15 GAP).
4. **Economic ROI Integrity:** Canonical expression: gross ROI =
   $\$5,068,632 / \$14,400 = 351.99\times$; the executable gate pins
   $350.0$ (cgap `crates/csct` REQUIRED_ROI_X / arcus ST-06 $\ge 350\times$).
   Standing: MODEL-DERIVED UNMEASURED until CT-04 closes — the ledger
   line items are hardcoded, no pricing receipt exists, and the
   $1,200/mo SUT ceiling was asserted, never priced (verdict:27).
   Registered pin divergence: csct-spec/README pins 352.0 vs code 350.0
   (KD row minted, this remediation).
5. **Cryptographic Standing:** The receipt must be output to `cgap/reports/challenger_sales_combinatorial_receipt.json` and cryptographically verifiable with status `ALIVE`.
