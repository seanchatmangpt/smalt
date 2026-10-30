# Design — POSH DfLSS Phase 4 (DMADV)

Design document for POSH (Port In, Starboard Out) under the DfLSS DMADV
methodology, elaborating §4 Phase 4 DESIGN of
`charter-master.md` and the SPAF boundary contract (§2).

Authoritative inputs: `charter-master.md`, `triz.md` (operator-supplied,
authoritative TRIZ analysis), `define.md`,
`docs/jira/posh/v26.10.30/00-charter.md`, POSH-001..010 tickets.

## 1. SPAF Tri-Tier Architecture

SPAF (Sovereign Peripheral Architecture Fence) divides POSH into three
tiers, each with a hard capability fence. Every operation is legal in
exactly one tier. A capability needed in two tiers is a design defect.

TRIZ anchor (triz.md Contradiction 2, hyperscaler interoperability vs
sovereign runtime control): the tri-tier split is Principle 24
(Intermediary). The sovereign BEAM/Rust core never natively speaks
hyperscaler protocols; a disposable, stateless Go Adapter Membrane
absorbs changing schemas, SigV4/STS quirks, and gRPC handshakes,
translating immediately into sovereign Turtle/REST boundaries. That is
precisely why the Go tier is forbidden domain state (SPAF Rule 1): an
intermediary that accumulates state stops being disposable.

```
+----------------------------------------------------------+
| Tier 1: BEAM orchestrator (smalt)                        |
|   state, supervision, turnstile routing, receipts        |
+--------------------+-------------------------------------+
                     | UDS length-prefixed JSON (v1)
                     | gRPC over same socket (v2)
+--------------------v-------------------------------------+
| Tier 2: Go stateless membrane (posh)                     |
|   protocol translation only; zero domain state           |
+--------------------+-------------------------------------+
                     | typed FFI boundary (C ABI), bounded buffers
+--------------------v-------------------------------------+
| Tier 3: Rust #![no_std] BLAKE3 SIMD kernel               |
|   constant-time Merkle hashing; CC = 1                   |
+----------------------------------------------------------+
```

### 1.1 Tier 1 — BEAM orchestrator (smalt)

Responsibilities:

- Domain state: resource graphs, supervision trees, turnstile routing
  decisions, receipt ledger.
- Owns `lib/smalt/posh/client.ex` (POSH-002): typed request envelopes,
  bounded deadlines, reconnect budget owned by supervision, never
  `Process.sleep`.
- Admits every posh capability through the existing court/receipt
  discipline (charter law 4).
- Projects routes and SHACL admission decisions from `ingress/*.ttl`.

Forbidden (SPAF Rule 2):

- Raw cryptographic hashing on actor heaps.
- Byte-unpacking loops over protocol payloads on local heaps.
- Any vendor SDK logic in `lib/` (charter falsifier: a fix that edits
  smalt lib/ to absorb a vendor protocol detail is a charter violation).

Interface types: Elixir structs `%Posh.Request{}`, `%Posh.Response{}`,
typed error envelope `%Posh.Error{kind: :transport | :upstream |
:deadline}`. BEAM never sees a raw vendor exception.

### 1.2 Tier 2 — Go stateless membrane (posh)

Responsibilities:

- Protocol translation only: HashiCorp go-plugin/protocol 6 (Terraform
  provider, terraform-plugin-framework), azure-sdk-for-go / azidentity
  (POSH-003), client-go (kind/swarm lanes, POSH-005).
- Membrane listener `cmd/posh/main.go`, `internal/server` UDS+TCP
  (POSH-001); `/healthz`; SIGTERM clean exit.
- Egress allowlist enforcement (POSH-008): default-deny, fail-closed on
  missing `posh.yaml`; violations are typed refusals.
- Rebuildable live state ONLY: token caches, connection pools. Nothing
  else survives restart.

Forbidden (SPAF Rule 1):

- Any domain state; any persistent database; any scheduler; any
  business logic; any storage (00-charter out-of-scope list).
- Long-lived state beyond token caches / connection pools.
- Egress to un-admitted hosts (typed `REFUSED(egress-allowlist)`).

Interface types: Go structs mirroring the membrane envelope
(`Request{ID, Op, Payload, Deadline}`, `Response{ID, Status, Body,
ReceiptToken [32]byte}`); typed error envelope
`{kind: transport|upstream|deadline, status, message}`; ARM probe
receipt JSON (POSH-003 `arm probe`).

### 1.3 Tier 3 — `#![no_std]` Rust BLAKE3 SIMD kernel

Responsibilities:

- BLAKE3 Merkle hashing of settled payloads into 32-byte receipt
  tokens; Merkle tree construction over receipt batches.
- Constant-time, branchless quarter-rounds; SIMD vector scans.
- Bounded stack memory, zero dynamic heap allocation (SPAF Rule 3).

Forbidden:

- `std`, dynamic allocation, syscalls, recursion, data-dependent
  branches in hash paths.
- Any I/O, any state, any knowledge of BEAM or Go types.

Interface types: C ABI surface only —
`blake3_merkle_root(const uint8_t* leaves, size_t n, uint8_t out[32])`,
`blake3_receipt(const uint8_t* payload, size_t len, uint8_t out[32])`.
Bounded fixed-size buffers; caller owns memory.

## 2. Turtle Specification Domain

All topology lives as W3C Turtle. ggen compiles the graph; nothing in
`ingress/` or `egress/` is hand-wired in code. This is TRIZ Principle
10 (Prior Action): routing/admission policies live exclusively in the
.ttl knowledge graphs; ggen validates RDF topology via SHACL and
SPARQL *prior to execution* — invariants are satisfied by compilation,
not runtime defensive boilerplate.

### 2.1 ingress/*.ttl (admission, routes, SHACL shapes)

```turtle
@prefix posh:  <https://smalt.dev/posh/ns#> .
@prefix sh:    <http://www.w3.org/ns/shacl#> .
@prefix xsd:   <http://www.w3.org/2001/XMLSchema#> .

# Admission shape: every Port In frame must conform or be dropped
# at the socket read with zero allocation (charter FMEA row 1).
posh:ArmRequestShape a sh:NodeShape ;
  sh:targetClass posh:ArmRequest ;
  sh:property [
    sh:path posh:method ;
    sh:in ( "GET" "PUT" "DELETE" ) ;
    sh:minCount 1 ; sh:maxCount 1 ;
  ] ;
  sh:property [
    sh:path posh:path ;
    sh:pattern "^/subscriptions/[^/]+/resourcegroups/.*" ;
    sh:minCount 1 ;
  ] ;
  sh:property [
    sh:path posh:deadlineMs ;
    sh:datatype xsd:integer ;
    sh:maxInclusive 30000 ;
  ] .

# Route: admission -> membrane -> turnstile -> Starboard Out.
posh:route-arm-crud a posh:Route ;
  posh:ingressPort  posh:port-in-uds ;
  posh:shape        posh:ArmRequestShape ;
  posh:membraneOp   "arm.request" ;
  posh:turnstile    posh:ts-arm ;
  posh:egress       posh:sink-arm-response .
```

### 2.2 egress/*.ttl (sinks, receipts, delivery)

```turtle
@prefix posh: <https://smalt.dev/posh/ns#> .

posh:sink-arm-response a posh:Sink ;
  posh:transport    posh:uds-json-v1 ;
  posh:deliverTo    "http://127.0.0.1:9443" ;
  posh:receiptRule  posh:receipt-blake3-mandatory .

# Receipt rule: no frame leaves Starboard Out without a 32-byte
# BLAKE3 Merkle receipt token (charter CTQ: 100% transitions).
posh:receipt-blake3-mandatory a posh:ReceiptRule ;
  posh:kernel    posh:blake3-simd-kernel ;
  posh:tokenSize 32 ;
  posh:onMissing posh:REFUSE .

# Egress allowlist mirrors POSH-008 fail-closed fence; the graph
# IS the allowlist — posh.yaml is generated from it.
posh:allowlist a posh:EgressAllowlist ;
  posh:admittedHost "http://127.0.0.1:9443" ;   # smalt ARM plane on kind
  posh:admittedHost "http://127.0.0.1:8081" ;   # kind API
  posh:onViolation posh:REFUSE .
```

## 3. ggen Synthesis

SPARQL `CONSTRUCT` rules compile the Turtle graph into BEAM pipeline
code and Go adapter code. Handwritten code is residue only.

### 3.1 Example CONSTRUCT (BEAM pipeline projection)

```sparql
PREFIX posh: <https://smalt.dev/posh/ns#>

CONSTRUCT {
  ?route a :GeneratedPipeline ;
    :module      ?mod ;
    :clientCall  ?op ;
    :shape       ?shape ;
    :turnstile   ?ts ;
    :sink        ?sink .
} WHERE {
  ?route a posh:Route ;
    posh:membraneOp ?op ;
    posh:shape ?shape ;
    posh:turnstile ?ts ;
    posh:egress ?sink .
  BIND(CONCAT("Smalt.Posh.Pipeline.", ?op) AS ?mod)
}
```

Projection: a ggen template renders each solution row to
`lib/smalt/posh/pipeline/<op>.ex` — a supervisor child with the SHACL
shape pre-compiled into a validation clause, the turnstile call, and
the sink writer. A route in the graph with no generated pipeline is an
orphan node and fails the Invariant Gate (charter §6).

### 3.2 Example CONSTRUCT (Go adapter projection)

```sparql
PREFIX posh: <https://smalt.dev/posh/ns#>

CONSTRUCT {
  ?op a :GeneratedAdapter ;
    :goMethod  ?method ;
    :allowHost ?host ;
    :receipt   ?rule .
} WHERE {
  ?route a posh:Route ; posh:membraneOp ?op ;
         posh:egress ?sink .
  ?sink posh:deliverTo ?host ; posh:receiptRule ?rule .
  BIND(REPLACE(?op, "-", "_") AS ?method)
}
```

Projection: `posh/internal/api/generated_adapters.go` — one dispatch
method per `posh:membraneOp`, allowlist entries emitted into
`posh.yaml`, receipt rule wired to the kernel ABI call. The allowlist
in the binary and in `posh.yaml` cannot drift from the graph because
both are projections.

### 3.3 Handwritten-code-is-irresidue rule

Generated output is never hand-edited (charter law: graph is the
source). This rule is anchored in the IFR (triz.md §4): "The Adapter
does not exist — Go code generated as a stateless disposable membrane
directly from RDF schemas, not hand-written" (Principle 28, semantic
graph synthesis). Hand-written plumbing is unpriced cost and harm in
sum(Functions)/(sum(Costs)+sum(Harms)); the only lawful handwritten
artifact is irreducible residue. Any behavior not expressible as a
CONSTRUCT + template lives in a named handwritten seam
(`cnv:CustomBehavior`-style, generated once, never overwritten by
regeneration). Every diff that edits a generated file by hand fails
the Invariant Gate: re-running ggen must reproduce the tree
byte-identically; a dirty regeneration is Andon RED.

## 4. Directory Topology

```
posh/
  ingress/                    # Port In engine
    ttl/                      # admission, routes, SHACL shapes
    kernel/                   # no_std Rust crate (FFI kernel)
  egress/                     # Starboard Out engine
    ttl/                      # sinks, receipts, allowlist
  cmd/posh/main.go            # membrane listener (POSH-001)
  internal/server/            # UDS+TCP
  internal/api/               # envelope types + generated_adapters.go
  bin/posh                    # static build (CGO_ENABLED=0)
smalt (BEAM):
  lib/smalt/posh/client.ex    # typed membrane client (POSH-002)
  lib/smalt/posh/pipeline/    # generated pipelines (one per op)
terraform-provider-smalt/     # provider (POSH-004, dev_overrides)
```

`ingress/` and `egress/` are physically separated engines: no shared
thread pools, no shared sockets, no shared allocators (charter §1.1
symmetric-contention root cause). This is TRIZ Principle 3 (Asymmetry,
triz.md Contradiction 1): decouple into distinct physical/semantic
lanes — Port In absorbs untrusted shock in insulated fail-closed
validation; Starboard Out runs unhindered at raw wire speed over
zero-copy binary membranes. Distinct folders, distinct supervision
trees, distinct memory rings. The only shared artifact is the
compiled kernel FFI object.

## 5. Cryptographic Turnstile

Su-Field model (triz.md §3): the admission turnstile is the complete
dual-substance field. Before: incomplete Su-Field `[S1 untrusted
payload] --F1 mechanical REST/JSON--> [S2 core state]`, vulnerable to
contamination. After: S1 interacts only with S3 (the POSH ingress
turnstile, governed by admission field F1 = SHACL shapes); S3 emits
F2 (the cryptographic BLAKE3 field); S2 (certified Gold state) admits
only the mathematical delta carrying a receipt. The payload never
touches S2 directly — that non-adjacency is the fence.

### 5.1 Receipt token

A settled transition commits a 32-byte BLAKE3 Merkle receipt token:
`token = BLAKE3-Merkle-root(leaves = [frame_hash, prev_receipt,
route_id, monotonic_tick])`. 100% of state transitions carry one
(charter CTQ); 0 transitions settle unproofed. This is also TRIZ
Principle 2 (Taking Out, triz.md Contradiction 3): only the
mathematical invariant (R_receipt + anonymized Gold aggregate)
survives settlement; the liability-inducing substance (raw PHI/
telemetry) is stripped at the edge before the token emits.

### 5.2 Type-enforced state-transition API

The transition API refuses to compile without a receipt — the token is
a required parameter of the only state-mutating constructor:

```elixir
@spec settle(unsettled, receipt :: <<_::256>>, tick)
  :: {:ok, settled} | {:refused, :receipt_invalid}
def settle(...)
```

There is no `settle/2`, no default argument, no `unsettled -> settled`
path that bypasses the 256-bit token. The Rust kernel verifies the
token before the BEAM state machine accepts the transition; a missing
or invalid token is a compile-time shape error on the Elixir side and
a typed refusal at runtime. FMEA row 3 target RPN 10 (10x1x1) is met
by construction: the error branch cannot exist.

### 5.3 CC=1 branchless kernel constraints

- Constant-time: no data-dependent branches, no early exits, no table
  lookups indexed by secret data.
- Branchless quarter-rounds (BLAKE3 g-function) via bitwise selects.
- Bounded stack: fixed-size state (BLAKE3 1312-byte chaining state),
  no recursion, no heap.
- Audit: `cargo-asm` / LLVM IR diff in CI proves no introduced
  conditional branch in the hash loop; a branch appearing is Andon RED.

### 5.4 AVX / NEON path

Two SIMD backends behind one C ABI:

- x86_64: AVX2 (8-lane quarter-round vectors), AVX-512 guarded at
  runtime by CPUID, same constant-time discipline.
- aarch64: NEON 4x32 vectors.
- Portable scalar fallback (same ABI, same correctness property) so
  the court runs on any host; performance lanes gate on the SIMD path.

## 6. Poka-Yoke Controls

### 6.1 Schema inventory gate (compile-time AST diff)

Every control in this section instantiates Principle 10 (Prior
Action): defects are eliminated before execution, at compile or
synthesis time, never nursed at runtime by defensive guards (the
runtime fallback is Principle 22 "let it crash" on an isolated actor,
never a guard ladder).

Existing capital: `/Users/sac/smalt/terraform-provider-smalt/scripts/
schema_inventory_gate.py`. It (1) parses all consumer `.tf` under
`/Users/sac/cai/courtroom-platform-az/infra` with a minimal HCL parser,
(2) runs `terraform providers schema -json` under `TF_CLI_CONFIG_FILE`
dev_overrides when available, else (3) statically parses the provider
schema sources, then diffs used-attr vs implemented-attr per type.
Exit 1 loudly on any gap — an undeclared HCL attribute halts the build
before `terraform plan` can panic (FMEA row 2, target RPN 16).

Non-vacuity: `--self-test` injects `bogus_attr_lx16` into a
implemented type's used set and asserts the gate flips to FAIL; a gate
that accepts the mutation exits non-zero as vacuous.

For the Go provider (POSH-004), the gate's third leg gains a Go
schema leg: the generated `provider_schema.go` is diffed against the
HCL inventory the same way, so schema drift between consumer configs
and the Go provider is caught at build, not at plan.

### 6.2 Other controls

- Invariant Gate SPARQL: 100% routes terminate in turnstiles, 0
  orphan nodes, every sink carries a receipt rule (charter §6).
- ggen regeneration idempotence (byte-identical) blocks hand-edits of
  generated code.
- posh-court non-vacuity mutation: corrupt an envelope, court must
  flip (POSH-006).
- Egress allowlist fail-closed boot: missing/empty file refuses boot
  (POSH-008 falsifier).

## 7. Memory Architecture

### 7.1 Port In — zero-allocation SPSC ring buffer

- Single-producer single-consumer lock-free ring between socket read
  and admission validation.
- Fixed slot count, power-of-two index math, cache-line-padded head/
  tail (no false sharing).
- SHACL validation runs against the slot in place; a shape violation
  drops the buffer with zero heap allocation (charter FMEA row 1
  Poka-Yoke).
- Ingress jitter budget < 10 us; frame drop rate 0.000% (CTQ).
- Physical decoupling: a Starboard outage cannot block Port In — the
  ring is the isolation boundary (FMEA row 4).

### 7.2 Starboard Out — zero-copy refc-binary / writev conduit

- Payloads leave BEAM as refc binaries: allocated off-heap, reference-
  counted, passed by pointer — never copied onto a process heap, so
  no global GC scans them and heap duplication is zero (GC p99.99
  <= 1.0 ms CTQ).
- Egress batching coalesces adjacent payloads into `writev` iovec
  arrays; one syscall per batch, no intermediate buffer copies.
- Go side receives framed slices without re-copying into new
  allocations (the membrane envelope passes offsets, not copies).

### 7.3 NVMe fail-closed spool

- When the egress sink is unreachable, Starboard spools settled
  frames (with their receipt tokens) to a local NVMe append-only log
  and ACKs ingress; delivery is at-least-once with receipt-keyed
  dedup on replay.
- Fail-closed: spool unavailable (disk full, IO error) -> ingress
  backpressures / frame is refused, never silently dropped. No
  unproofed frame ever exists on disk or wire.
- Medical-sensor CTQ: readings survive cloud outages; spool drains on
  reconnect in receipt order.

## Status

DESIGN — this document. Phase 4 DESIGN elaboration of
`charter-master.md` §4; inputs POSH-001..010 and `00-charter.md`.
No POSH ticket implemented at time of writing; Elixir-provider lanes
(2026-10-30 wave) continue in background and feed protocol findings
into POSH-003/POSH-004.
