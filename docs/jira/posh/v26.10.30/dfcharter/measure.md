# Measure — POSH DfLSS Phase 2

Elaborates §4 Phase 2 (MEASURE) of `charter-master.md`; never contradicts it.
Feed: §3 CTQ table, §5 FMEA, §6 gate SLAs, §7 DPMO formula.
All receipts land in `docs/jira/posh/<version>/receipts/`.

## 1. Baseline Metric Definitions and Instruments

Every metric below names its instrument. A metric without a named instrument
is UNVERIFIED by definition and may not enter the baseline table.

### M1 — p99 Ingress-to-Egress Tail Latency

- Definition: wall time from first byte read on Port In socket to last
  byte written on Starboard Out sink, per message, at target load.
- Unit: microseconds (integer).
- Instrument: `:timer.tc/1` (or `:timer.tc/3`) bracketing the pipeline hop
  pair, recorded per message into an EDR/`{:histogram, _}` collector.
  Cross-process spans use `:telemetry` execute events with monotonic
  `:erlang.monotonic_time/1` deltas; `:timer.tc` already uses the
  monotonic clock internally, satisfying clock discipline (§2.3).
- Percentiles computed over the raw sample array per run; never
  pre-aggregated. Run summary written to a bench receipt by
  `scripts/bench.py` (invoked via `just bench`), which emits JSON with
  per-run p50/p99/p99.9/p99.99 arrays keyed by load profile.
- CTQ tie-in: charter §1.2 claims p99 > 850 ms on symmetric gateways;
  the baseline reproduces that class on a reference symmetric gateway
  before any POSH code exists.

### M2 — GC Pause Distributions

- Definition: per-process and total GC pause durations on the BEAM,
  over the same run window as M1.
- Unit: nanoseconds.
- Instrument: `:erlang.trace/3` with `:garbage_collection` trace flag;
  the trace handler records `gc_major_start`/`gc_major_end` and
  `gc_minor_start`/`gc_minor_end` monotonic deltas. Supplement with
  `:erlang.system_info(:garbage_collection)` snapshots for heap
  context and `:recon` (`:recon.bin_leak/1`, `:recon.gc/1`) to detect
  refc-binary heap duplication (charter CTQ: zero refc duplication).
- NOT an instrument: sleeping then sampling. Pause measurement is
  event-driven via traces only.
- CTQ tie-in: §3 "p99.99 pause ≤ 1.0 ms"; baseline measures the
  monolithic-heap comparator, not POSH.

### M3 — CPU Cycles per Message

- Definition: CPU cycles attributable to one message traversing the
  membrane, divided by message count.
- Instrument (BEAM): cycle counter via `perf stat -e cycles -p <os_pid>`
  on the BEAM process during a fixed message-count run window
  (macOS dev: `perf` via `kubectl`/Linux court nodes; darwin fallback
  is `llvm-perf`-equivalent `sudo powermetrics` is rejected — instead
  use wall-clock `:timer.tc` paired with scheduler utilization from
  `:msacc` (microstate accounting), reported separately and labeled).
- Instrument (Rust kernel): `cargo bench` + `iai`/`iai-callgrind`
  cycle counters on the BLAKE3 kernel (deterministic, hardware-counted,
  immune to scheduler noise — preferred for the no_std turnstile).
- Unit: cycles/message; msacc results reported as µs/message and
  explicitly labeled wall-vs-cpu.

### M4 — Allocation Rates

- Definition: bytes and count of allocations per message.
- Instrument (BEAM): `:erlang.trace_process/3` with `:garbage_collection`
  plus `{:dictionary, ...}` heap snapshots; per-scheduler reductions via
  `:erlang.statistics(:scheduler_wall_time)`; binary refc counts via
  `:recon.count(:binary)`. Allocation per message derived from
  `message_queue_data` heap deltas in a controlled single-process loop.
- Instrument (Rust kernel): `#![no_std]` invariant checked structurally:
  `cargo build` with a global allocator shim that counts `alloc` calls;
  the receipt asserts alloc-count == 0 across the kernel bench corpus.
  This is a compile/court artifact, not a runtime estimate.
- Instrument (Go shims): `go test -bench . -benchmem` (allocs/op,
  B/op) via HashiCorp go-plugin harness bench.

Each metric's baseline run emits one receipt (§6) containing: subject SHA,
instrument name, raw percentile arrays, host identity, and exit code.

## 2. Measurement System Analysis (MSA)

ISO 13053-2 requires the gauge be qualified before the data is trusted.

### 2.1 Timer Calibration

- Reference: `:timer.tc` resolves to `:erlang.monotonic_time/1`
  (native → microsecond conversion). Verify resolution empirically:
  loop 10,000 `:timer.tc` calls around a no-op; the minimum nonzero
  observed delta is the clock floor. Receipt records clock floor and
  native resolution (`1 000 000 * erlang:monotonic_time(second) diff`).
- Cross-check: compare a 1-second `:timer.tc` span against the OS
  monotonic clock (`clock_gettime` via a C helper or `date +%s%N` on
  Linux courts) — drift must be < 0.01%; any larger skew fails the
  MSA receipt and bars all timing data from that host for the wave.

### 2.2 GR&R-Style Gauge Reproducibility for Benches

Adapted Gauge R&R for software: no human operators, so operator axis =
bench runner identity (host + runner version + ggen identity, charter
primitive R). Parts = fixed workload fixtures pinned by SHA.

- Method: run the SAME pinned fixture K=5 times on each of M=3
  configurations (2 hosts + 1 CI court). Compute:
  - Repeatability (equipment variation): spread of 5 runs on one host.
  - Reproducibility: host-to-host mean shift on the same fixture.
  - %GRR = 6 * sigma_gauge / tolerance-width, where tolerance-width
    comes from charter §3 USL−LSL for that CTQ (e.g., GC pause
    p99.99: USL 1.0 ms, LSL 0).
- Acceptance: %GRR ≤ 10% GREEN, 10–30% conditional (label the receipt
  CONDITIONAL and name the confound), > 30% RED — gauge rejected, no
  baseline DPMO may be published from that instrument that wave.
- Deterministic benches (`iai` cycle counts) are exempt from the host
  axis but must still show run-to-run repeatability = exact equality;
  a single divergent count is RED (counting-cycle determinism is the
  gauge itself).

### 2.3 Monotonic-Clock Discipline

- All durations use `:erlang.monotonic_time/1` (via `:timer.tc` or
  raw). Wall-clock time (`:os.system_time`) is banned inside any
  measurement; it may appear only as receipt metadata.
- No `Process.sleep` in any bench or measurement harness (smalt
  NO-SLEEP doctrine). Coordination is structural: GenServer `call`
  sync, `:sys.get_state`, bounded polls on real observables.
- Bench start-up readiness is a state transition (listener socket
  bound / port open), polled with a bounded deadline, never a wait.

## 3. Defect-Opportunity Mapping (N=4 per Route)

Charter §7: O = R × 4. Each route (message path) carries exactly four
defect opportunities; each maps to a named gate that detects its defect.

**D1 — Syntax**
- Valid: payload/route form matches the SHACL shape bound at the
  Port In read.
- Defect: malformed shape admitted into heap.
- Gate: INVARIANT (SHACL check at socket read; charter §5 row 1).

**D2 — Authentication**
- Valid: caller identity resolves to an admitted principal before
  route dispatch.
- Defect: unauthenticated or foreign-routed admission.
- Gate: TEST (Chicago identity court) + INVARIANT (route-termination
  rule, charter §6).

**D3 — Transformation**
- Valid: Gold-egress projection preserves schema parity; zero
  PII/PHI mutation beyond declared transforms.
- Defect: undeclared mutation, PHI leak, schema drift.
- Gate: LINT + INVARIANT (AST provider-schema diff; HIPAA field scan).

**D4 — Cryptographic Proof**
- Valid: state transition carries a 32-byte BLAKE3 Merkle receipt
  token.
- Defect: transition committed without non-repudiation proof.
- Gate: BUILD (type-enforced turnstile — the API will not compile
  without the receipt token; charter §5 row 3) + TEST.

Detection rule: a unit U contributes a defect for dimension d iff its
detecting gate emits RED (or the receipt for that unit is absent where
a receipt is mandatory — an unreceipted actuation is itself a
dimension-4 defect). YELLOW is not a defect; it is recorded as a
defect-precursor count, separate from D_total.

## 4. Baseline DPMO Establishment Procedure

From charter §7: DPMO = (D_total / (U × O)) × 1,000,000, O = 4.

### 4.1 Unit Definition

- One unit U = one message traversing one complete route (Port In read
  → turnstile → Gold egress write), identified by its dimension-4
  receipt token. A message that never produces a receipt token is a
  unit AND a dimension-4 defect (receipt-mandatory invariant).
- Baseline comparators measured identically: (a) reference symmetric
  gateway fixture, (b) manual cloud shim fixture. POSH has no unit
  count until Phase 4 produces synthesized pipelines; Phase 2 DPMO is
  therefore comparator-baseline DPMO, published as such.

### 4.2 Sampling Plan

- Population: N_runs = 30 qualifying runs per fixture per wave
  (ISO 13053 minimum for capability estimation), each run processing
  a fixed SHA-pinned workload of U_run = 10,000 messages.
- Stratification: runs spread across 3 load profiles (sustained 1x,
  burst 10x, outage-recovery) to prevent a single regime dominating.
- A run qualifies only if: its gates were instrumented, its host
  passed MSA (§2.2), and its receipt chain verifies (§6).

### 4.3 Run Length and Aggregation

- Per run: gates emit per-unit pass/defect rows into the run receipt.
- Wave aggregate: D_total = Σ defects over all qualifying runs;
  U = Σ units. One DPMO number per fixture per wave, with a
  stratified breakdown (dimension × load profile) so ANALYZE gets
  Pareto input, not just a scalar.

### 4.4 Sigma Level Reporting

- Convert DPMO → sigma per charter §7 table (runtime target ≤ 1.00
  DPMO; compile-time turnstile = 0 by construction, verified by the
  BUILD gate refusing receipt-less transitions — the court receipt
  for a refused compile is the measurement instrument for "∞ sigma").

## 5. Ratio Fences for All Duration Claims

Per smalt no-sleep doctrine: absolute-ms bounds fence exactly one
leaked constant and flake under load. Every duration claim in this
phase uses relative fences against an independent sleep-free baseline.

- **Gate SLA claims (charter §6):** ratio fence — gate duration ≤
  K × (same gate on pinned fixture SHA, same host, paired rounds,
  min-of-N). K per gate; the absolute SLA stays charter-level
  policy, never a test assertion.
- **Bench run cost:** paired rounds — new vs baseline bench
  interleaved A/B/A/B, min-of-3 per side; claim fails if the ratio
  exceeds the recorded K.
- **Measurement overhead (`:timer.tc`, traces):** instrumented vs
  uninstrumented same-workload pipeline; overhead ratio K_over
  ≤ 1.10 required, else the instrument perturbs the subject and
  the data is RED.
- **GC-pause improvement (future phases):** ratio vs comparator
  fixture M2 distribution, not vs any absolute bound; the §3 CTQ
  USL (1.0 ms) is a design target, not the fence.
- **Poll deadlines:** every bounded poll's deadline is K × a
  sleep-free observable baseline (poll interval × max-iterations),
  never a bare ms literal.

Fence constants live in the bench config; changing a K value is a
reviewed diff with a receipt naming the measured ratio that forced it.

## 6. Data Collection Plan — Receipts

### 6.1 Location and Naming

- Path: `docs/jira/posh/<version>/receipts/measure/`
- Naming: `<UTC timestamp>-<metric>-<fixture-sha8>.json` e.g.
  `20261030T120000Z-m1-tail-a1b2c3d4.json`.
- One receipt per run; wave summary receipt aggregates by fixture SHA.

### 6.2 Receipt Fields (minimum)

`subject` (repo + exact SHA), `instrument` (named tool, §1),
`host_identity` (hostname + arch + BEAM/ERTS version), `raw` (full
percentile arrays / defect rows — never pre-aggregated only),
`commands` (exact invocation), `exit_codes`, `msa_ref` (the gauge
receipt this run trusts), `prev_receipt_sha256` (chain to previous
receipt for this metric+fixture).

### 6.3 Retention and Tamper-Evidence

- Retention: receipts are project capital — never deleted within a
  milestone; superseded receipts remain and are superseded, not
  replaced (charter §7 conservation; out-of-subject receipts principle).
- Tamper-evidence: each receipt embeds the BLAKE3 hash of its raw
  sample file and the `prev_receipt_sha256` chain link; a recompute
  pass (`just receipts-verify`) recomputes chains and fails RED on any
  broken link. Git history is the secondary ledger; a receipt edited
  after commit is detectable as a chain break.
- Access rule (conservation): a receipt created by run R is never
  mutated by a later phase; corrections append a superseding receipt.

## 7. Tollgate Exit Criteria (Phase 2)

1. All four metrics have named instruments and ≥ 1 GREEN MSA receipt.
2. N=4 defect map published with gate bindings (§3 table).
3. Comparator-baseline DPMO computed from ≥ 30 qualifying runs per
   fixture, stratified per §4.3, receipts chained and verified.
4. Zero `Process.sleep` in any measurement harness (grep receipt).

Status: PARTIAL

Verified this session:
- charter-master.md read in full; sections 3/4/5/6/7 cross-referenced
  above without contradiction.
- `scripts/bench.py` exists on disk; `docs/jira/posh/v26.10.30/`
  exists with `charter-master.md` and `define.md`.
- Instrument names (`:timer.tc`, `:erlang.trace`, `:msacc`, `:recon`,
  `cargo bench`/`iai`, `go test -benchmem`, `perf stat`) cited from
  standard tooling, not executed here — the baseline runs themselves
  are NOT yet executed, hence PARTIAL, not ALIVE.
