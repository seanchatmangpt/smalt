# Product Requirements Document (PRD): Smalt v26.10.21 Sovereign Cloud Engine

Standing: OPERATOR-CHARTER (measured standing grounded in receipts & Chicago courts; coordinator annotations mark the three claims still awaiting their measured anchor)
Context: full · Release target: v26.10.21 Canonical Seal · Date: 2026-10-21

## 1. Product Positioning & Strategic Objective

Smalt v26.10.21 is an autonomous, in-memory sovereign cloud substrate authored on the BEAM virtual machine (ERTS 17.1.1 / Erlang/OTP 29.1.2 / Elixir 1.20.4-otp-29). It displaces multi-tenant Microsoft Azure PaaS middleware across developer workstations, air-gapped confidential enclaves, and enterprise non-production/staging tiers.

By executing wire-identical implementations of Azure's core operational planes alongside a high-velocity native workflow engine, Smalt delivers:

1. **Unmodified SDK Wire Parity:** First-party client libraries (`@azure/storage-blob`, `@azure/cosmos`, `@azure/service-bus`, `@azure/keyvault-secrets`) function over loopback without code refactoring. *(Evidence: `../v26.10.20/receipts/wire-parity-matrix.md` — 6 SDKs witnessed, `../../../tmp/bench/impl21-postupgrade-sdk.jsonl` — 5/5 on the OTP-29 beam.)*
2. **Sub-Millisecond Wire Execution:** 1.04 ms P99 point-reads over loopback HTTP/2, beating Microsoft's planetary Cosmos DB SLA (< 10 ms) by an order of magnitude. *(Evidence: `../../../tmp/bench/t43-p99-hunt.jsonl` — 0.813–1.04 ms across 20k ops; T23 floor profile.)*
3. **Microsecond Native Execution (POWL 2.0):** In-process SESE workflow nets bypass the network stack: point-reads **2 µs P99**, CAS **5 µs P99**, 4-step settlements **74 µs P99**. *(Evidence: `tmp/bench/powl-native-face.jsonl` — POWLBENCH.)*
4. **Level 3 Poka-Yoke & Formal Admission:** Fail-closed ingress gates, SHACL reticle admission, and crash-only refusal semantics prevent invalid state transitions by construction. *(Coordinator annotation: the TLA+ refinement-mapping and Affidavit 352-byte CTRT / FRE 902(14) / FRCP 37(e) claims in this section are OPERATOR-ASSERTED — no court or receipt exists for them in this window; they are roadmap, not landed capability. The landed fail-closed evidence is the reticle courts, kd_conformance, and the ingress Poka-Yoke filters.)*

## 2. Core Service Plane Specifications

```
+──────────────────────────────────────────────────────────────────────────────────────────────────+
|                                  SMALT v26.10.21 CORE SERVICE MATRIX                              |
+──────────────────────────┬─────────────────────────────────────┬─────────────────────────────────+
| Service Plane            | Wire & Protocol Interfaces          | Verified Substrate Guarantees   |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-BLOB                 | REST (2021-12-02..2026-10-06)       | Non-WORM 202 Accepted delete;   |
| (Azure Storage Blob)     | Plaintext :8443 / TLS 1.3 :9444     | XML error serialization;        |
|                          | HTTP/1.1 and HTTP/2 (Bandit)        | Byte-exact staging.             |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-COSMOS               | Gateway REST Plane                  | 1.04 ms P99 point-read; CAS     |
| (Azure Cosmos DB SQL)    | Plaintext / TLS 1.3 :9444           | wall (10-56x on :auto tables);  |
|                          |                                     | quoted-GUID _etag; _gen/_v      |
|                          |                                     | stripping; 412 If-Match wire.   |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-SB                   | AMQP 1.0 (:5671, :5672)             | Native broker settlement;       |
| (Azure Service Bus)      | ATOM / ARM Management               | 254.3 reds/frame decode;        |
|                          |                                     | 44-byte SAS CBS authentication; |
|                          |                                     | 204 No Content queue delete;    |
|                          |                                     | paged $Resources listings.      |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-APIM                 | In-Process Plug Pipeline            | Wire-witnessed 429/401 policy   |
| (API Management)         | Integrated HTTP Ingress             | refusals; in-memory rate limit; |
|                          |                                     | local STS JWT; 0 external hops. |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-KV                   | REST Secret & Cryptographic Plane   | 201 PUT secrets; ES256/RS256    |
| (Key Vault & HSM)        | Attestation endpoint (roadmap)      | sign/verify wire-witnessed;     |
|                          |                                     | SEV-SNP/TPM quote = roadmap.    |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-APPCONF              | REST Key-Value Plane                | 200-upsert contract (SDK-       |
| (App Configuration)      | Webhook / Event Grid Ingress        | witnessed); label slicing;      |
|                          |                                     | loopback push, SSRF air-gap.    |
+──────────────────────────┼─────────────────────────────────────┼─────────────────────────────────+
| PRD-POWL                 | Native BEAM / Erlang Interface      | 2 µs P99 reads; 74 µs settle;   |
| (Workflow & Execution)   | smalt_fond_powl_runner / Executor   | strong-cyclic FOND closures;    |
|                          |                                     | error-free past L8192; graph    |
|                          |                                     | cycle checks 37/37.             |
+──────────────────────────┴─────────────────────────────────────┴─────────────────────────────────+
```

### 2.1 Storage & Data Plane Requirements

#### PRD-BLOB-01: Container Lifecycle & Deletion Semantics
- KD-135: standard container deletions return 202 Accepted; WORM strictly scoped to locked containers. *(Closed-WITH-RECEIPT.)*
- KD-137: 416 → `<Error><Code>InvalidRange</Code></Error>` + `x-ms-error-code` header. *(Closed-SIMULATED.)*
- KD-139: missing `x-ms-blob-type` → 400 MissingRequiredHeader. *(Closed-SIMULATED.)*

#### PRD-COSMOS-01: CAS & Concurrency Scaling
- Point-read P99 ≤ 1.1 ms wire *(witnessed 0.813–1.04 ms, T43; floor 2 µs native, POWLBENCH)*.
- If-Match quoted-GUID CAS with 412 on divergence (KD-148) — **wire-path gap found and fixed this window** (PB-1 DIV-1 → CAS412 lane; regression 35/35, `receipts/cas412r-postfix-regression.md`).
- KD-147 `_gen`/`_v` stripping *(Closed-SIMULATED)*.
- Counter tables on `{write_concurrency, :auto}` + `{decentralized_counters, true}` — 64-worker bursts ≤ 67 ms, zero lost updates *(IMPL-3)*.

#### PRD-SB-01: AMQP 1.0 Broker & Management Parity
- ≤ 254.3 reductions/frame on 1,582-byte frames *(IMPL-13/17 measured denominator)*.
- KD-131 CBS 44-byte derived keys *(Closed-SIMULATED, live CBS witness)*; KD-132 map32 conformance; KD-143 sqlFilter persistence; KD-155 204 No Content deletes; paged `$Resources` listings with real-SDK multi-page traversal (T27r).

### 2.2 Security, Cryptography & Ingress Admission

#### PRD-SEC-01: Transport Security & Post-Quantum Defaults
- Default preferred TLS group on :9444/:5671 is `x25519mlkem768` *(landed: IMPL-14F default flip, 3-leg court; ML-KEM witness captured)*.
- Dual-cert `{certs_keys, ...}` binding ECDSA + RSA on one socket *(landed: IMPL-8, court leg 3)*.
- Real Go clients (crypto/tls) across default/classical/mlkemonly modes: 6/6 pass *(GOLEG)*.
- CRL `allowed_hosts` restriction: **UNSUPPORTED-by-airgap** — no outbound path exists (airgap court stands); mandatory only if egress is introduced.

#### PRD-KV-01: Cryptographic Verification & Attestation
- KD-149/150/151 closed: 201 PUT creates, GUID-versioned URIs, api-version ceiling.
- ES256/RS256 sign/verify via `kv_crypto_dispatch` — wire-witnessed *(KVCRYPTO)*.
- `/attestation/report` SEV-SNP/TPM: **roadmap (PROD-4)** — not landed; PROD-CORE-ADDENDUM work order.

## 3. Native Execution & Formal Verification Engine (POWL 2.0)

### 3.1 Architecture & Performance Requirements

#### PRD-POWL-01: In-Process Microsecond Execution
- Point read P99 ≤ 5 µs *(witnessed 2 µs, POWLBENCH)*.
- CAS mutation P99 ≤ 10 µs *(witnessed 5 µs)*.
- 4-step settlement P99 ≤ 100 µs *(witnessed 74 µs)*.

#### PRD-POWL-02: FOND Strong-Cyclic Policy Engine
- Environmental non-determinism (CAS 412, lock contention) via strong-cyclic state transitions; bounded by the single-opcode retry guard.
- Non-separable cross-cut graphs rejected; SESE preserved *(POWLSK2 5/5 re-court)*.
- Graph acyclicity + normalization via the OTP 29 functional `graph` module *(IMPL-7/15, 37/37)*.

#### PRD-POWL-03: Concurrency Ceiling & Scaling
- Orchestration kernel executes past 8,192 concurrent instances error-free *(PB-3)* — the L8192 wall belongs to the OS socket layer, not the kernel.
- Process censuses via `processes_iterator/0` + `processes_next/1`: 0 words caller heap *(IMPL-1/18)*.

### 3.2 Audit Ledger & Cryptographic Sealing (OCEL 2.0)

#### PRD-AUDIT-01: Deterministic Provenance Sealing
- Every transition emits an OCEL event recording multi-object references.
- Digests stream through SHA-256 with explicit `{epoch, seq}` ordered tuples — cross-release audit portability *(PB-4: the sort is measured-cheap; the maps:fold shortcut is gate-admissible but not adopted)*.
- **Coordinator annotation**: the 352-byte CTRT / FRE 902(14) / FRCP 37(e) legal-standing claims are OPERATOR-ASSERTED — the landed seal is the Merkle root + PROV-O N-Triples + optional EC signature (ReceiptEngine, PB-5 3-way byte-identity). CTRT framing is roadmap.

## 4. Operational Modes & Tooling

### 4.1 Production Reality Simulator (`:prod_sim`)
RU token buckets (10k RU/s, 429 + retry-after), 4–15 ms jitter shims, HSM 2k-ops/10s caps — **roadmap (PROD-5)**; the substrate's real throttle faces (cosmos RU window with scaled retry-after, EH throttle, APIM rate-limit) are landed and wire-witnessed.

### 4.2 Sovereign Migration CLI (`smalt-migrate`)
Trilingual parser (TF/Bicep/ARM), deterministic manifest (byte-identical, NFR-2 measured 0.205s), atomic `.bak` rollback, non-vacuous wire verification with `NonLoopbackEgress` assertion — all receipt-gated ALIVE (`receipts/` migrate family; e2e court 4/4; enterprise fixture 66 resources).

## 5. Non-Functional Requirements & Mechanical Ceilings

- **NFR-BOOT**: production release boot floor measured **1.9 s** (RELBOOT/T47; in-VM init 396–493 ms; remainder ERTS boot + module resolution). The 500 ms aspiration is typed FAIL on the release subject.
- **NFR-FOOTPRINT**: ≤ 100 MB BEAM-internal idle *(measured 93.3 MB BEAM total / 224 MB host RSS, T44)*.
- **NFR-ALLOCATION**: `just memory-gate` ceiling 200 words/txn *(OBSFENCE, shim-proven)*.
- **NFR-STREAMING**: 50 MB payloads ≤ 23 KB peak heap in ≤ 100 ms *(T42: 23,264 bytes / 97 ms measured)*.

## 6. PRD Acceptance Ledger

Grounded in `docs/jira/v26.10.21/VALIDATION.md` (board v8/v9, 45 cells — census mechanically re-derived 2026-10-22 from the board tables; v9 folds NFR-LATENCY→PASS and PRD-APIM→ALIVE counted in the ALIVE-class bucket):

- **29 ALIVE-class** (ALIVE / PASS / ALIVE-on-pinned / CONFIRMED-on-pinned / AVAILABLE / CLOSED) — wire-witnessed via official SDKs and Chicago courts.
- **7 PARTIAL** — mechanically bounded with ceilings/headroom on disk (DATA-01..04, POWL-CEIL, PB-1, PB-2).
- **5 REFUTED** — pruned with executed falsifiers (CORE-02, CORE-03, WIRE-03, POWL-PERF favorably, PB-4).
- **4 UNSUPPORTED/FAIL** — typed boundaries (CORE-04, SEC-03 airgap CRL, POWL-01 EEP-79, NFR-FOOTPRINT idle sub-claim).

Arithmetic: 29 + 7 + 5 + 4 = 45. Row-level PENDING: 0 · PENDING-PB: 0 · PENDING-GWS: 0 (GWS-IN-WASM-COURTS closed BK-31 `receipts/bk31-gws14-inwasm-courts.md`; GWS-SEC-FUZZ closed BK-32 `receipts/bk32-gws15-sec-fuzz.md`).

## Next Operational Horizon

1. **`frozen-duckdb`**: frozen columnar DuckDB over OCEL 2.0 event streams + Cosmos snapshots — zero-copy OLAP without Synapse/Fabric egress.
2. **`graphlaw`**: SHACL/SPARQL-compiled state invariants governing both the analytical tables and the BEAM actor graph.
3. **PROD-1..5**: WAL durability, ingress hardening, native POWL bindings, attestation bridge, `:prod_sim` (PROD-CORE-ADDENDUM work orders).

*Addendum (BK-BMIR3, 2026-10-22): the `tmp/bench/impl21-postupgrade-sdk.jsonl` and `tmp/bench/t43-p99-hunt.jsonl` evidence cited above now has tracked byte-identical mirrors at `docs/jira/v26.10.21/bench/` (impl21-postupgrade-sdk, t43-p99-hunt); paired-sha256-verified, provenance `docs/jira/v26.10.21/bench/PROVENANCE.md`.*
