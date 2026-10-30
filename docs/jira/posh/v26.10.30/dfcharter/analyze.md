# POSH DfLSS Analyze (Phase 3) — Root-Cause & FMEA

Elaborates charter-master.md §4 Phase 3 and §5. No contradiction; where
numbers are restated they are copied from charter §5, not re-derived.

Baseline source for every statistical claim: `measure.md` (Phase 2
deliverable, same directory). Each RPN driver below cites its measured
baseline there; where measure.md is not yet landed, the driver is marked
UNVERIFIED (pending) rather than asserted.

Inventive-principle authority: `triz.md` (operator-supplied, same
directory). The four problem axes resolve through its three TRIZ
contradictions; the FMEA Poka-Yoke actions are TRIZ resolutions, not
generic controls.

## 1. Ishikawa (Fishbone) — Charter Problem Axes

Four charter §1.1 axes, causes branched to 6M classes
(Method/Man/Machine/Material/Measurement/Environment).

```
                         SYMMETRIC CONTENTION (p99 > 850 ms)
  Method  [shared thread pool for intake+settlement]-------------------+
  Method  [one socket table shared by both directions]              |
  Machine [global allocator; refc binaries on shared heap]          |
  Machine [scheduler collapse: dirty schedulers starved]            |
  Material [burst frames queued behind settlement retries]          |
  Measurement [p99-only telemetry hides HOL blocking]               |
  Environment [cloud RTT variance amplifies shared-pool waits]      |
                                                                   v
                      +------------------------------------------+
  Man     [same team owns both halves; no ownership fence] --> SYMMETRIC
                                                                   CONTENTION
  Method  [retry-on-shared-pool couples failure domains]            ^
  Environment [outage backpressure propagates into intake]          |
                                                                   |
                         CONFIG DRIFT (runtime panics)             |
  Method  [YAML/TOML blobs, no type system]------------------------+|
  Method  [schema changes land without AST diff]                   ||
  Man     [hand-edited configs; no generated projection]           ||
  Machine [provider SDK versions skew from vendored schemas]      ||
  Material [undeclared HCL attributes reach plan phase]           ||
  Measurement [no gate compares attributes to provider schema]    ||
  Environment [vendor ships weekly schema churn]                 ||
                                                                 vv
                      +------------------------------------------+
  Man     [tribal knowledge of valid config] ------------------> CONFIG
                                                                 DRIFT
                         HYPERSCALER IMPEDANCE
  Method  [community adapters bridge via NIFs over C]---------------+
  Method  [foreign memory bounds unenforced at call sites]         |
  Machine [stop-the-world GC swept by large binary buffers]        |
  Machine [refc binary duplication across adapter heaps]           |
  Material [leaked allocations in adapter error paths]             |
  Measurement [no memory-bound probe per adapter call]             |
  Environment [K8s/Terraform release cadence outruns adapters]     |
                                                                   v
                      +------------------------------------------+
  Man     [adapter fixes forked, not upstreamed] ---------------> HYPERSCALER
                                                                 IMPEDANCE
                         AUDIT VACUUM
  Method  [logs mutable post-write; no receipt chain]---------------+
  Method  [error branch skips hash; async log writes]              |
  Man     [audit assembled by hand at inspection time]             |
  Machine [centralized cloud lake stores raw PHI]                  |
  Material [unstructured log text, no BLAKE3 Merkle anchor]        |
  Measurement [no 21 CFR Part 11 non-repudiation probe]            |
  Environment [HIPAA Safe Harbor fields never screened at egress]  |
                                                                   v
                      +------------------------------------------+
                                                                   |
                                                            AUDIT VACUUM
```

Note: the six 6M classes appear on every axis because the charter problem
is architectural, not staffing — Man causes are consequences of missing
structure, not root causes. This matters for §5: countermeasures target
Method/Machine/Material (structure), which mechanically deletes the Man
and Measurement causes.

### 1.1 TRIZ Resolution per Axis (per triz.md, authoritative)

Each axis terminates not in a generic fix but in a named TRIZ
contradiction resolution:

- **Symmetric contention** resolves via **Contradiction 1**
  (Validation Rigor vs Wire Throughput) with **Principle 3
  (Asymmetry)**: structurally distinct ingress/ and egress/ lanes —
  separate supervision trees, separate memory rings. The shared-pool
  and shared-allocator 6M causes on this axis are deleted by the
  asymmetry split, not tuned down.
- **Config drift** resolves via **Principle 10 (Prior Action)** and
  **Principle 28 (Replacement of Mechanical Systems)**: policies live
  in Turtle graphs checked by SHACL/SPARQL prior to execution;
  ggen projects code, eliminating manual plumbing. The YAML/TOML
  and hand-edited-config causes are removed because the
  configuration itself ceases to exist (triz.md IFR).
- **Hyperscaler impedance** resolves via **Contradiction 2**
  (Interoperability vs Sovereign Control) with **Principle 24
  (Intermediary)**: the disposable stateless Go membrane absorbs
  schema churn; the sovereign core never speaks hyperscaler
  protocols. The NIF/foreign-memory causes are deleted — the
  bridge code is generated, disposable, and stateless (SPAF Rule 1).
- **Audit vacuum** resolves via **Contradiction 3**
  (Deep Auditability vs Privacy Liability) with **Principle 2
  (Taking Out)**: only the 32-byte BLAKE3 receipt (R_receipt) and
  anonymized Gold aggregate persist; the liability-inducing
  substance never reaches the cloud. The raw-PHI-in-lake and
  mutable-log causes are deleted by extraction, not encrypted
  in place.

Su-Field framing (triz.md §3): all four axes share one harmful
action — S1 (untrusted payload) acting directly on S2 (sovereign
state) through an incomplete field. Every resolution introduces
S3 (the Ingress Turnstile) with admission field F1 (SHACL) and
cryptographic field F2 (BLAKE3), so S2 admits only Delta
S_admitted. The fishbone's four axes are four symptoms of the
one incomplete Su-Field.

## 2. FMEA — Full Table (charter §5, elaborated)

RPN = Severity × Occurrence × Detection (1–10 each), per charter §5.

### 2.1 Ingress Intake (Port In) — malicious payload admitted

Charter RPN 180 = 9×4×5; target 18 (9×1×2).

- Root-cause chain: YAML/TOML schema drift (axis: config drift) →
  validation deferred to runtime try/catch → malformed/hostile frames
  allocated onto actor heaps → global GC sweep stalls intake scheduling
  → p99 > 850 ms and memory exhaustion.
- Detection mechanism (named gate): **Invariant Gate** (charter §6,
  SLA < 5 s) — SPARQL query asserts 100% of ingress/ routes terminate
  in SHACL turnstiles; an orphan route = RED halt. Runtime complement:
  Test Gate Chicago suites admit hostile-frame corpora against the real
  ring buffer.
- RPN-reduction argument (structural, not aspirational): O 4→1 because
  SHACL validation moves to socket-read time inside the zero-alloc ring
  buffer — a frame that fails shape match is dropped before allocation,
  so the failure mode's precondition (allocation before validation) is
  removed by construction, not reduced in frequency. D 5→2 because the
  Invariant Gate runs on every build with a 5 s SLA — detection latency
  drops from "observed in prod" to "pre-merge, machine-checked".
  Severity stays 9 (a hostile payload is inherently severe); the
  product is 9×1×2 = 18.
- TRIZ mapping: this is the **Su-Field completion** (triz.md §3) — S1
  previously acted on S2 directly; S3 (turnstile) + F1 (SHACL
  admission field) intercept, supported by **Principle 10 (Prior
  Action)**: invariants satisfied by compilation before execution. On
  failure, **Principle 22 (Blessing in Disguise)** applies: the
  isolated actor crashes, its heap drops — no defensive guards nursing
  corrupted state.

### 2.2 Go Adapter Boundary — undeclared HCL attribute

Charter RPN 288 = 8×6×6; target 16 (8×1×2).

- Root-cause chain: vendor SDK schema churn (axis: hyperscaler
  impedance) → drift between vendored schema and provider → undeclared
  attribute reaches plan phase → Terraform CLI hard error → RED Andon
  in downstream environments (worst measured class per measure.md
  baseline B-02).
- Detection mechanism: **Build Gate** hosting the Inventory Gate Diff
  (charter §4 Phase 4): static AST diff of HCL attributes vs generated
  Go provider schema; missing attribute → compile halt (Andon RED,
  charter §6, SLA < 60 s). This is Poka-Yoke in the strict sense —
  the defect becomes unrepresentable at build time.
- RPN-reduction argument: O 6→1 and D 6→2 both collapse for the same
  structural reason: the AST diff runs in the Build Gate on every
  commit, so an undeclared attribute cannot exist in a green build.
  Occurrence is not "less frequent" — the generating mechanism
  (hand-maintained adapter code) is deleted by ggen synthesis from
  Turtle (charter §1.2), leaving no surface for drift. 8×1×2 = 16.
- TRIZ mapping: **Principle 24 (Intermediary)** — the Go membrane is
  the disposable intermediary absorbing hyperscaler schema churn
  (triz.md Contradiction 2), plus **Principle 28**: the adapter is
  mechanically projected from RDF, not hand-written, so the drift
  surface's author disappears.

### 2.3 Cryptographic Settlement — mutation without proof

Charter RPN 120 = 10×2×6; target 10 (10×1×1).

- Root-cause chain: hashing lives on actor-heap call sites (violates
  SPAF Rule 2) → error/exception branch bypasses the hash step → state
  committed with no receipt → audit failure under FDA 21 CFR Part 11.
- Detection mechanism: **Invariant Gate** SPARQL rule "every state
  transition terminates in a receipt rule" plus the Test Gate's
  receipt-token assertions; design-time enforcement is the Type-Enforced
  Turnstile — the transition API's return type requires a signed 32-byte
  BLAKE3 token, so the bypassing branch fails to compile.
- RPN-reduction argument: D 6→1 is the load-bearing reduction: the
  receipt token is a required type in the transition API, so a
  mutation-without-proof is a type error, caught by the compiler with
  deterministic latency (0 DPMO compile-time tier, charter §7). O 2→1:
  error branches are generated from the same Turtle rule as happy
  paths, so the bypass path cannot be authored. Severity 10 is
  irreducible (Part 11 non-repudiation failure is maximal). 10×1×1.
- TRIZ mapping: **Principle 2 (Taking Out)** — extract only the
  mathematical invariant (32-byte BLAKE3 receipt); the
  liability-carrying substance never persists (triz.md Contradiction
  3), and **Principle 35 (Parameter Changes)**: mutable audit records
  become immutable Knowledge Wormholes W(t) navigable in
  O(log n + k). F2 (cryptographic field) is the completing field for
  the S1→S3→S2 chain.

### 2.4 Egress Delivery (Starboard) — outage blocks ingestion

Charter RPN 225 = 9×5×5; target 18 (9×1×2).

- Root-cause chain: symmetric shared connection pool (axis: symmetric
  contention) → settlement retry queue backs up into intake socket
  pool → head-of-line blocking → intake buffers overflow → edge device
  crash (sensor frame loss = 0.000% CTQ violated, charter §3).
- Detection mechanism: **Test Gate** Chicago integration suites run
  real outage scenarios (real collaborators: kill the egress sink in
  the kind cluster, assert intake keeps admitting and spools to NVMe);
  Invariant Gate SPARQL asserts zero shared resources between
  ingress/ and egress/ route graphs.
- RPN-reduction argument: O 5→1 because the coupling mechanism itself
  is deleted — SPSC ring buffer physically decouples Port In; Starboard
  fails closed to local NVMe spool (charter §5 action). There is no
  shared pool left to contend, so "outage blocks ingestion" loses its
  causal path, not just its probability. D 5→2 via the real-outage
  Chicago suites on every build. 9×1×2 = 18.
- TRIZ mapping: **Principle 3 (Asymmetry)** — triz.md Contradiction 1
  resolved by splitting ingress/ and egress/ into distinct physical and
  semantic lanes (the PISO primitive); the asymmetric vectors give
  intake bursts zero physical pathway to degrade outbound (triz.md
  IFR: "The Contention does not exist").

## 3. Category-Theoretic Proof Sketch

**Claim (charter §4 Phase 3):** the functor F : TurtleRoute → BeamTopo
mapping W3C Turtle route graphs to BEAM actor topologies preserves
composition and causal consistency.

**Objects.**
- Category **TurtleRoute**: objects = ingress/ and egress/ route graphs
  (RDF graphs over the POSH Turtle DSL, each valid against its SHACL
  shapes); morphisms = graph homomorphisms induced by SPARQL CONSTRUCT
  rules (route refinement / linking).
- Category **BeamTopo**: objects = BEAM actor topologies (supervision
  trees with actor processes as nodes, message channels as edges);
  morphisms = topology maps sending each actor to an actor and each
  channel to a channel, respecting supervision edges.

**Functor laws.**
- F(id_G) = id_F(G): identity CONSTRUCT (empty WHERE with same graph)
  yields the identical generated topology — ggen synthesis is
  deterministic given the graph (charter §1.2), so identical input
  graph, identical supervision tree.
- F(g ∘ f) = F(g) ∘ F(f): composing two route refinements in Turtle
  (CONSTRUCT B from A, then CONSTRUCT C from B) and synthesizing once
  equals synthesizing A→B and B→C separately and gluing. Holds because
  ggen's SPARQL CONSTRUCT rules are local — each rule reads only its
  input graph's triples and writes local actor/channel terms, so the
  generated topology is assembled from per-rule images. Falsifier: a
  rule that inspects derivation history (graph-level negation or
  aggregate over prior CONSTRUCT steps) breaks locality and with it
  the law. The Invariant Gate's SPARQL verification runs over the
  composed graph, so non-local rules fail the gate before synthesis.

**Causal consistency (e_i → e_j preserved).**
Let e_i → e_j be a causal edge in the route graph (route A feeds
route B, receipt rule anchored between them). F sends it to a message
channel actor_i → actor_j in the supervision tree. Preservation means:
any settlement receipt emitted at e_j transitively covers e_i's
payload, because the receipt rule is part of the graph morphism image
and ggen emits the Merkle anchor at the channel, not the endpoint.
Falsifier (what a violating counterexample looks like): a Turtle pair
where route A feeds B with a receipt rule anchored only on B's
terminal sink, while a synthesis rule reorders or drops the intermediate
channel — the generated topology delivers e_j without e_i's anchor,
and a Test Gate replay (real BLAKE3 verification against the Merkle
root) rejects the settlement. Concretely: two routes
`ingress/sensor-a.ttl` and `ingress/sensor-b.ttl` CONSTRUCTed into one
topology where the synthesis template merges channels; if the template
orders channel creation after sink bind, actor_j can process e_j before
the anchor for e_i exists. The Invariant Gate ("100% routes terminate
in turnstiles; 0 orphan nodes", charter §6) halts this shape; the
rejection is the falsifier firing.

**Non-vacuity:** the counterexample shape above is runnable in a court:
synthesize the violating template, run `just posh-court`, expect RED.
A court that cannot RED on this shape is vacuous (charter §6 Andon
protocol).

## 4. Hypothesis Tests Linking RPN Drivers to Measured Baselines

All baselines sourced from `measure.md` (Phase 2 deliverable). Statistical
form: each hypothesis is tested as a ratio fence against the measured
baseline (ratio fences, not absolute-ms bounds; paired rounds, min-of-N).

Each driver: H0, test statistic vs measure.md baseline, reject condition.

- Shared-pool HOL blocking (FMEA 2.4)
  - H0: egress outage does not raise intake p99.
  - Test: paired rounds, min-of-N over 3 pairs — measure.md baseline
    B-01 (symmetric gateway p99 > 850 ms) vs decoupled SPSC topology.
  - Reject H0 when: decoupled p99 ratio > 10x better AND drop rate
    0.000% (CTQ, charter §3).
- Hostile payload allocation (FMEA 2.1)
  - H0: SHACL-at-socket does not cut alloc per hostile frame.
  - Test: alloc-per-message counters over a paired hostile-frame
    corpus.
  - Reject H0 when: decoupled alloc ratio not below the measure.md
    baseline allocation rate.
- HCL schema drift (FMEA 2.2)
  - H0: AST gate adds no detection beyond manual runs.
  - Test: mutation court — inject undeclared attribute, require
    Build Gate RED (Andon halt, charter §6).
  - Reject H0 when: any injected drift passes Build Gate (vacuous).
- Receipt bypass branch (FMEA 2.3)
  - H0: type turnstile adds no compile-time capture.
  - Test: mutation court — author a bypass branch, require compile
    failure.
  - Reject H0 when: bypass branch compiles.
- GC pause driver (FMEA 2.1/2.4)
  - H0: ring buffer does not eliminate STW pauses.
  - Test: p99.99 pause distribution, paired vs measure.md GC baseline.
  - Reject H0 when: p99.99 ratio fails <= 1.0 ms USL (charter §3).

Every row's reject condition is a named court that can exit 1; a court
that cannot reject its H0 is vacuous and must be repaired before the
RPN target is credited (same discipline as charter §5's Poka-Yoke
actions: the reduction is credited only when the mechanism exists and
its court can fire).

Pending rows: where measure.md has not yet landed the named baseline
(B-0n), the row is UNVERIFIED and the RPN target is not credited until
the baseline exists and the court fires. This is the charter Phase 3
tollgate condition: "RPN reductions validated by architecture
prototypes."

## 5. Countermeasure Ranking (ERRC)

Delete/tighten outranks generate. Ranks reuse charter §5 actions —
nothing new is generated here.

1. **E** — DELETE shared connection pool / symmetric backpressure
   (FMEA 2.4, RPN 225). Structural deletion of the coupling mechanism;
   highest RPN deleted, not reduced. Court: Test Gate real-outage suite
   must go GREEN with egress sink dead while intake stays at baseline
   allocation.
2. **E** — DELETE hand-maintained Go adapter surface (FMEA 2.2, RPN
   288). Replaced by ggen synthesis from Turtle; the drift-prone code
   no longer exists to drift. Highest initial RPN of the table; ERRC
   ranks it first despite 2.4's higher attention because 288 > 225 is
   the largest reducible mass and the deletion is total.
3. **R** — TIGHTEN validation timing: move SHACL validation from
   runtime try/catch to socket-read inside the zero-alloc ring buffer
   (FMEA 2.1, RPN 180). Not a new control — relocation of an existing
   one to the allocation boundary.
4. **R** — TIGHTEN receipt enforcement from async-log detect to
   required-type compile check (FMEA 2.3, RPN 120). Existing control
   strengthened; the async log path is deleted as a side effect
   (unreceipted logging no longer exists).
5. **C** — CREATE the two named courts that don't exist yet: the
   real-outage Chicago suite (spool-to-NVMe witness) and the receipt
   bypass mutation court. Created only because ranks 1–4 need firing
   witnesses; generation is last, and each court is non-vacuity-tested
   (must be able to RED).

### 5.1 ERRC x TRIZ correspondence

The ERRC ordering is the TRIZ ordering read from triz.md:

- Rank 1 (delete shared pool) = Principle 3 (Asymmetry): the harmful
  shared field between Port In and Starboard is physically removed.
- Rank 2 (delete adapter surface) = Principle 24 + 28: the
  intermediary absorbs churn, and the hand-written mechanism is
  replaced by semantic graph synthesis.
- Ranks 3–4 (tighten) = Principle 10 (Prior Action): both tightenings
  move an existing control earlier — from runtime to the allocation
  boundary, from async-log detection to compilation.
- Rank 4's side effect = Principle 2 (Taking Out): the unreceipted
  async log path is extracted out of existence.
- Rank 5 (create courts) = Principle 22 (Blessing in Disguise): the
  courts convert failure into signal — a RED Andon on a court is the
  crash-and-drop of a defect before it reaches S2.

Consistent with triz.md IFR: ranks 1–4 all shrink sum(Harms) faster
than sum(Functions), which is the direction sum(Functions) /
(sum(Costs) + sum(Harms)) must move.

## Status

ALIVE for document authoring (this file written and on disk, TRIZ
mapping from triz.md folded into §1.1, §2, §5.1; category-theoretic
proof §3 unchanged); all baseline-dependent claims are UNVERIFIED
pending `measure.md` receipts and court firings per §4. Tollgate:
Phase 3 closes when the §4 courts exist and can exit 1.
