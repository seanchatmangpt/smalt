# Architecture Requirements Document (ARD) & Product Requirements Document (PRD): Smalt v26.10.21 Sovereign Cloud Engine

Standing: OPERATOR-CHARTER (aspirational targets are operator-asserted until receipted; measured standing is tracked in docs/jira/v26.10.20/DFLSS-CHARTER.md and the receipts/ tree)
Context: full · Date: 2026-10-21

## 1. Executive Summary & Strategic Directive

### 1.1 Product Mission and Market Positioning

Smalt v26.10.21 is an autonomous, sovereign, in-memory cloud platform and execution substrate authored on the BEAM virtual machine. Its core objective is the displacement of multi-tenant Microsoft Azure Platform-as-a-Service (PaaS) middleware across enterprise non-production, staging, and latency-critical operational tiers.

Public cloud PaaS architectures monetize operational coordination and defensive partitioning. Enterprise workloads face systemic performance and financial penalties due to artificial cloud limits:

- **Cosmos DB** enforces physical partition boundaries (10,000 RU/s and 50 GB ceilings), throwing HTTP 429 (RequestRateTooLarge) under concurrency bursts and requiring multi-second exponential backoff loops.
- **API Management (APIM) Premium** imposes an operational cost of $2,795 per unit monthly while adding 16 to 25 milliseconds of remote network policy evaluation latency.
- **Service Bus Premium** ($677 per Messaging Unit monthly) and **Event Hubs Dedicated** clusters ($1,000 to $6,000 monthly) restrict partition scaling and rate-limit AMQP connections.
- **Key Vault Managed HSM** clusters ($3.20 per hour or ~$2,300 monthly) throttle cryptographic operations to 2,000–4,000 operations per 10 seconds.

Smalt v26.10.21 breaks this vendor-lock tollbooth paradigm. By executing an in-memory, wire-identical implementation of Azure's primary PaaS planes, Smalt enables enterprise systems to run unmodified first-party SDKs (`@azure/storage-blob`, `@azure/cosmos`, `@azure/service-bus`, `@azure/keyvault-secrets`) against local, containerized, or in-browser WebAssembly (WASM) BEAM nodes.

### 1.2 The Technological Thesis: Inverting Cloud Limits with Modern BEAM Primitives

Azure throttles through artificial billing token buckets designed to protect centralized compute margins. Smalt replaces these artificial boundaries with physical hardware constraints:

- Cooperative reduction counters (2,000 reductions per timeslice) replace paid priority tiers to guarantee starvation-free preemption across concurrent operations.
- Dynamic, lock-free shared memory tables eliminate multi-region coordination engines and caching SaaS layers.
- Process isolation protects actor state, eliminating the container sandbox overhead typical of hypervisor-level isolation.

To achieve direct operational superiority over Azure, Smalt v26.10.21 integrates modern runtime enhancements across Erlang/OTP 27, 28, and 29 alongside Elixir v1.17 through v1.20. These runtime improvements eliminate legacy BEAM bottlenecks—including global trace locks, mailbox scanning overhead, tuple-copy allocation churn, and external JSON parsing overhead—delivering deterministic sub-millisecond execution across all service planes.

> **Verification note (coordinator, 2026-10-21)**: the OTP-29-specific capability claims in this document (EEP-79 native records, deterministic map iteration order, `is_integer/3` guards, `x25519mlkem768` defaults, `processes_iterator/0`, EEP-76 priority aliases, `trace:session_create/3`, `PartitionSupervisor.resize!/2`) are under empirical probe (see `docs/jira/v26.10.20/receipts/otp29-capability-probes.md` when landed). Each Phase-1..4 item must pass its probe or be re-scoped before implementation; claims that fail the probe are typed REFUTED and dropped, not implemented against a nonexistent API.

## 2. Architecture Requirements Document (ARD)

### 2.1 Substrate Core & ERTS Runtime Engine

```
+-----------------------------------------------------------------------------------+
|                        Smalt v26.10.21 Substrate Architecture                     |
|                                                                                   |
|  [ Ingress Protocols: TLS 1.3 / Post-Quantum Hybrid (x25519mlkem768) ]            |
|       |                           |                          |                    |
|       v                           v                          v                    |
|  +------------------+    +-------------------+    +----------------------+        |
|  | Blob Wire Engine |    | Cosmos CAS Engine |    | AMQP 1.0 Broker      |        |
|  | (:8443 / :9444)  |    | (:8081 / :9444)   |    | (:5671 / :5672)      |        |
|  +------------------+    +-------------------+    +----------------------+        |
|       |                           |                          |                    |
|       +---------------------------+--------------------------+                    |
|                                   v                                               |
|  [ Shared Data Plane: Dynamic ETS ({write_concurrency, auto}) ]                   |
|  [ In-Process Coordination: Registry.lock/3 & Priority Aliases ]                  |
|  [ Execution Validation: POWL 2.0 Compiler & ShaclReticle ]                       |
|  [ Runtime Telemetry: Isolated Multi-Session Tracing (trace:session_create/3) ]   |
+-----------------------------------------------------------------------------------+
```

#### AR-CORE-01: Constant-Memory Process Table Iteration

**Problem Statement**: Enterprise background sweeps, connection leak detectors, and tenant censuses historically invoked `erlang:processes/0`. In high-density nodes executing 500,000+ concurrent actors, this operation allocates an unbounded O(N) list on the caller's heap, inducing major garbage collection pauses, cache-line invalidation, and transient node unresponsiveness.

**Architectural Specification**: All internal diagnostic sweeps, orphan resource collectors, and tenant process monitors must utilize `erlang:processes_iterator/0` and `erlang:process_next/1`. Iteration must run across scheduling slices in bounded batches, maintaining a strictly constant O(1) memory footprint without stopping active worker loops.

**Verification Gate**: Node health monitors must traverse a node hosting ≥ 500,000 active processes with heap growth constrained to ≤ 64 KB and zero scheduler latency jitter.

#### AR-CORE-02: Priority Mailbox Signaling via EEP 76

**Problem Statement**: High-volume ingestion actors (such as Cosmos DB partition handlers or AMQP topic workers) can accumulate message queues exceeding 50,000 items. Urgent control-plane signals (circuit-breaker trips, supervisory drain orders, quota shutdowns) trapped behind high-throughput data messages cause administrative lag. Attempting selective receive incurs an O(N) traversal cost over preceding messages, degrading scheduler efficiency.

**Architectural Specification**: Worker processes exposed to saturation bursts must initialize a priority alias via `alias([priority])`. Supervisors, partition coordinators, and circuit breakers must route administrative, kill, and drain signals exclusively through this priority alias. The runtime injects these signals directly at the head of the process mailbox, pre-empting pending transactions without scanning overhead.

**Verification Gate**: Under an injected data queue depth of 50,000 messages, an administrative drain command sent via a priority alias must process in ≤ 500 µs.

#### AR-CORE-03: JIT Multi-Segment Binary Matching for Wire Serialization

**Problem Statement**: Emulating wire protocols (AMQP 1.0 framing in Service Bus, staged block chunking in Blob Storage, HTTP/2 framing) requires packing and unpacking mixed-endian, multi-segment binary headers, consuming substantial CPU reductions.

**Architectural Specification**: Network deserializers in `lib/smalt/amqp/` and `lib/smalt/blob/` must be structured to exploit the BEAM JIT multi-segment binary matching optimizations available in Erlang/OTP 29. Binary matching clauses must align with native register boundaries, avoiding intermediate sub-binary allocations during endianness conversions.

**Verification Gate**: Reductions consumed per AMQP 1.0 transfer frame decode must decrease by ≥ 30% compared to the legacy non-JIT baseline.

#### AR-CORE-04: Compile-Time Escape Analysis & Memory Compaction

**Problem Statement**: Transactional FSM loops repeatedly construct updated state records, generating short-lived heap objects that trigger minor garbage collection cycles under high operations per second.

**Architectural Specification**: Core state transitions within connection runners and finite-state machines (gen_statem) must structure record updates to satisfy the compiler's escape analysis, enabling safe in-place destructive updates of tuples and state terms. Map comprehensions computing deterministic responses must utilize constant expressions to compile into single-pass allocation routines.

### 2.2 In-Memory Data Plane & Transactional Coordination

#### AR-DATA-01: Dynamic Lock Granularity and Decentralized Counters

**Problem Statement**: Centralized ETS tables supporting high-frequency concurrent operations (such as Cosmos DB document stores and Blob block stages) suffer from cross-core write contention and cache-line invalidation.

**Architectural Specification**: All shared ETS tables across the storage, document, and messaging engines must be initialized with `{write_concurrency, auto}` and `{read_concurrency, true}`. This configuration dynamically adjusts internal write locks based on real-time scheduler contention while automatically activating `{decentralized_counters, true}` to distribute table size tracking across scheduler-specific cache lines.

**Verification Gate**: Concurrent execution of 1,024 concurrent CAS operations across 16 scheduler threads must show zero lock contention stalls and flat P99 latency.

#### AR-DATA-02: Race-Free Atomic Traversal and Upsert Primitives

**Problem Statement**: Legacy read-modify-write patterns (lookup followed by conditional insert) create concurrency race conditions unless protected by expensive table locks via `safe_fixtable/2`.

**Architectural Specification**:

- All range queries, table scans, and cursor-based pagination flows must use `ets:next_lookup/1` to retrieve the key and associated payload in a single atomic cycle.
- Counter updates, sliding-window rate limiters, and document upserts must use `ets:update_element/4`, atomically updating target indices or inserting default baseline records if the key does not exist.

**Verification Gate**: Zero race windows detected during parallel upsert contention across 10,000 interleaved test iterations.

#### AR-DATA-03: Term-Scoped In-Process Mutual Exclusion

**Problem Statement**: Routing entity-level synchronizations (e.g., CAS operations on a specific Cosmos DB document or write leases on a specific blob) through a singleton GenServer introduces an operational bottleneck.

**Architectural Specification**: Localized transactional locking must be decoupled from process identity and implemented via `Registry.lock/3`. Worker processes synchronize directly on arbitrary composite keys (e.g., `{:cosmos_doc, database, collection, document_id}`). The lock is automatically released upon function return or caller crash, preventing unreleased lock deadlocks without process-bottlenecked state evaluation.

**Verification Gate**: Micro-benchmarks must show lock acquisition and release overhead of ≤ 5 µs per transaction.

#### AR-DATA-04: Dynamic Supervisor Pool Sizing

**Problem Statement**: Worker pool exhaustion under unexpected burst traffic causes message queuing, while static over-provisioning wastes host memory.

**Architectural Specification**: Worker pools in the ingestion pipelines must be governed by PartitionSupervisor with runtime capacity management via `PartitionSupervisor.resize!/2`. Dynamic load detectors monitor worker reduction load and scale partition processes up to configured ceilings without dropping connections or restarting supervision trees.

### 2.3 Wire Protocol Engines & Data Serialization

#### AR-WIRE-01: Native Zero-Copy Streaming JSON Processing

**Problem Statement**: Interacting with Azure ARM management endpoints, Cosmos DB document APIs, and Key Vault REST interfaces requires high-frequency JSON encoding and decoding. Relying on external pure-Elixir parsers wastes memory, while C-based NIF parsers introduce VM crash risks and cross-compilation friction.

**Architectural Specification**: All JSON processing must use the native standard-library `json` / `JSON` engine. Large payloads (such as Cosmos DB batch queries and bulk document ingests) must be ingested via SAX-style streaming interfaces (`json:decode/3`), parsing incoming TCP binary chunks without allocating the entire term tree in memory.

**Verification Gate**: Ingestion throughput of a 50 MB JSON document stream must run with peak heap allocations constrained to ≤ 2 MB, yielding a ≥ 40% reduction in allocation churn compared to external pure-Elixir libraries.

#### AR-WIRE-02: Single-Opcode Protocol Bounds Validation

**Problem Statement**: Wire protocol handlers must validate incoming numerical fields (such as HTTP Content-Length, Cosmos DB RU limits, and byte range parameters) against protocol specifications, often generating complex multi-clause guard logic.

**Architectural Specification**: All numerical parameter validators across protocol boundaries must use the `is_integer/3` guard BIF (e.g., `when is_integer(content_length, 0, 104_857_600)`). The compiler translates this into a single, optimized VM range-check instruction, rejecting out-of-spec requests directly in the function head before allocating intermediate binary payloads.

#### AR-WIRE-03: Fail-Closed Comprehensions & Pattern Matching

**Problem Statement**: Relaxed list comprehensions drop malformed or unrecognized terms silently, risking corrupted internal states in API transformation layers.

**Architectural Specification**: Data transformations translating incoming SDK requests into substrate terms must utilize strict generators (`<-:-`). If a payload segment deviates from required schema invariants, the comprehension must fail immediately with a badmatch exception, routing to typed HTTP 400 responses. Mid-comprehension variable assignments must use `compr_assign` to avoid redundant function calls.

### 2.4 Cryptographic Infrastructure & Transport Security

#### AR-SEC-01: Native Post-Quantum Hybrid Transport Security

**Problem Statement**: Enterprise systems handling sensitive transactional data are vulnerable to "harvest-now, decrypt-later" adversarial attacks targeting classical public-key cryptography.

**Architectural Specification**: The core TLS listener plane (:9444, :8443) and AMQP over TLS listener (:5671) must operate on Erlang/OTP 29 ssl, setting the hybrid post-quantum algorithm `x25519mlkem768` (pairing classical X25519 with the ML-KEM-768 lattice-based key encapsulation mechanism) as the default preferred key exchange group. Outbound mutual TLS connections to upstream enterprise datastores must prioritize `x25519mlkem768` while maintaining fallback compatibility.

**Verification Gate**: Handshakes initiated by modern SDK clients must negotiate `x25519mlkem768` key exchange by default, confirmed via TLS socket property inspections.

#### AR-SEC-02: Dual-Certificate Cryptographic Selection

**Problem Statement**: Supporting legacy enterprise clients requiring RSA certificates alongside modern clients requiring high-performance ECDSA certificates historically required multiple port bindings.

**Architectural Specification**: TLS listeners must configure the `{certs_keys, ...}` option, binding both ECDSA (P-256/P-384) and RSA certificate-key pairs to a single socket endpoint. The TLS stack automatically negotiates and selects the optimal cipher suite based on client capabilities.

#### AR-SEC-03: SSRF-Hardened Revocation Checking

**Problem Statement**: In-memory cloud emulators running inside enterprise boundaries risk Server-Side Request Forgery (SSRF) vulnerabilities if Certificate Revocation List (CRL) validation allows arbitrary outbound HTTP requests.

**Architectural Specification**: Outbound CRL validation must configure the `allowed_hosts` restriction, strictly forbidding connections to loopback interfaces, link-local addresses, and private IP blocks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.169.254).

### 2.5 Workflow Execution & Orchestration Subsystem (POWL 2.0)

#### AR-POWL-01: Native Record Structural Guarantees (EEP 79)

**Problem Statement**: The POWL 2.0 compiler transforms complex Petri nets into PartialOrder and ChoiceGraph structures. Traditional Erlang records compile to plain tagged tuples, allowing accidental pattern matches against untyped tuples and permitting structural corruption during compilation passes.

**Architectural Specification**: All workflow AST nodes (Transition, PartialOrder, ChoiceGraph, LoopGraph) must be declared and compiled as Native Records according to EEP 79. Native records exist as a distinct, first-class runtime data type, enforcing strict type checks at the VM level and preventing invalid structural updates across transformation passes.

**Verification Gate**: Dialyzer and runtime checks must enforce native record identity, rejecting plain tuple substitutions across all compiler stages.

#### AR-POWL-02: Deterministic Receipt Hashing via Map Traversal Guarantees

**Problem Statement**: The workflow audit engine generates P-PLAN and PROV-O cryptographic audit receipts via Merkle tree hashing. Non-deterministic map iteration order across different BEAM versions or node instances requires manual key-sorting passes before hashing, adding CPU overhead.

**Architectural Specification**: Merkle DAG hash generators must leverage Erlang/OTP 29's deterministic map iteration order. Key-value serialization for cryptographic digests must stream directly through `maps:fold/3` without intermediate list sorting, producing identical canonical digests across runs.

**Verification Gate**: Merkle root hashes for 100,000 generated execution plans must prove byte-identical across disparate platforms and architectures.

#### AR-POWL-03: Functional Graph Decomposition

**Problem Statement**: Workflow net normalization and marked-graph decomposition previously relied on mutable ETS-based digraph structures, requiring explicit process-bound resource teardowns.

**Architectural Specification**: Petri net validation and cycle-detection algorithms must execute via the purely functional graph module introduced in OTP 29 STDLIB. The compiler passes graph terms immutably across pipeline phases, eliminating table lifecycle overhead and simplifying parallel branch evaluation.

### 2.6 Verification, Observability & Testing Architecture

#### AR-OBS-01: Multi-Session Isolated Dynamic Tracing

**Problem Statement**: Verification suites executing automated test courts concurrently with background telemetry monitors previously experienced tracer collisions; setting global trace flags in one test invalidated active traces in another.

**Architectural Specification**: All dynamic telemetry assertions, test court inspectors, and zero-egress verifiers must initialize isolated trace sessions via `trace:session_create/3` and `trace:system/3`. Each session must maintain independent tracer processes, match specifications, and flag filters, allowing multiple test suites to trace identical functions concurrently without cross-talk or silent event drops.

**Verification Gate**: Concurrent execution of 20 parallel test courts tracing `Smalt.EgressRouter` must record 100% of matching trace events with zero dropped frames.

#### AR-OBS-02: Structured Process Identity Tracking

**Problem Statement**: In high-density testbeds running thousands of concurrent actors, crash dumps and diagnostic logs displaying anonymous process identifiers (`<0.1234.0>`) complicate troubleshooting.

**Architectural Specification**: Every process spawned within the substrate—including HTTP connection handlers, AMQP link actors, Cosmos partition arbiters, and background timers—must set structured semantic metadata using `proc_lib:set_label/1` (Erlang) or `Process.set_label/1` (Elixir). Labels must follow a structured schema: `%{service: :cosmos, role: :partition_writer, partition_key: "tenant-01", correlation_id: "req-9876"}`.

**Verification Gate**: Crash reports generated by abnormal process terminations must render the structured label dictionary in formatted log outputs.

#### AR-OBS-03: Call-Memory Heap Profiling & Regression Fences

**Problem Statement**: Latency regression fences often miss hidden memory leaks and excessive heap churn that later degrade throughput in production under sustained load.

**Architectural Specification**: Automated performance testbeds must execute against `tprof` configured with `#{type => call_memory}`. Test harnesses must measure the exact word volume allocated by individual functions per transaction, setting strict heap allocation ceilings in CI gates to catch memory regressions before merge.

**Verification Gate**: Any pull request introducing a > 5% increase in heap words allocated per transaction must fail the automated CI build.

#### AR-OBS-04: Deterministic Multi-Node Cluster Orchestration

**Problem Statement**: Testing distributed leader failover, partition recovery, and multi-node replication previously relied on brittle shell scripts or the deprecated slave module.

**Architectural Specification**: Multi-node verification testbeds must exclusively use the `peer` module. Ephemeral BEAM nodes must be linked to the originating test runner with deterministic lifecycle management, ensuring immediate peer process termination if the test runner halts. Cluster tests must inject network disconnects and simulate partition boundaries using standard distribution control APIs.

## 3. Product Requirements Document (PRD)

### 3.1 Azure PaaS Service Displacement Specifications

```
+------------------------------------------------------------------------------------------------------------------------------------+
|                                          Smalt v26.10.21 Enterprise Capability Matrix                                               |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure PaaS Meter     | Microsoft Azure Architectural Limits               | Smalt v26.10.21 Substrate Parity Implementation         |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure Storage Blob   | Multi-second container deletes; XML error contract | Non-WORM deletion returning 202 Accepted; canonical XML |
|                      | mandatory; staged blocks require chunk validation. | error serializers (<Error><Code>...</Code></Error>).    |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure Cosmos DB      | 10,000 RU/s and 50 GB partition limits; 429 backoff| Memory CAS arbitration; quoted-GUID _etag matching;     |
|                      | loops; expensive multi-master provisioned tiers.   | system property stripping (_gen/_v); 50k RU/s burst     |
|                      |                                                    | absorbed.                                               |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure Service Bus &  | $677/MU/month baseline; strict AMQP link limits;   | Wire AMQP 1.0 broker; 44-byte SAS auth; spec-compliant  |
| Azure Event Hubs     | unpersisted SQL filter rules on child PUTs.        | map32 decoding; 204 No Content management deletion.     |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure API Management | $2,795/month baseline; 16-25 ms policy latency;    | In-process policy pipeline; sub-millisecond rate        |
| (APIM) Premium       | 20-minute autoscale provisioning delays.           | limits; local JWT rewrites; zero external egress.       |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure Key Vault      | 2,000-4,000 ops/10s rate limits; expensive Managed | In-memory cryptographic actors; hardware-derived        |
| Managed HSM          | HSM pools ($3.20/hour baseline).                   | tokens; compliant HTTP 201 creation responses and URI   |
|                      |                                                    | formatting.                                             |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
| Azure App            | Enterprise subscription fees; high-frequency       | ETS-backed in-memory feature flag resolution; dynamic   |
| Configuration        | polling egress; Private Link configuration costs.  | trial protocol lookups in < 1 ms.                       |
+----------------------+----------------------------------------------------+--------------------------------------------------------+
```

#### PRD-BLOB: Azure Storage Blob & Data Lake Wire Parity

**Scope**: Emulation of the Azure Storage Blob REST API (versions 2021-12-02 through 2026-10-06) across plaintext (:8443) and TLS (:9444) endpoints.

**Functional Requirements**:

1. Implement full Put Block (`comp=block`), Put Block List (`comp=blocklist`), and Get Blob pipelines, supporting parallel multi-part block staging with byte-exact MD5/CRC64 verification.
2. Resolve KD-135: Standard containers must support deletion, returning HTTP 202 Accepted byte-identical to live Azure Storage. WORM immutability policies must remain strictly scoped to explicitly locked containers.
3. Resolve KD-137: HTTP 416 Range Not Satisfiable responses must serialize Azure-compliant XML error bodies (`<Error><Code>InvalidRange</Code>...</Error>`) and inject the `x-ms-error-code: InvalidRange` response header.
4. Resolve KD-139: Missing `x-ms-blob-type: BlockBlob` headers on block PUT requests must fail with HTTP 400 MissingRequiredHeader.
5. Ensure all 4xx/5xx error responses emit `Content-Type: application/xml`, `x-ms-request-id`, `x-ms-version`, and `x-ms-error-code` headers matching Microsoft REST specifications.

#### PRD-COSMOS: Azure Cosmos DB Core/SQL Plane

**Scope**: Emulation of the Azure Cosmos DB REST gateway and document execution plane.

**Functional Requirements**:

1. Emulate multi-master partition write pools, absorbing bursts equivalent to 50,000 provisioned RU/s without throwing HTTP 429 throttling errors.
2. Resolve KD-147: Strip internal substrate operational metadata (`_gen`, `_v`) from wire payloads, presenting clean Azure-compatible document bodies.
3. Resolve KD-148: Enforce quoted-GUID formatting for `_etag` headers. Atomic Compare-And-Swap (CAS) updates must match incoming If-Match values against this format, returning HTTP 412 Precondition Failed on mismatches.
4. Implement Cosmos DB parameterised SQL query evaluations in-memory, returning single-partition and cross-partition result sets with appropriate continuation tokens.

#### PRD-SB: Azure Service Bus & Event Hubs Messaging Plane

**Scope**: Emulation of AMQP 1.0 broker routing and ATOM/ARM management planes (:5671, :5672, :5300).

**Functional Requirements**:

1. Provide native AMQP 1.0 message transfer supporting broker settlement, direct queue point-to-point delivery, and multi-cast topic fan-out.
2. Resolve KD-131: Support CBS (Claims-Based Security) token authentication using real-world 44-byte derived keys, enforcing SAS validation matching live Azure requirements.
3. Resolve KD-132: Enforce AMQP 1.0 PrimitiveCodec map32 decoding in strict conformance with specification section 1.8, preserving connection lifecycles when malformed payloads are rejected.
4. Resolve KD-143: Persist `sqlFilter.sqlExpression` rule parameters across ARM and ATOM PUT/GET operations, evaluating filter expressions against incoming message application properties during topic distribution.
5. Resolve KD-155: Fix management plane HTTP method dispatch; DELETE /:queue or DELETE /:topic operations must return HTTP 204 No Content without leaking AMQP error frames.

#### PRD-APIM: API Management (APIM) Policy Gateway

**Scope**: High-performance, in-process API gateway evaluating enterprise policies locally.

**Functional Requirements**:

1. Execute rate-limiting counters, mutual TLS verification, header transforms, and JWT validation in-process.
2. Replace the $2,795 per month APIM Premium gateway with zero-network, sub-millisecond local policy execution.
3. Ensure complete compatibility with Next.js and Popcorn frontend applications via browser-local WebAssembly bindings, eliminating CORS preflight overhead and public network exposure.

#### PRD-KV: Key Vault & Managed HSM Plane

**Scope**: Emulation of the Key Vault secret management and cryptographic signing plane.

**Functional Requirements**:

1. Resolve KD-149: Secret creation via PUT must return HTTP 201 Created.
2. Resolve KD-150: Return secret identifier URIs matching Azure format: `https://{vault}.vault.azure.net/secrets/{name}/{guid}`.
3. Resolve KD-151: Reject unsupported future API versions with HTTP 400 Bad Request.
4. Implement local cryptographic operations (sign, verify, encrypt, decrypt) using hardware-derived keys, supporting RS256 and ES256 algorithms without external HSM hardware fees.

#### PRD-APPCONF: App Configuration Engine

**Scope**: Emulation of the Azure App Configuration enterprise plane.

**Functional Requirements**:

1. Provide sub-millisecond feature flag evaluations and key-value retrievals backed by read-concurrent ETS tables.
2. Support label-based configuration slicing and real-time push notifications over WebSocket connections, eliminating cloud polling costs.

### 3.2 Sovereign Migration Tooling (smalt-migrate)

smalt-migrate is an automated, non-destructive extraction and displacement CLI tool implemented using Typer. It extracts cloud dependencies from existing Infrastructure-as-Code (IaC) definitions and re-points client connection strings to the local Smalt substrate.

```
+------------------------------------------------------------------------------------+
|                         smalt-migrate Operational Pipeline                          |
|                                                                                     |
|  [ Step 1: Scan ]      Parse Terraform, Bicep, ARM JSON; extract PaaS topology      |
|         |                                                                           |
|         v                                                                           |
|  [ Step 2: Generate ]  Compile deterministic smalt.manifest.json & seed datasets    |
|         |                                                                           |
|         v                                                                           |
|  [ Step 3: Inject ]    Create .env.smalt loopback strings; back up originals (.bak) |
|         |                                                                           |
|         v                                                                           |
|  [ Step 4: Verify ]    Execute live wire assertions across Blob, Cosmos, KV, SB     |
|         |                                                                           |
|         v                                                                           |
|  [ Step 5: Ledger ]    Emit byte-exact savings ledger & zero-egress audit proof     |
+------------------------------------------------------------------------------------+
```

**Functional Requirements**:

1. **Trilingual IaC Parser**: Inspect and parse Terraform HCL (`.tf`), Azure Bicep (`.bicep`), and compiled ARM JSON (`.json`) templates without executing cloud provider plugins. Map discovered cloud resources into an intermediate representation covering Storage Accounts, Cosmos DB Accounts, Service Bus Namespaces, Key Vaults, and APIM Instances.
2. **Deterministic Manifest Compilation (generate)**: Compile extracted topology into `smalt.manifest.json`. Enforce byte-identical determinism: identical IaC input files must yield identical manifest outputs, omitting non-deterministic timestamp keys.
3. **Environment Injection & Rollback (inject / rollback)**: Generate `.env.smalt` containing connection strings repointed to 127.0.0.1 or the local WASM bridge. Provide an atomic rollback command that restores original `.env` files from `.bak` snapshots.
4. **Wire Gate Verification (verify)**: Connect to the local Smalt node using official Microsoft client SDKs. Execute non-vacuous operational checks: Blob Put/Get, Cosmos CAS ETag match/mismatch, Key Vault secret put/get, and Service Bus message send/receive. Assert zero external network egress during verification; non-loopback network calls must raise `NonLoopbackEgressError`.
5. **Continuous Pipeline Execution (all)**: Provide a single pipeline command (`smalt-migrate all --iac-path ./infra`) executing scan, generate, inject, and verify steps sequentially, completing analysis of a 50-resource topology in ≤ 5 seconds.

### 3.3 Non-Functional Requirements (NFRs) & Performance Ceilings

- **NFR-CONCURRENCY (L8192 Threshold Wall)**: The substrate must support up to 4,096 concurrent actor transactions with zero server-side 5xx errors and sub-linear latency scaling. Gracefully handle load up to 8,192 concurrent requests; saturation beyond capacity must result in typed backpressure rather than memory collapse.
- **NFR-LATENCY (Sub-Millisecond Point Operations)**: In-memory point operations must meet strict latency targets: Key Vault secret retrieval P50 ≤ 600 µs, P99 ≤ 2 ms; Cosmos DB document point-read P50 ≤ 800 µs, P99 ≤ 3 ms; Storage Blob 1 KiB block upload P50 ≤ 1.5 ms, P99 ≤ 4 ms.
- **NFR-FOOTPRINT (Lightweight Sovereign Deployment)**: Cold start to operational readiness ≤ 500 ms. Baseline memory footprint at idle ≤ 60 MB. Execution support across Linux (x86_64, aarch64), macOS (Apple Silicon), and standard browser runtimes via WebAssembly.
- **NFR-COMPLIANCE (Wire Parity Authority)**: The official Microsoft client SDKs (`@azure/storage-blob`, `@azure/cosmos`, `@azure/service-bus`, `@azure/keyvault-secrets`) are the definitive behavioural specification. Local emulators (e.g., Azurite) are treated as secondary; if an emulator diverges from the official SDK wire protocol, the SDK behavior is authoritative.

### 3.4 Competitive Superiority Matrix: Smalt v26.10.21 vs. Microsoft Azure Enterprise PaaS

| Dimension / Capability | Microsoft Azure Enterprise PaaS Tier | Smalt v26.10.21 Sovereign Substrate | Direct Operational Advantage |
|---|---|---|---|
| Billing Model | Provisioned capacity reservations + metered micro-transactions | Zero infrastructure cost; sovereign local silicon execution | Eliminates ~$2,955/year baseline per 50-resource dev/test topology |
| Throttling & 429 Errors | Artificial token buckets; HTTP 429 throttling; 30-second backoff loops | Bounded strictly by hardware memory and scheduler reductions | Zero artificial throttling; deterministic sub-millisecond execution |
| Storage Error Handling | Strict XML `<Error><Code>...</Code></Error>` and `x-ms-error-code` headers | Exact wire-level XML error serialization and header injection | Full compatibility with @azure/storage-blob exception handlers |
| Container Delete Semantics | Returns HTTP 202 Accepted; container purges asynchronously | Standard containers return HTTP 202; WORM scoped to locked stores | Eliminates 409 lock conflicts during rapid test teardowns |
| Cosmos DB Partitioning | Hard 10,000 RU/s and 50 GB limits; multi-hour partition splits | In-memory dynamic ETS tables; atomic Compare-And-Swap on GUID etags | Absorbs 50k RU/s bursts in-memory with zero partitioning delays |
| Service Bus Management | ATOM/ARM plane returns HTTP 204 on delete; strict rule persistence | Method sniff routes HTTP 204 on delete; persists sqlFilter expressions | Unblocks first-party administration clients (ServiceBusAdminClient) |
| APIM Policy Latency | 16–25 ms remote gateway hops; $2,795/month unit baseline | In-process plug routing; local JWT rewrite; P95 ≈ 10 µs | 3 orders of magnitude lower latency; zero remote infrastructure fees |
| Key Vault Cryptography | 2,000–4,000 ops/10s rate limits; $3.20/hour Managed HSM fee | Local hardware-derived cryptographic tokens (RS256/ES256); zero fees | High-frequency signing without cloud rate-limit exhaustion |
| Transport Security | Classical TLS 1.2/1.3; vulnerable to harvest-now, decrypt-later | Default hybrid post-quantum key exchange (x25519mlkem768) | Future-proof quantum resistance out of the box |
| Developer Feedback Loop | 15–20 minute CI deployment and staging pipeline cycles | Sub-second test execution; deterministic zero-egress validation | Shortens feedback loops; accelerates developer velocity |

## 4. Implementation & Migration Roadmap

> **Phase-2 capability corrections (VAL-DATA probe, 2026-10-21 — see `receipts/val-ar-data.md`):**
> (1) `PartitionSupervisor.resize!/2` refuses to grow past the configured `partitions:` count ("must be between 0 and N") and **returns the previous count**, not `:ok` — elasticity must be modeled boot-at-max/shrink-on-idle, and callers must match on the integer return. (2) The traversal primitive is `ets:next_lookup/2` (not /1), **ordered_set-only** (badargs on `set` tables), and past-end returns the bare atom `:'$end_of_table'`. (3) `ets:update_element/4`'s atomic insert-or-update form is `(Tab, Key, ElementSpec, DefaultTuple)` — the `(Tab, Key, Pos, NewValue)` arity is badarg. (4) `{write_concurrency, :auto}`, `{decentralized_counters, true}`, `Registry.lock/3` are all **available on the pinned host toolchain** — Phase-2 is an adoption work order, not an upgrade gate. All four APIs verified by executed probe, not documentation.

```
+-----------------------------------------------------------------------------------------+
|                              Implementation Phasing Roadmap                              |
|                                                                                          |
|  [ Phase 1: Core Substrate Engine Upgrade ]                                               |
|   * Processes iterator (O(1) memory sweeps)                                               |
|   * EEP 76 priority mailbox signaling                                                     |
|   * JIT multi-segment binary matching                                                     |
|                                                                                           |
|  [ Phase 2: Shared Memory & Concurrency Hardening ]                                       |
|   * Dynamic ETS {write_concurrency, auto} & decentralized counters                        |
|   * Atomic traversal via ets:next_lookup/1 & ets:update_element/4                         |
|   * In-process locking via Registry.lock/3 & PartitionSupervisor.resize!/2                |
|                                                                                           |
|  [ Phase 3: Protocol, Serialization & Cryptographic Compliance ]                          |
|   * Native streaming JSON migration (55% faster string decoding)                          |
|   * Single-opcode range guards (is_integer/3) & strict comprehensions                     |
|   * Post-quantum TLS defaults (x25519mlkem768) & dual certs_keys                          |
|                                                                                           |
|  [ Phase 4: POWL 2.0 Native Compilation & Verification Framework ]                        |
|   * EEP 79 Native Records for compiler ASTs                                               |
|   * Deterministic map traversal Merkle receipt hashing                                    |
|   * Isolated multi-session tracing (trace:session_create/3)                               |
|                                                                                           |
|  [ Phase 5: Production Readiness & Enterprise Validation ]                                |
|   * Full smalt-migrate trilingual IaC integration (TF, Bicep, ARM JSON)                   |
|   * Complete KD-01..157 divergence verification; final receipt sealing                    |
+-----------------------------------------------------------------------------------------+
```

**Phase 1: Core Substrate Engine Upgrade** — Upgrade Erlang/OTP base to OTP 29 and Elixir base to v1.20. Refactor node monitors and connection censuses to use `erlang:processes_iterator/0` and `process_next/1`, establishing O(1) memory consumption across background maintenance loops. Implement EEP 76 priority message aliases across core supervisor and partition coordinator loops, ensuring prioritized delivery for administrative and drain commands under mailbox load. Recompile protocol parsers with the OTP 29 BEAM JIT to exploit multi-segment binary optimizations for AMQP 1.0 and HTTP/2 framing.

**Phase 2: Shared Memory & Concurrency Hardening** — Configure all internal storage and queue ETS tables with `{write_concurrency, auto}` and `{read_concurrency, true}`, enabling dynamic lock adaptation and decentralized cache-line counters. Migrate table traversal loops and rate-limiting counters to `ets:next_lookup/1` and `ets:update_element/4`, eliminating table-locking overhead and multi-step race conditions. Replace singleton GenServer coordination locks on document and entity updates with `Registry.lock/3`. Integrate `PartitionSupervisor.resize!/2` within ingestion worker pools to support dynamic partition adjustments during traffic spikes.

**Phase 3: Protocol, Serialization & Cryptographic Compliance** — Replace external JSON parsers with the native standard-library `json` / `JSON` module, adopting SAX streaming (`json:decode/3`) for multi-megabyte payloads. Implement `is_integer/3` guard validations across all HTTP and AMQP parameter handling routines. Enable post-quantum hybrid key exchange (`x25519mlkem768`) as the default on TLS listeners (:9444, :8443) and AMQPS listeners (:5671). Configure `{certs_keys, ...}` on all endpoints to support concurrent ECDSA and RSA certificates.

**Phase 4: POWL 2.0 Native Compilation & Verification Framework** — Re-implement `Smalt.POWL2` AST structs (PartialOrder, ChoiceGraph, Transition) using EEP 79 Native Records, establishing runtime type enforcement at the VM boundary. Refactor P-PLAN and PROV-O Merkle DAG digest engines to take advantage of deterministic map iteration order in Erlang/OTP 29, eliminating manual key sorting. Transition automated test courts and regression harnesses to isolated trace sessions using `trace:session_create/3` and `trace:system/3`. Enforce memory allocation ceilings in CI using `tprof` with `#{type => call_memory}` profiling.

**Phase 5: Production Readiness & Enterprise Validation** — Validate the smalt-migrate CLI against enterprise IaC estates (Terraform, Bicep, ARM JSON), confirming deterministic manifest compilation and automated `.env.smalt` loopback repointing. Execute the dual-backend differential test suite against live Azure and official client SDKs (`@azure/storage-blob`, `@azure/cosmos`, `@azure/service-bus`, `@azure/keyvault-secrets`), confirming that all rows in the Known Divergences register (KD-01..157) are reconciled and receipt-sealed. Release the Smalt v26.10.21 container images, WebAssembly artifacts, and CLI binaries to enterprise staging environments.

## See Also

- `docs/jira/v26.10.20/DFLSS-CHARTER.md` — DFLSS project charter with measured CTQ standings
- `docs/jira/v26.10.20/FINAL.md` — prior window wrap (SCVD wave, smalt-migrate wave 1, KD scoreboard)
- `docs/jira/v26.10.20/POWL2.md` — POWL 2.0 wave status and skeptic findings
- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical KD register (table is ground truth)
