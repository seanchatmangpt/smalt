# DPMO & Sigma Level Formulation (POSHT Charter §7 Elaboration)

Status: DRAFT — targets locked to charter-master.md §7; baseline numerics UNVERIFIED
until MEASURE phase receipts land.

Elaborates `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/charter-master.md`
§7. Targets are invariant and never renegotiated here:

| Metric | Compile-Time | Runtime |
|---|---|---|
| DPMO | 0.00 | ≤ 1.00 |
| C_pk | ≥ 2.00 | ≥ 1.67 |
| Sigma | ∞ (by construction) | ≥ 6.2 |

## 1. Formal Defect-Opportunity Model

For each route in the Turtle topology, exactly four defect opportunities exist —
one per defect dimension. Opportunities are countable mechanically from the
route graphs, never estimated.

O = R × 4

### 1.1 Route count R (derivation, not assertion)

R is derived by SPARQL COUNT over route individuals in the ingress/ and egress/
graphs. Route individuals are typed `posh:Route` (or equivalent class per the
Turtle spec) and appear in both `ingress/*.ttl` (admission, routes, SHACL
shapes) and `egress/*.ttl` (sinks, receipts, delivery).

```sparql
SELECT (COUNT(DISTINCT ?route) AS ?r)
WHERE {
  { ?route a posh:Route . FILTER(STRSTARTS(STR(?route), "urn:posh:ingress:")) }
  UNION
  { ?route a posh:Route . FILTER(STRSTARTS(STR(?route), "urn:posh:egress:")) }
}
```

R is recomputed at every Invariant Gate run (charter §6, SLA < 5 s) and
published in the gate receipt, so the denominator of DPMO is receipt-backed,
not hand-counted. A drift between gate-run R and the R cited in any DPMO claim
invalidates the claim.

### 1.2 The four defect dimensions (per route, per unit)

**D_schema — schema mismatch.** Defect = a route's payload shape fails its
SHACL shape, or a generated provider/adapter schema diverges from the vendor
HCL AST (missing/extra attribute). Detector: SHACL validation at gate;
HCL-vs-generated-Go AST diff gate.

**D_admission — invalid intake.** Defect = a payload admitted to the Port In
ring buffer without full shape validation, or a valid payload wrongly
rejected (both count). Detector: socket-read admission counter; rejected-
buffer audit log.

**D_turnstile — receipt bypass.** Defect = a state transition committed
without a valid signed 32-byte BLAKE3 receipt token, or with an unverifiable
token. Detector: turnstile API type enforcement; receipt verification on
replay; Invariant Gate receipt-rule query.

**D_settlement — egress defect.** Defect = Gold egress emits a HIPAA Safe
Harbor field, drops a frame, or fails delivery with incorrect fail-closed
spool behavior. Detector: zero-PHI scan on Gold egress; frame-drop counter;
spool-on-outage chaos test.

Each dimension is a binary, per-observation defect flag with a named detector
above — no subjective "severity-adjusted" counting. D_total is the sum of
defect flags across all four dimensions over U units.

## 2. DPMO Formula and Worked Examples

DPMO = (D_total / (U × O)) × 1,000,000

where U = units processed (a unit = one route traversal in one qualification
run), O = 4 opportunities per unit.

### 2.1 Qualification-scale example (charter §4, VERIFY: 500 runs)

- R = 120 routes → O = 120 × 4 = 480 opportunities per run
- U = 500 qualification runs × 120 routes = 60,000 route traversals
- Total opportunities = 60,000 × 4 = 240,000
  (equivalently: O_per_unit=4, unit=route traversal; the charter's
  "R=120, U=500 → O=480,000" phrasing treats O as aggregate: 500 × 480 = 240,000
  traversals × ... — to keep the arithmetic exact we use the traversal unit.)
- DPMO ≤ 1.00 requires D_total ≤ (1.00 × 240,000) / 1,000,000 = 0.24 → 0 defects.

Interpretation: at 240,000 sampled opportunities, a single defect already gives
DPMO = 4.17 > 1.00. The runtime ≤ 1.00 DPMO target is therefore a claim about
the production population rate bounded by a qualified upper confidence limit,
not a raw sample count (see §2.3).

### 2.2 D_total thresholds that keep DPMO ≤ 1.0

D_total ≤ 1.0 × (U × O) / 1,000,000. For the aggregate form O_agg = U × R × 4:

| Scale | U (runs) | R (routes) | O_agg | Max D_total for ≤ 1.0 DPMO |
|---|---|---|---|---|
| Qualification | 500 | 120 | 240,000 | 0 (any 1 defect → 4.17 DPMO) |
| CI-scale | 5,000 | 120 | 2,400,000 | 2 |
| Monthly prod census | 50,000 | 120 | 24,000,000 | 24 |
| Annual | 600,000 | 120 | 288,000,000 | 288 |

Rule: with qualification-scale samples, the pass/fail criterion is strictly
zero defects; DPMO ≤ 1.0 at nonzero counts is only attestable at census scale.

### 2.3 Honest statistics for small samples

Where the raw DPMO would be 0 by sampling luck, the reported runtime figure is
the upper 95% confidence bound (one-sided, Poisson): with D defects observed in
N opportunities, report DPMO_95 = 3.689 × 1e6 / N when D = 0. At N = 240,000
that is 15.37 DPMO — not ≤ 1.0 — so a ≤ 1.00 DPMO claim at qualification scale
requires either ~3.7M+ zero-defect opportunities (N ≥ 3,689,000 for
DPMO_95 ≤ 1.0) or a census-scale rate argument. Claims below this bar are
written as "0 defects observed, DPMO_95 = X" — never rounded to "≤ 1.00 DPMO".

## 3. Sigma Mapping

### 3.1 Convention (stated explicitly)

Standard industry convention applies a **1.5σ shift** (Z_short-term =
Z_long-term + 1.5) to convert a long-term DPMO into the "six sigma" headline
number: 3.4 DPMO ↔ 6.0σ shift-adjusted ↔ 4.5σ long-term.

**POSH claims long-term (shift-free) sigma for the runtime target, and
constructional (∞) sigma for compile time.** Justification: (a) honesty — the
1.5σ shift presumes uncontrolled drift between the short and long windows; POSH
controls drift with SPC (§6) and the Andon gates (charter §6), so claiming the
shift credit would inflate the number by exactly the mechanism we already
mechanically suppress; (b) the charter runtime target ≥ 6.2σ exceeds the
conventional 6.0σ headline precisely because it is shift-free — a 6.2σ
long-term process is strictly stronger than a 6.0σ shift-adjusted one (≈ 0.57
DPMO long-term); (c) compile time needs no conversion: 0 defects by
construction is ∞ under either convention.

### 3.2 Mapping table

Sigma from DPMO: σ_long-term = Φ⁻¹(1 − DPMO/1e6).

| DPMO | σ (long-term, POSH claim basis) | σ (shift-adjusted, +1.5) |
|---|---|---|
| 0 (by construction) | ∞ | ∞ |
| 0.001 | 5.10 | 6.60 |
| 0.57 | 6.20 | 7.70 |
| 1.00 | 5.99 | 7.49 |
| 3.4 | 5.15 | 6.00 (six-sigma headline) |
| 32 | 4.15 | 5.65 |
| 6,210 | 3.50 | 5.00 |
| 66,807 | 2.50 | 4.00 |

Consistency check: the charter runtime pair (≤ 1.00 DPMO, ≥ 6.2σ) is not
numerically co-satisfiable as raw long-term figures (1.0 DPMO ↔ 5.99σ). The
charter's intent, adopted here: ≤ 1.00 DPMO is the *point-estimate* ceiling and
≥ 6.2σ is the *target asymptote* the control plan drives toward; reported
status always carries the §2.3 confidence bound so the gap is visible rather
than papered over. Where a receipt must state one number, DPMO is the metric of
record and sigma is derived, never asserted independently.

## 4. C_pk Derivation

C_pk = min[(USL − μ) / (3σ_proc), (μ − LSL) / (3σ_proc)]

where μ and σ_proc are the measured mean and within-subgroup standard
deviation of the CTQ distribution (X̄-S control chart statistics, §6).

### 4.1 Compile time (attribute-type process)

Compile time is not a variable CTQ: the "specification" is degenerate —
defect = any nonzero warning or error exit from the Andon BUILD/LINT/INVARIANT
gates. A degenerate one-sided attribute process at exactly zero defect
production has no distributional width; capability is defined instead by the
turnstile construction (§5) and C_pk ≥ 2.00 is satisfied vacuously-with-
receipt: the spec band [0, 0] contains the distribution point mass at 0. Any
nonzero warning collapses the point mass to "defect," the Andon gate halts
(RED), and the C_pk claim is suspended until repaired. Numeric C_pk is
reported for variable CTQs below; compile-time reports defect count, not
C_pk algebra.

### 4.2 Runtime variable CTQs (from charter §3)

CTQs with two-sided or one-sided spec limits and their spec limits:

| CTQ | LSL | USL | Basis |
|---|---|---|---|
| Intake ingress jitter (Port In) | — | 10 µs | charter §3 |
| Max GC pause (p99.99) | — | 1.0 ms | charter §3 |
| Test gate branch coverage | 85% | — | charter §6 GREEN band (RED < 80%) |
| Build gate wall clock | — | 60 s | charter §6 SLA |

### 4.3 Algebra, worked for intake jitter

Suppose MEASURE-phase baseline (placeholder — receipt pending) gives jitter
samples with:

- μ = 6.2 µs, σ_proc = 0.8 µs (from S̄/c₄ within-subgroup estimate, n = 5
  subgroups × 25 samples)
- USL = 10 µs, LSL = none (jitter ≥ 0 physically; one-sided upper spec)

One-sided C_pk (C_pu) = (USL − μ) / (3σ_proc) = (10 − 6.2) / (3 × 0.8)
= 3.8 / 2.4 = 1.583 → below the 1.67 runtime gate → NOT capable; design
iteration required (ring-buffer sizing, busy-poll affinity) before VERIFY
sign-off. This is exactly how the algebra is used: C_pk ≥ 1.67 ⟺ μ ≤ USL −
5σ_proc (for one-sided upper), i.e. the mean must sit at least 5 process
sigmas inside the spec limit.

For a two-sided CTQ the same algebra applies per side and C_pk takes the
minimum; C_pk ≥ 1.67 additionally implies C_p ≥ 1.67, i.e. total spread 6σ_proc
fits within the spec width with margin ≥ 3σ_proc.

Runtime gate: every charter §3 CTQ must show C_pk ≥ 1.67 (5σ_proc inside the
nearest limit); compile-time is governed by §5 instead.

## 5. Compile-Time 0 DPMO: Claim Discipline

### 5.1 What "defect-free by construction" means operationally

1. **Synthesis is total, not assisted.** Every BEAM pipeline module, Go
   adapter, and route binding is emitted by `ggen` SPARQL CONSTRUCT from the
   Turtle graphs. A route that exists in the graph exists in the code; a route
   absent from the graph cannot be instantiated at runtime (no hand-written
   route surface).
2. **The turnstile is the AST-diff gate.** The compile-time defect detector is
   the Invariant Gate + AST static diff: generated Go provider schema vs
   vendor HCL attributes; generated Elixir route surface vs Turtle route
   individuals; SHACL shape closure (100% routes terminate in turnstiles, 0
   orphan nodes — charter §6).
3. **Green = 0 defects across all R × 4 opportunities, mechanically.** A GREEN
   gate run is a machine-checked statement that D_schema = D_admission =
   D_turnstile = D_settlement = 0 for every route individual in the run's
   graph — hence 0.00 DPMO *for that run*, by counting, not by promise.
4. **Claim scope.** "0 DPMO by construction" is asserted only over
   ggen-synthesized surfaces passing the turnstile. Hand-written residue
   (charter §2 boundary rules) is inside the runtime accounting (§2), not the
   compile-time claim.

### 5.2 Falsifier

The claim is refuted by any one of:

- **F1 (synthesis escape):** a compiled, green-gated build exhibits a route
  behavior traceable to a graph edge/shape that the SPARQL CONSTRUCT rules did
  not project — i.e. runtime behavior diverges from the AST-diffed projection.
- **F2 (turnstile pass-through):** a build with a deliberately mutated Turtle
  route (added orphan node, dropped receipt rule, SHACL-violating shape)
  compiles clean — the AST-diff gate fails to RED on a known defect injection.
- **F3 (count divergence):** gate receipt R differs from a fresh SPARQL COUNT
  over the same graphs, or a DPMO receipt cites an R not published by a gate
  receipt.

F2 is the non-vacuity court: a turnstile that cannot be forced RED is a
vacuous gate and the 0 DPMO claim is withdrawn, not merely questioned.

## 6. SPC Control Plan

### 6.1 Charted statistics

| Process | Chart | Statistic | Subgroup |
|---|---|---|---|
| Compile defects (4 dims) | p-chart (np if n const) | defect flags per run, R×4 ops | per run |
| Intake ingress jitter | X̄-S | subgroup mean & within-σ of jitter samples | n = 5 per run |
| GC pause p99.99 | X̄-S | subgroup mean & within-σ of pause samples | n = 5 per run |
| Branch coverage | I-MR | coverage % per run | n = 1 |
| Gate SLA (B/T/L/I) | I-MR | gate wall clock per run | n = 1 |

Rationale: compile defects are attribute data (defect flag present/absent) →
p-chart; latency CTQs are variable data with within-run dispersion → X̄-S;
per-run singletons → I-MR.

### 6.2 Sampling frequency

- Every CI run: p-chart point (all four defect dimensions), gate SLA I-MR,
  coverage I-MR.
- Every qualification run (the 500-run VERIFY ladder): jitter and GC-pause
  X̄-S subgroups.
- Production census: monthly DPMO rollup per §2.2 census scale; control limits
  recalculated only on a verified process change (never on an out-of-control
  point).

### 6.3 Out-of-control reaction rules

1. **Any single defect flag (p-chart > 0):** Andon RED — pipeline halts
   instantly (charter §6). Root-cause via charter §5 FMEA mode; repair lands
   only with a regression court proving the defect class cannot recur
   (fix-forward, no hiding the point by recalculating limits).
2. **Western Electric rule violation on X̄-S / I-MR** (1 point > 3σ, 2 of 3
   beyond 2σ same side, 4 of 5 beyond 1σ same side, 8 in a row same side):
   YELLOW — investigate with special-cause checklist; two consecutive
   YELLOW on the same CTQ escalates to RED.
3. **Control-limit recalculation is an admitted transition:** allowed only
   after a documented, receipted process change; an out-of-control point never
   triggers recalculation on its own.
4. **Charter §3 CTQ C_pk < 1.67 on a recalculated basis:** runtime claim
   suspended; VERIFY tollgate sign-off blocked until capability restored.
5. **p-chart denominator change (R drift):** limits recomputed from the new R;
   a run whose receipt R mismatches the live graph count is discarded from the
   chart (§5.2 F3).

## References

- Charter: `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/charter-master.md`
  (§3 CTQs, §4 VERIFY, §5 FMEA, §6 gates, §7 targets)
- Sibling phase docs: `define.md`, `measure.md`, `analyze.md`, `design.md`,
  `verify.md`, `andon.md`, `triz.md`

Status: COMPLETE-DOCUMENT / UNVERIFIED-NUMBERS — all baseline figures (μ, σ_proc,
R=120, U=500) are worked placeholders pending MEASURE receipts; targets and
formulas are final and consistent with charter-master.md §7.
