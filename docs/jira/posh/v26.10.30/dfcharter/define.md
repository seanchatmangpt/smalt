# Define — POSH DfLSS DMADV Phase 1 Charter

Parent: `dfcharter/charter-master.md` (§1 problem/business case, §2 SPAF
boundary rules, §3 VOC/CTQ flowdown, §4 phase plan, §8 RACI). This document
elaborates the DEFINE gate: full scope, per-CTQ falsifiers and measurement
instruments, tollgate entry/exit criteria, SIPOC, and the working RACI. It
does not contradict the master; where a ticket (POSH-001..010) concretizes a
master clause, the ticket is cited as the instrument.

## 1. Charter Header

| Field | Value |
|---|---|
| Project | POSH (Port In, Starboard Out) — Sovereign Peripheral Membrane |
| Version | v26.10.30 |
| Methodology | DMADV; target ≥ 6σ (master §7) |
| Problem (master §1.1) | Symmetric I/O contention (p99 > 850 ms), config drift,
Go/BEAM impedance mismatch (brittle community adapters, GC cascades),
compliance/audit vacuum (unverified logs, PHI exposure) |
| Business case (master §1.2) | ≥ 90% cloud cost inversion via zero-PII Gold
egress; 0 DPMO compile-time synthesis from Turtle via ggen; 75% CPU/message
reduction via Port In ring buffer + Starboard zero-copy conduit |
| Tickets | POSH-001..010 (`docs/jira/posh/v26.10.30/`) |
| Dates | DEFINE opens 2026-10-30; phase weeks per master §4 (Phase 1: W1-2) |

## 2. Scope

### In scope (master §2 + tickets)

- Turtle DSL for `ingress/` and `egress/` topologies; ggen SPARQL CONSTRUCT
  synthesis of BEAM pipelines and Go adapters (master §2; POSH-001/002).
- Go peripheral membrane inside smalt: UDS/localhost JSON v1, gRPC v2
  (POSH-002), Azure ARM face via official SDKs (POSH-003).
- Terraform provider (HashiCorp plugin framework v6) via dev_overrides swap,
  consumer configs byte-unchanged (POSH-004).
- Packaging: erlang-port companion + k8s sidecar (POSH-005).
- Inline BLAKE3 SIMD Merkle receipts; Andon gates Build/Test/Lint/Invariant
  (master §2/§6; POSH-006 courts).
- Egress fences (POSH-008), SDK-parity register (POSH-009), migration ledger
  (POSH-007), wave fan-out plan (POSH-010).

### Out of scope

- ERTS/BEAM scheduler modification (master §2).
- Full native reimplementation of AWS/Azure/GCP service APIs.
- GUI/dashboard development.
- Non-standard proprietary wire protocols outside HTTP/gRPC/UDS.
- Business logic, storage, or scheduling inside the Go adapter (SPAF Rule 1;
  charter law 1/2) — violation, not exclusion.

### Boundary invariants (SPAF contract, master §2)

- Rule 1 (Go): stateless peripheral shims only (HF plugin v6, client-go);
  zero domain state, zero persistent databases.
- Rule 2 (BEAM): actors own state, supervision, turnstile routing; no raw
  hashing or byte-unpacking loops on actor heaps.
- Rule 3 (Rust): `#![no_std]` kernels, constant-time, CC = 1, zero heap.
- Charter falsifier: any vendor protocol detail absorbed into smalt `lib/`
  is a membrane violation (POSH-006 court pre-merge leg refuses it).

## 3. Voice of the Customer

Customers: operator/sponsor (Sean), smalt maintainers, consumer repo
courtroom-platform-az, CI fleet, compliance officer (master §3 row 3), edge
workloads (master §3 row 2). Master §3 VOC quoted verbatim below; ticket
VOC quoted from POSH-001..010.

| Customer | VOC (verbatim) | Source |
|---|---|---|
| DevOps/Platform | "work without rewriting infrastructure" | master §3 |
| Edge/Embedded | "cannot drop readings during cloud outages" | master §3 |
| Compliance | "audit-verifiable without leaking patient identifiers" | master §3 |
| Systems Eng | "No stop-the-world GC pauses" | master §3 |
| Operator | "posh never owns domain state" | charter law 1 |
| Operator | "no falsifier receipt does not land" | charter law 4 |
| Maintainers | "typed transport error ... never crash the caller" | POSH-002 |
| Maintainers | "fails healthz must fail pod readiness" | POSH-005 |
| Maintainers | "empty file -> posh must refuse to boot" | POSH-008 |
| courtroom-az | "consumer configs ... BYTE-UNCHANGED" | POSH-004 |
| courtroom-az | "stale/absent binary must FAIL LOUDLY at plan" | POSH-004 |
| CI fleet | "mutation shim FAILS the court" | POSH-006 |
| CI fleet | "removed face flips its cell to MISSING" | POSH-009 |
| CI fleet | "< 5ms overhead per call" | POSH-002 |

## 4. CTQ Matrix (elaborated from master §3)

Master gives metric + spec limits; this section adds instrument (which
court/receipt proves it) and falsifier per CTQ.

### CTQ-A Schema Parity & CLI Compatibility

- VOC: "work without rewriting infrastructure" (DevOps/Platform).
- Spec: 100% HCL schema match; dev_overrides exit code = 0.
- Instrument: POSH-004 parity court — plan/apply/destroy/zero-drift/residue
  ladder on kind; AST diff of HCL attributes vs generated provider schema.
- Tolerance: 0 schema deltas; zero-drift re-plan `-detailed-exitcode` = 0.
- Falsifier: any plan JSON byte-delta after the dev_overrides swap, or a
  stale/absent provider binary silently falling through to registry —
  either flips the court to FAIL.

### CTQ-B Intake Ingress Jitter (Port In)

- VOC: "cannot drop readings during cloud network outages" (Edge).
- Spec: jitter < 10 µs; frame drop rate 0.000%.
- Instrument: POSH-002 membrane timing receipt — ratio fence vs a
  sleep-free in-process baseline, min-of-N paired rounds (no absolute-ms
  sleep bounds); frame-loss counter over a sustained burst run.
- Tolerance: zero dropped frames at any load level tested.
- Falsifier: any dropped frame, or a fence that also passes with the ring
  buffer bypassed (vacuous measurement).

### CTQ-C Receipt Non-Repudiation & Zero-PHI

- VOC: "audit-verifiable without leaking identifiers" (Compliance).
- Spec: 100% transitions carry a 32-byte BLAKE3 receipt; 0 Safe Harbor
  fields in Gold egress.
- Instrument: POSH-006 court receipt-structure leg + receipt schema
  validation; PHI field scan over Gold egress fixtures.
- Tolerance: 0 unreceipted transitions; 0 PHI fields.
- Falsifier: one state transition committing without a verifiable receipt,
  or a PHI field surviving the egress scan, fails the court; a court that
  cannot flip on an injected unreceipted transition is VACUOUS and blocks
  merge (POSH-006 falsifier).

### CTQ-D Max GC Latency Spike

- VOC: "No stop-the-world GC pauses" (Systems Engineering).
- Spec: p99.99 pause ≤ 1.0 ms; zero refc binary heap duplication.
- Instrument: MEASURE-phase pause distribution over the membrane under
  burst load (master §4 Phase 2 MSA); allocation-rate telemetry.
- Tolerance: no pause above 1.0 ms at p99.99.
- Falsifier: any STW pause > 1.0 ms traced to binary buffer handling on
  actor heaps (SPAF Rule 2 violation), or a benchmark harness that cannot
  reproduce the burst profile.

### CTQ-E Membrane Crash Containment

- VOC: "never crash the calling process" (maintainers, POSH-002).
- Spec: 100% typed error envelopes (transport | upstream | deadline);
  supervision-owned recovery.
- Instrument: POSH-002 kill-court — kill posh mid-stream, observe typed
  `transport` error and reconnect recovery receipt.
- Tolerance: zero raw exits or uncaught vendor exceptions in BEAM.
- Falsifier: one untyped exit reason or calling-process crash on posh kill
  flips the kill-court to FAIL.

### CTQ-F BEAM Purity (Membrane Discipline)

- VOC: "smalt lib/ gains no vendor SDK logic" (charter law 5).
- Spec: 0 vendor-protocol symbols (SigV4, STS refresh, msgpack/cty
  sentinels, gRPC framing) in smalt `lib/`.
- Instrument: grep receipt + POSH-006 court pre-merge leg; POSH-009 parity
  register confirms the detail lives in a registered posh face.
- Tolerance: 0 (charter-level, no tolerance).
- Falsifier: any vendor protocol detail landing in `lib/` = charter
  violation; the fix must move behind the membrane, court refuses merge.

### CTQ-G Court Non-Vacuity

- VOC: "mutation shim FAILS the court" (CI fleet, POSH-006).
- Spec: every posh court flips to FAIL on its paired injected defect.
- Instrument: POSH-006 mutation runs (corrupt response envelope, removed
  parity face, bypassed allowlist) recorded as receipts.
- Tolerance: zero courts that stay green under mutation.
- Falsifier: any court green with its defect injected = VACUOUS GATE,
  exits 1, blocks merge.

### CTQ-H Egress Containment

- VOC: "default-deny other egress" / "refuse to boot" (POSH-008).
- Spec: 100% of un-admitted host attempts return
  REFUSED(egress-allowlist); boot with missing/empty allowlist exits
  non-zero before listen.
- Instrument: POSH-008 bypass-court and boot-court receipts.
- Tolerance: zero silent egress; zero booted listeners on empty allowlist.
- Falsifier: one silent outbound connection, or a boot that opens the
  socket with an empty allowlist, fails the court.

### CTQ-I Readiness Gating

- VOC: "fails healthz must fail pod readiness" (maintainers, POSH-005).
- Spec: pod NotReady whenever the posh healthz probe fails.
- Instrument: POSH-005 sidecar-court witness on the kind lane; port-mode
  supervision restart receipt.
- Tolerance: never Ready while serving ARM through a dead membrane.
- Falsifier: pod Ready with failing healthz = FAIL.

### CTQ-J Admission Discipline

- VOC: "no falsifier receipt does not land" (charter law 4).
- Spec: 0 posh PRs merged without a court receipt in
  `docs/jira/posh/<v>/receipts/`.
- Instrument: receipt ledger audit leg of `just court`.
- Tolerance: 0.
- Falsifier: any merge lacking a receipt = discipline breach, raises a
  typed ledger defect.

### CTQ-K Membrane Overhead

- VOC: "< 5ms overhead per call" (POSH-002).
- Spec: per-call overhead < 5 ms, hard ceiling at p95.
- Instrument: POSH-002/003 timing receipt; ratio fence vs in-process
  baseline (no-sleep doctrine).
- Tolerance: p95 ceiling 5 ms; no absolute-ms sleep fences.
- Falsifier: p95 ≥ 5 ms, or a fence that passes with the membrane
  bypassed.

## 5. Tollgates (DMADV, per master §4)

### T1 DEFINE (Weeks 1-2)

- Entry: master charter approved; ticket set written (POSH-001..010).
- Exit: this document approved; CTQ definitions + boundary rules
  signed off; Turtle press-release spec (v2.0) drafted; C4 context and
  container baseline; risk register seeded from master §5 FMEA.

### T2 MEASURE (Weeks 3-4)

- Entry: T1 exit; posh scaffold boots (POSH-001); membrane v1 round-trips
  (POSH-002).
- Exit: baseline receipts for CTQ-B/D/J/K (tail latency, GC pause
  distribution, allocation rates); MSA on monotonic timers; defect
  opportunity map N=4 per route (Syntax, Authentication, Transformation,
  Cryptographic Proof); baseline DPMO recorded.

### T3 ANALYZE (Weeks 5-6)

- Entry: T2 exit (verified measurement integrity).
- Exit: Ishikawa isolating adapter memory bloat and BEAM bottlenecks;
  FMEA RPNs assigned (master §5) with poka-yoke actions mapped to tickets;
  category-theoretic proof that Turtle-route -> actor-topology mapping
  preserves composition; schema-v1 face set frozen; seam
  `posh/internal/api/types.go` locked in RESOLUTIONS.md (POSH-010).

### T4 DESIGN (Weeks 7-10)

- Entry: T3 exit; lanes L1-L8 dispatched (POSH-010), wave-1 read-only
  edit plans filed.
- Exit: `ingress/*.ttl` + `egress/*.ttl` specs; ggen synthesis packs
  compile BEAM pipelines + Go adapters; BLAKE3 `no_std` kernel; HCL AST
  diff poka-yoke; POSH-003/004/005/008/009 acceptance green; migration
  ledger complete (POSH-007); per-lane atomic commits with lane build
  roots deleted before integration.

### T5 VERIFY (Weeks 11-12)

- Entry: all design-leg courts green.
- Exit: Chicago School state-based suites green; cleanroom run on kind via
  `just posh-court`; zero-drift `-detailed-exitcode` 0 (CTQ-A); mutation
  shim flips the court (CTQ-G); DPMO calculated; control plan handed off;
  formal sign-off per master §9.

## 6. SIPOC — posh membrane

```
Supplier            Input                    Process              Output            Customer
smalt BEAM core     typed envelopes +        receive on USD/      typed response    smalt client.ex
(posh client.ex)    deadlines                localhost, JSON v1   or typed error    (lib/smalt/posh)
                                             (gRPC v2 later)      envelope
azure-sdk-for-go    azidentity creds,        face routing: token  ARM JSON probes   smalt parity
azidentity          SMALT_ARM_ENDPOINT,      mint (cache), RG     + CRUD receipts   lanes
                    allowlist                /provider/container
                                             Apps CRUD
terraform-plugin-   protocol-6 handshake,    provider schema,     plan/apply/       courtroom-
framework           MAGIC_COOKIE             plan/apply/destroy,  destroy results;  platform-az
                                             data sources         zero-drift state  (Terraform CI)
client-go           kubeconfig over kind     kind/swarm control   object state      smalt kind/swarm
                                                                  witnesses         lanes
no_std BLAKE3       transition payloads      receipt mint at      32-byte Merkle    compliance/
kernel              + state deltas           turnstile            receipts          audit lanes
smalt courts        falsifier corpora,       admit/reject;        receipts under    maintainers,
(shim-court)        mutation shims           non-vacuity          posh/<v>/receipts CI fleet
                                             mutation runs
posh.yaml fences    endpoint allowlist       default-deny         REFUSED(egress)   CI fleet,
(fail-closed boot)  (missing file = no       egress, typed        + stderr receipts operators
                    boot)                    refusals
```

## 7. RACI (working, from master §8)

| Activity | Sponsor | Lead Architect | BEAM Eng | Go Specialist | Quality Lead |
|---|---|---|---|---|---|
| Charter sign-off (T1) | A | R | C | C | C |
| Turtle specs (ingress/egress) | I | A | R | C | C |
| ggen synthesis packs | I | A | R | R | I |
| BLAKE3 no_std kernel | I | A/R | I | I | C |
| Go peripheral adapters | I | C | C | A/R | I |
| Andon gates + verification | I | C | C | C | A/R |
| Tollgate sign-off (T5) | A | C | I | I | R |

Lane dispatch follows POSH-010: coordinator owns git transitions; lanes
L1-L8 hold disjoint file ownership on the one canonical smalt checkout.

## Status

DEFINE — ALIVE (document). Verified this session: read
`charter-master.md` (150 lines) and POSH-001..010 in
`docs/jira/posh/v26.10.30/` on disk; every VOC row quotes master §3 or a
ticket verbatim; every CTQ (A-K) carries instrument + falsifier;
tollgates map 1:1 to master §4 phases; RACI transposed from master §8.
PARTIAL as a project: only the DEFINE gate has an artifact — no baseline
receipts exist yet (they are T2 exit criteria).
