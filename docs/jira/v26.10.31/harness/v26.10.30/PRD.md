# Product Requirements Document
## Title: Next.js Application Test Harness & Verification Suite for the Smalt Local Substrate

Status: Ready for Review
Target Environment: Local macOS / Linux developer workstations (kind, local loopback, offline-first)
Requirements Context: Anonymized enterprise case study — multi-tenant legal-technology platform,
SOC 2 compliance baseline, client-matter isolation, CRMH audit exports, SIEM matter attribution.

---

## 1. Executive Summary & Purpose

This PRD defines the test architecture, acceptance criteria, and verification methodology for
Next.js web applications executing against the local Smalt substrate rather than live cloud
services.

Historically, frontend and full-stack integration suites either depend on brittle mock service
workers (which fail to capture true API-version dynamics, authentication envelopes, and
wire-level protocol behavior) or connect to live cloud environments (which introduce billing
costs, non-deterministic network latency, and multi-tenant test contamination).

This harness establishes Chicago-style (classical, state-based) automated testing: every test
asserts against real HTTP wire exchanges, cryptographic receipts, and strict error states,
confirming the application functions with wire parity before any deployment to production
infrastructure. The motivating production context is an anonymized enterprise deployment:
per-matter infrastructure isolation, consolidated container workloads, compliance-mandated
audit exports with retention policy, and security telemetry with matter-level attribution.

## 2. Product Objectives & Success Metrics

### Core Objectives

- True wire-parity testing: full-lifecycle frontend and server-side workflows against local
  loopback endpoints with zero cloud connectivity.
- Deterministic verification: identical input sequences produce identical cryptographic
  receipts; zero test flakiness; no timing side-channels.
- Immediate defect isolation: mechanical, fail-closed assertions — protocol drift, missing
  permissions, or invalid API versions halt execution with actionable diagnostics.
- Zero cloud development cost: multi-tenant case creation, document processing, and
  infrastructure triggers validate entirely offline.

### Key Performance Indicators

| KPI | Target |
|---|---|
| Full-suite execution time | < 45 seconds on a standard engineering laptop |
| Zero-mock policy | 0% of control-plane/data-plane exchanges mocked; 100% against the live loopback substrate |
| Flake rate | 0 flaky runs across 1,000 continuous loops |
| Mutation kill rate | > 90% when requests or headers are deliberately inverted |

## 3. Scope & System Context

The application under test interacts with the local substrate through two layers:

1. Client-side React components: browser interactions — authentication, administrative forms,
   document segmentation dashboards, status displays.
2. Server-side runtime (Node.js/Edge): server actions and route handlers using cloud SDKs
   configured with loopback endpoints — infrastructure provisioning, secret retrieval, audit
   telemetry, blob lifecycle management.

The substrate exposes a local control-plane face (loopback), an admission gate stamping every
state mutation with a cryptographic receipt, role-based admission, and data-plane engines for
blob storage, container workloads, and secrets.

## 4. Functional Test Domains

### Domain 1 — Tenant & Case Infrastructure Provisioning

Context: case managers request a new matter via the administrative interface; the server
runtime provisions dedicated resource boundaries. (Case-study origin: per-matter resource and
network isolation replacing shared, hardcoded deployments.)

- TC-TENANT-001 Isolated Tenant Boundary Creation: a valid "create case" submission issues a
  provisioning command; substrate state reflects a dedicated, non-overlapping resource group
  and isolated network boundary; subsequent inspection confirms the resource with
  tenant-tagged metadata.
- TC-TENANT-002 Anti-Spillover Boundary Rejection: a cross-tenant operation (Case A writing
  into Case B's network) is refused mechanically (403-class); the UI renders a boundary error;
  no state mutates. Honest-scope note: if the substrate currently admits the operation, the
  suite records the observed behavior as a registered divergence — never a fabricated refusal.
- TC-TENANT-003 Backend State Preservation: a provisioning request with empty or stripped
  state is refused fail-closed; the UI surfaces a critical deployment error.

### Domain 2 — Container Consolidation & Unified App Management

Context: frontend and backend workloads consolidate into a single container-app instance per
administrative unit (case-study origin: consolidation decision replacing split instances).

- TC-CONTAINER-001 Consolidated Instance Deployment: exactly one active container-app
  instance containing two co-located container definitions (frontend gateway, backend worker)
  sharing loopback networking.
- TC-CONTAINER-002 Health Probe Response Handling: status pollers receive complete, non-nil
  payloads for both roles; the UI renders healthy andon badges.

### Domain 3 — Key Vault Secret Retrieval & Lifecycle

- TC-VAULT-001 Disjunctive Secret Value Retrieval: a secret request succeeds (200) and the
  application handles the value whether delivered directly or inside property envelopes —
  both branches asserted, never one.
- TC-VAULT-002 Nonexistent Secret Fail-Closed: an unprovisioned secret returns 404
  ResourceNotFound; the application logs an actionable missing-dependency error and aborts
  safely without crashing the worker.
- TC-VAULT-003 Receipt Header Verification: every state-modifying vault operation returns the
  cryptographic receipt header matching the expected digest format.

### Domain 4 — Compliance Reporting & Audit Ingestion (CRMH Pipeline)

Context: daily compliance exports (CRMH) land in blob storage for enterprise data-pipeline
ingestion, under a mandatory 14-day retention rule and a canonical naming schema.

- TC-CRMH-001 Export Payload Format & Naming: exports write to paths strictly conforming to
  `crmh/daily-exports/{tenantId}/{timestamp}.json`; stored payloads pass structural JSON
  validation. The naming/schema law is testable substrate-independently; the wire-write leg
  skips loudly and typed if the storage face is unreachable.
- TC-CRMH-002 14-Day Lifecycle Policy: the storage account's active management policy
  enforces deletion of block blobs older than exactly 14 days; the compliance dashboard
  reports the rule active. If the substrate lacks the policy route, the test registers the
  gap loudly.

### Domain 5 — SIEM Audit Telemetry & Matter Attribution

Context: sensitive operations (document upload, transcript segmentation, juror score
matching) emit audited telemetry into managed event streams with strict matter attribution.

- TC-SIEM-001 Audited Event Dispatch: an audit event carries both the matter/case identifier
  and the cryptographic receipt identifier; the receipt equals the one stamped on the
  triggering mutation.
- TC-SIEM-002 Partition Verification: drained events arrive in strict chronological order
  with zero payload mutation or stripped matter headers. Full stream-drain legs skip loudly
  if the event transport is not exposed locally; the ordering law is still asserted on the
  application-side event builder.

### Domain 6 — API Version Compatibility & Wire Ceilings

- TC-VER-001 Admitted Version Roundtrip: requests at approved api-versions (e.g. the
  registry ceiling) process normally (200/201) across at least four resource families.
- TC-VER-002 Out-of-Ceiling Refusal: future-version requests are rejected with a typed
  InvalidApiVersionParameter; the application's logging captures the rejected version and
  renders a remediation instruction (pin to the latest supported).

### Domain 7 — Terminal UX, Jidoka Line Stops & Error Ergonomics

- TC-UX-001 Timeout & SLA Enforcement: a backend query exceeding the client SLA window
  terminates at the boundary with a typed timeout error; the worker process survives.
- TC-UX-002 Actionable Diagnostic Rendering: an operation failing on missing role assignment
  renders a structured diagnostic: the specific missing permission, the affected resource
  URI, and the exact corrective action. Where the substrate's refusal body lacks dedicated
  fields, the diagnostic declares the enrichment gap explicitly rather than fabricating.

### Domain 8 (Extension) — Ground-Truth Evaluation Runs

Context (case-study origin): case-level evaluation containers run scoring functions against
human ground-truth data, producing 1–7 scale performance reports for juror-matching analysis.

- TC-EVAL-001 Scored Run Persistence: an evaluation run persists its scored results with
  matter attribution and a receipt per state transition.
- TC-EVAL-002 Report Determinism: identical input data yields identical score reports
  (byte-stable), with the receipt chain verifiable end-to-end.

## 5. Non-Functional Requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-PERF-01 | Loopback latency ceiling for non-cryptographic metadata roundtrips | < 15 ms (p99) |
| NFR-HERMETIC-01 | Total network isolation; public-cloud-bound attempts fail immediately and typed | Fail-fast < 5 s |
| NFR-CLEANUP-01 | State determinism: isolated state per run or full cleanup; 0 unmanaged containers/blobs | Residue = 0 |
| NFR-CONCURRENCY-01 | Parallel workers without port locks or resource races | 20 parallel flows, 0 conflicts |

## 6. Execution Lifecycle & Phase Gates

Three-stage gating model:

STAGE 1 PRE — doctor preflight (loopback listeners active, no stale port occupants with
conflicting PIDs named), api-version pin and environment verification.
STAGE 2 LIVE — the seven (or eight, with the extension) functional domains, sequentially or
across isolated worker namespaces, with concurrent negative-branch mutation evaluation.
STAGE 3 POST — substrate zero-drift verification; receipt-ledger completeness check
(every receipt from the run is journaled); ephemeral purge preserving persistent
configuration invariants.

## 7. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Silent API drift | SDK header variations break local parsing | Strict schema validation at all ingress points; compat-pin checks before every suite |
| Port/loopback collisions | Local processes conflict with the harness | Preflight collision detection naming the conflicting PID |
| False-positive assertions | Tests pass without validating real data | Mandatory negative-branch mutation testing: every passing test has an inverted-input proof |
| Secret deserialization mismatch | Secret format variance breaks parsing | Disjunctive flat-string and nested-envelope branches asserted in the vault domain |
| Refusal-body ergonomics gaps | Diagnostics can't render what the substrate doesn't say | Enrichment gaps declared explicitly; substrate ergonomics gaps registered upstream, never fabricated |

## 8. Acceptance

The harness is accepted when: all domain suites pass on the live local substrate under the
KPI targets; the mutation court demonstrates >90% kill; the flake loop demonstrates 0 drift;
and the post-stage gate certifies residue 0 with a complete receipt ledger — each claim
backed by a recorded, re-runnable gate rather than narrative.
